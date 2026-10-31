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

// X-Extract-ID 合法性(任务书 §2.4):≤64 字符,只含字母数字与 - _ . : ,
// 其他(含任何位置的空白)一律视为未携带,防止把任意字符串写进 D1 / 结构化
// 日志(日志注入)。不做 trim —— 任务书口径是「不符合字符集就当没带」;
// 且 Fetch API 的 headers.get() 已按 HTTP 规范剥掉首尾 OWS,trim 属多余宽容。
// App 端生成的是 `extract-<uuid>` 形态,天然落在字符集内。
const EXTRACT_ID_PATTERN = /^[A-Za-z0-9_\-.:]{1,64}$/;

export function sanitizeExtractId(raw) {
  const value = String(raw ?? "");
  return EXTRACT_ID_PATTERN.test(value) ? value : null;
}

// 成功率口径:success / cache_hit / empty_todos 计为成功(cache_hit 零成本给了
// 结果;empty_todos 是模型看过原文后判定没有待办,链路本身工作正常)。
// client_disconnected 是用户主动取消,不计入成功率分子**也不计入分母**——
// 混进分母会把「用户划走」算成故障,污染「解析失败率」告警(与 iOS 端
// ExtractOutcome.cancelled 必须与 failed 分开统计同口径)。
const SUCCESS_OUTCOMES = new Set(["success", "cache_hit", "empty_todos"]);
const DISCONNECTED_OUTCOME = "client_disconnected";

// quota_rejected 按 error_type 再分两类(任务书 task-metrics-quota-and-review-query §1.2):
//   用户自己的限制 —— 免费额度用完 / 订阅额度 / 限速 / 深读限额,按设计拦下,
//     不是服务故障:排除出成功率分母,也排除出耗时统计(几毫秒就返回,混进
//     P50/P95 会把真实变慢掩盖掉)。管理接口用 userLimitRejections 单独计数。
//   我方容量问题(key_pool_full / global_budget_exceeded(_pro))—— 用户想用但
//     我方给不了:照旧计为失败、计入耗时,要能触发告警。
// 与 worker.js 的 QUOTA_REJECTION_TYPES 是两回事:那个决定 outcome 写不写成
// quota_rejected(写行口径);这个决定统计口径。error_type 不在本集合里的
// quota_rejected 行(未来新增的闸门类型/未知值)保守计为失败——宁可多告警,
// 不可漏告警。summarizeExtractRequests 与 evaluateExtractAlerts 共用本常量。
const USER_LIMIT_REJECTION_TYPES = new Set([
  "quota_exceeded",
  "subscription_quota_exceeded",
  "rate_limited",
  "deepread_limit_exceeded"
]);

/// 统计口径上的「不参与评价」行:用户主动取消,或被自己的额度/限速按设计拦下。
/// 成功率分母与耗时样本用同一排除集(两类行都不代表服务质量和解析速度)。
function isExcludedFromStats(row) {
  return row.outcome === DISCONNECTED_OUTCOME || USER_LIMIT_REJECTION_TYPES.has(row.error_type);
}

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
  // client_disconnected 与用户额度/限速拒绝出分母(见上方口径注释);分母为 0
  // 时返回 null 而非 0 —— 「没有可评价的请求」与「全部失败」是两种语义。
  const rated = rows.filter((r) => !isExcludedFromStats(r));
  if (rated.length === 0) return null;
  const ok = rated.filter((r) => SUCCESS_OUTCOMES.has(r.outcome)).length;
  return ok / rated.length;
}

/// 参与耗时统计(P50/P95)的 total_ms 数值:排除取消与用户限制行后的有限值。
function latencyValuesOf(rows) {
  return rows
    .filter((r) => !isExcludedFromStats(r))
    .map((r) => Number(r.total_ms))
    .filter((v) => Number.isFinite(v));
}

/// 把窗口内的一批行汇总成管理接口返回体。纯函数(时间窗口/截断标记由调用方算)。
export function summarizeExtractRequests(rows) {
  const totalMsValues = latencyValuesOf(rows);
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
        // requests 是窗口内归属到该 key 的原始行数(含被排除的,与 byOutcome 对账用);
        // successRate / p50 / p95 按排除后的口径。
        requests: groupRows.length,
        successRate: groupRate === null ? null : round4(groupRate),
        p50Ms: percentile(latencyValuesOf(groupRows), 0.5),
        p95Ms: percentile(latencyValuesOf(groupRows), 0.95),
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
    // 「用户自己的限制」被拦下的次数(单独计数,不进成功率/耗时)——看免费额度
    // 撞墙频率用,与 byOutcome 的 quota_rejected 计数(两类之和)互补。
    userLimitRejections: rows.filter((r) => USER_LIMIT_REJECTION_TYPES.has(r.error_type)).length,
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
///   latency:   { breached, requests, p95Ms, slowestModel }  —— breached = 样本够 && P95 超阈值
///   success:   { breached, requests, successRate, failuresByModel }
/// 样本不足(< minRequests)时 breached=false(任务书:量太小没有意义);
/// 最小样本数按**各自参与统计的行数**判断(成功率按成功率先的有效行,耗时按
/// 耗时有效行)——用户额度拒绝刷屏时两类样本同时缩水,不该因此反而告警。
/// 成功率分母与耗时样本都排除 client_disconnected 与用户额度/限速拒绝(口径同
/// successRateOf / latencyValuesOf);我方容量拒绝(key_pool_full 等)计为失败,
/// 进失败分布与耗时。P95 统计含其余失败行的 total_ms(用户体感耗时包含等失败
/// 的时间),排除 null。
export function evaluateExtractAlerts(rows, { p95ThresholdMs, successMin, minRequests = EXTRACT_ALERT_MIN_REQUESTS }) {
  const rated = rows.filter((r) => !isExcludedFromStats(r));
  const latencyRows = rated.filter((r) => Number.isFinite(Number(r.total_ms)));
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
