// 解析耗时监控(extract_requests 表,任务书 docs/extract-latency-monitoring-task.md §2-§4)。
//
// 三块能力共用本模块:
//   1. D1 写入包装 —— 每次 extract 解析一行,写失败只 logWarn,绝不影响用户请求
//   2. 汇总统计(纯函数)—— /v1/admin/extract-metrics 的分组 + P50/P95
//   3. 告警评估(纯函数)—— handleScheduled 里最近 30 分钟的 P95 / 成功率判定
//
// 隐私红线(任务书 §2.6):任何字段不得出现 Key 的值、转写原文、待办标题、
// 模型输出。key_slot 只存 secret 名(单 key 条目 = secretName,多 key 条目 =
// `条目id#secretName`,与 provider.js attempt.keySlot 同源)。

import { logWarn, errorFields } from "./log.js";

// X-Extract-ID 合法性(任务书 §2.4):≤64 字符,只含字母数字与 - _ . : 。
// App 端生成的是 `extract-<uuid>` 形态,天然落在字符集内;其余一律视为未携带,
// 防止把任意字符串写进 D1 / 结构化日志(日志注入)。
const EXTRACT_ID_PATTERN = /^[A-Za-z0-9_\-.:]{1,64}$/;

export function sanitizeExtractId(raw) {
  const value = String(raw ?? "").trim();
  return EXTRACT_ID_PATTERN.test(value) ? value : null;
}

// 成功率口径:success / cache_hit / empty_todos 计为成功(cache_hit 零成本给了
// 结果;empty_todos 是模型看过原文后判定没有待办,链路本身工作正常)。
// client_disconnected 是用户主动取消,不计入成功率分子**也不计入分母**——
// 混进分母会把「用户划走」算成故障,污染「解析失败率」告警(与 iOS 端
// ExtractOutcome.cancelled 必须与 failed 分开统计同口径)。
const SUCCESS_OUTCOMES = new Set(["success", "cache_hit", "empty_todos"]);
const DISCONNECTED_OUTCOME = "client_disconnected";

// 管理接口单次查询行数上限(任务书 §3.1):D1 无百分位函数,把窗口内 total_ms
// 拉回 Worker 内排序;上限防止 168h 窗口拖垮内存 / 查询时长。多取 1 行用于
// 判断是否被截断(截断时返回 sampled: true)。
export const EXTRACT_METRICS_QUERY_ROW_LIMIT = 20000;

// 告警评估窗口与最小样本数(任务书 §4:最近 30 分钟、<20 次不告警)。
export const EXTRACT_ALERT_WINDOW_MS = 30 * 60 * 1000;
export const EXTRACT_ALERT_MIN_REQUESTS = 20;
export const EXTRACT_ALERT_P95_DEFAULT_MS = 20000;
export const EXTRACT_ALERT_SUCCESS_MIN_DEFAULT = 0.9;

/// 写一行 extract_requests。调用方负责「一请求一行」去重;本函数只做写入 +
/// 失败降级(任务书 §2.3:写库出错只 logWarn,不向上抛、不影响响应)。
export async function writeExtractRequestRow(db, row, requestContext) {
  try {
    await db.prepare(
      `INSERT INTO extract_requests
         (received_at, request_id, extract_id, device_id, plan, stream,
          provider_id, model, key_slot, attempts, providers_tried, failover,
          upstream_first_byte_ms, total_ms, status, outcome, error_type, todos_count)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      row.received_at,
      row.request_id,
      row.extract_id ?? null,
      row.device_id,
      row.plan ?? null,
      row.stream ?? 0,
      row.provider_id ?? null,
      row.model ?? null,
      row.key_slot ?? null,
      row.attempts ?? 0,
      row.providers_tried ?? null,
      row.failover ?? 0,
      row.upstream_first_byte_ms ?? null,
      row.total_ms ?? null,
      row.status ?? null,
      row.outcome ?? null,
      row.error_type ?? null,
      row.todos_count ?? null
    ).run();
  } catch (error) {
    logWarn("proxy.extract_metrics.write_failed", {
      ...requestContext,
      outcome: row.outcome ?? null,
      ...errorFields(error)
    });
  }
}

// ── 汇总统计(管理接口)────────────────────────────────────────────────────

/// nearest-rank 百分位:升序排序后取第 ceil(p × n) 个(1-based)。
/// n=0 返回 null。选 nearest-rank 而非插值:实现确定、可单测,误差一档对
/// 20s 阈值的告警语义无影响。
export function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const rank = Math.max(1, Math.ceil(fraction * sorted.length));
  return sorted[rank - 1];
}

function successRateOf(rows) {
  // client_disconnected 出分母(见 SUCCESS_OUTCOMES 注释);分母为 0 时返回 null
  // 而非 0 —— 「没有可评价的请求」与「全部失败」是两种语义。
  const rated = rows.filter((r) => r.outcome !== DISCONNECTED_OUTCOME);
  if (rated.length === 0) return null;
  const ok = rated.filter((r) => SUCCESS_OUTCOMES.has(r.outcome)).length;
  return ok / rated.length;
}

/// 把窗口内的一批行汇总成管理接口返回体。纯函数(时间窗口/截断标记由调用方算)。
export function summarizeExtractRequests(rows) {
  const totalMsValues = rows
    .map((r) => Number(r.total_ms))
    .filter((v) => Number.isFinite(v));
  const rate = successRateOf(rows);

  const groupBy = (keyFn) => {
    const groups = new Map();
    for (const row of rows) {
      const key = keyFn(row);
      if (key === null || key === undefined) continue;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
    return [...groups.entries()].map(([key, groupRows]) => {
      const groupRate = successRateOf(groupRows);
      return {
        key,
        requests: groupRows.length,
        successRate: groupRate === null ? null : round4(groupRate),
        p50Ms: percentile(groupRows.map((r) => Number(r.total_ms)).filter(Number.isFinite), 0.5),
        p95Ms: percentile(groupRows.map((r) => Number(r.total_ms)).filter(Number.isFinite), 0.95),
        // 429 口径:该 key 上**终态**为上游 429 的行数。被 failover 吸收掉的 429
        // 记在最终成功行的 providers_tried/failover 里,不归属到原 key(表结构
        // 只存最终 key_slot,见结果文档局限说明)。
        status429: groupRows.filter((r) => r.error_type === "status_429").length
      };
    }).sort((a, b) => b.requests - a.requests);
  };

  const outcomeCounts = new Map();
  for (const row of rows) {
    const key = row.outcome ?? "unknown";
    outcomeCounts.set(key, (outcomeCounts.get(key) ?? 0) + 1);
  }

  return {
    requests: rows.length,
    successRate: rate === null ? null : round4(rate),
    p50Ms: percentile(totalMsValues, 0.5),
    p95Ms: percentile(totalMsValues, 0.95),
    failoverCount: rows.filter((r) => Number(r.failover) === 1).length,
    byProvider: groupBy((r) => (r.provider_id && r.model)
      ? `${r.provider_id}|${r.model}`
      : r.provider_id ?? null),
    byKeySlot: groupBy((r) => r.key_slot ?? null),
    byOutcome: [...outcomeCounts.entries()]
      .map(([outcome, count]) => ({ outcome, count }))
      .sort((a, b) => b.count - a.count)
  };
}

function round4(value) {
  return Math.round(value * 10000) / 10000;
}

// ── 告警评估(handleScheduled)──────────────────────────────────────────────

/// 最近 EXTRACT_ALERT_WINDOW_MS 内的行 → 两条独立告警的判定结果。纯函数。
///
/// 返回:
///   latency:   { breached, requests, p95Ms }  —— breached = 样本够 && P95 超阈值
///   success:   { breached, requests, successRate, failuresByModel }
/// 样本不足(< minRequests)时 breached=false(任务书:量太小没有意义);
/// P95 统计含失败行的 total_ms(用户体感耗时包含等失败的时间),排除 null。
/// 成功率分母排除 client_disconnected(口径同 successRateOf)。
export function evaluateExtractAlerts(rows, { p95ThresholdMs, successMin, minRequests = EXTRACT_ALERT_MIN_REQUESTS }) {
  const rated = rows.filter((r) => r.outcome !== DISCONNECTED_OUTCOME);
  const latencyRows = rows.filter((r) => Number.isFinite(Number(r.total_ms)));
  const p95Ms = percentile(latencyRows.map((r) => Number(r.total_ms)), 0.95);
  const successRate = successRateOf(rows);

  const latencyBreached = latencyRows.length >= minRequests
    && p95Ms !== null
    && p95Ms > p95ThresholdMs;
  const successBreached = rated.length >= minRequests
    && successRate !== null
    && successRate < successMin;

  // 失败分布(按 条目|模型 聚合),告警文案直接可用;只列失败行。
  const failuresByModel = new Map();
  for (const row of rated) {
    if (SUCCESS_OUTCOMES.has(row.outcome)) continue;
    const key = row.provider_id ? `${row.provider_id}|${row.model ?? "?"}` : "(no_provider)";
    failuresByModel.set(key, (failuresByModel.get(key) ?? 0) + 1);
  }

  // 最慢的 条目|模型(分组 P95 取最大,任务书 §4:告警附最慢的模型)。
  const modelGroups = new Map();
  for (const row of latencyRows) {
    if (!row.provider_id) continue;
    const key = `${row.provider_id}|${row.model ?? "?"}`;
    if (!modelGroups.has(key)) modelGroups.set(key, []);
    modelGroups.get(key).push(Number(row.total_ms));
  }
  let slowestModel = null;
  for (const [model, values] of modelGroups) {
    const p95 = percentile(values, 0.95);
    if (p95 !== null && (slowestModel === null || p95 > slowestModel.p95Ms)) {
      slowestModel = { model, p95Ms: p95 };
    }
  }

  return {
    latency: { breached: latencyBreached, requests: latencyRows.length, p95Ms, slowestModel },
    success: {
      breached: successBreached,
      requests: rated.length,
      successRate: successRate === null ? null : round4(successRate),
      failuresByModel: [...failuresByModel.entries()]
        .map(([model, count]) => ({ model, count }))
        .sort((a, b) => b.count - a.count)
    }
  };
}
