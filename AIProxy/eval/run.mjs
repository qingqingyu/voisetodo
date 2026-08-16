#!/usr/bin/env node
// AI 抽取质量评测 runner(零依赖,Node >= 18)。
//
// 用法:
//   发送 + 评分:
//     node run.mjs --endpoint http://localhost:8787 --token <APP_TOKEN> --label baseline-sonnet
//   断点续跑(跳过上次已完成 case):
//     node run.mjs ... --resume
//   只重放评分(不花钱重跑):
//     node run.mjs --replay results/baseline-sonnet-<ts>.json
//
// 机制(设计依据见同目录 README.md):
// - stream=true 绕开 KV 结果缓存(缓存条件 !stream && !personalHints,worker.js)
// - 每次 run 生成唯一 X-Device-ID,隔离设备配额桶(quota 在 cache 之前执行)
// - X-Local-Date 动态日期锚:worker 的 resolveQuotaDate 对该头做 ±1 天漂移校验
//   (超限回退 server UTC,prompt 参考日期跟着回退),固定写 dataset 里的
//   2026-01-07 会被拒。因此每次 run 在 UTC 今天 ±1 天内选一个周三作锚
//   (与 golden 的 authoring 锚同星期,相对日期语义完全同构),再把 golden
//   日期按锚偏移平移;月底 case 按 end-of-month tag 重算为锚当月最后一天。
//   锚会回读响应头 X-Quota-Reset-Date 校验,被 worker 拒绝(≠锚)立即中止。
// - 5xx/超时/429/JSON 解析失败 → infra_error,收尾重试一次,不计入准确率
// - 原始响应先落盘(含本次锚),评分独立可重放(--replay 复用当时的锚)
//
// 退出码:0 = 跑完(不论分数);1 = 用法/环境错误;2 = 有 case 未完成(infra_error 重试后仍失败)

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_DATASET = join(SCRIPT_DIR, "dataset.json");
const RESULTS_DIR = join(SCRIPT_DIR, "results");

// ---------- CLI ----------

function parseArgs(argv) {
  const args = { gapMs: 300, timeoutMs: 90_000 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    // 取值防御:缺值或把下一个参数名当值吃掉(--endpoint --resume → 字面量
    // "--resume" 去发请求,报错点离病因很远),都在解析期就地报错。
    const next = () => {
      if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) {
        throw new Error(`参数 ${a} 缺少取值`);
      }
      return argv[++i];
    };
    const nextFiniteNumber = (flag) => {
      const raw = next();
      const n = Number(raw);
      if (!Number.isFinite(n) || n <= 0) {
        throw new Error(`${flag} 需要一个正数,收到: ${String(raw)}`);
      }
      return n;
    };
    switch (a) {
      case "--endpoint": args.endpoint = next(); break;
      case "--token": args.token = next(); break;
      case "--label": args.label = next(); break;
      case "--dataset": args.dataset = next(); break;
      case "--replay": args.replay = next(); break;
      case "--resume": args.resume = true; break;
      case "--gap": args.gapMs = nextFiniteNumber("--gap"); break;
      case "--timeout": args.timeoutMs = nextFiniteNumber("--timeout"); break;
      default: throw new Error(`未知参数: ${a}`);
    }
  }
  if (args.replay) return args;
  if (!args.endpoint || !args.token || !args.label) {
    throw new Error("需要 --endpoint --token --label(或用 --replay <file> 只重放评分)");
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(args.label)) throw new Error(`--label 非法: ${args.label}`);
  return args;
}

// ---------- 日期锚(worker ±1 天漂移校验约束下的动态周三锚) ----------

const DAY_MS = 24 * 3600 * 1000;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function parseISODate(s, what = "日期") {
  if (typeof s !== "string" || !ISO_DATE_RE.test(s) || !Number.isFinite(Date.parse(`${s}T00:00:00.000Z`))) {
    throw new Error(`${what} 非法(需 YYYY-MM-DD): ${String(s)}`);
  }
  return Date.parse(`${s}T00:00:00.000Z`);
}

function toISODate(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

/// 在 UTC 今天 ±1 天内选一个与 meta.anchor_weekday 同星期的日期作锚。
/// 返回 null 表示这个窗口内没有(worker 漂移校验只容忍 ±1 天,锚必须是 authoring
/// 锚的同星期,否则裸星期几/下周三等相对日期语义与 golden 不再同构)。
function pickAnchor(anchorWeekday) {
  const target = WEEKDAY_NAMES.indexOf(anchorWeekday);
  if (target === -1) throw new Error(`meta.anchor_weekday 非法: ${anchorWeekday}`);
  const todayMs = parseISODate(new Date().toISOString().slice(0, 10), "UTC 今天");
  for (const off of [0, 1, -1]) {
    const cand = todayMs + off * DAY_MS;
    if (new Date(cand).getUTCDay() === target) return toISODate(cand);
  }
  return null;
}

/// 把 golden 日期从 meta.anchor_today(authoring 锚)平移到本次 run 的锚。
/// - 周三语义同构:authoring 锚与新锚同星期 → tomorrow/下周三/周五前 等表达的
///   目标日期偏移量不变,均匀平移即正确
/// - 月底例外:end-of-month tag 的 case 重算为新锚当月最后一天(均匀平移会把
///   1 月 31 日挪到月中)
/// - case 级 today 覆盖不支持(其 golden 的星期语境未知),显式抛错不静默
function shiftGoldenDates(dataset, anchor) {
  const anchorWeekday = WEEKDAY_NAMES[new Date(parseISODate(anchor, "锚日期")).getUTCDay()];
  if (anchorWeekday !== dataset.meta.anchor_weekday) {
    throw new Error(`锚 ${anchor} 是 ${anchorWeekday},与 meta.anchor_weekday=${dataset.meta.anchor_weekday} 不同星期,golden 相对日期语义将失真`);
  }
  // authoring 锚自身的星期也要自洽:--dataset 可指向任意文件,dataset 自检脚本
  // 只覆盖本仓库这份。anchor_weekday 手滑改了而 golden 日期没跟着重写时,
  // 平移基准已经错了,必须在这里拦下而不是静默跑完。
  const originWeekday = WEEKDAY_NAMES[new Date(parseISODate(dataset.meta.anchor_today, "meta.anchor_today")).getUTCDay()];
  if (originWeekday !== dataset.meta.anchor_weekday) {
    throw new Error(`meta.anchor_today(${dataset.meta.anchor_today}) 实际是 ${originWeekday},与 meta.anchor_weekday=${dataset.meta.anchor_weekday} 不符——golden 平移基准不可信`);
  }
  const originMs = parseISODate(dataset.meta.anchor_today, "meta.anchor_today");
  const anchorMs = parseISODate(anchor, "锚日期");
  const deltaDays = Math.round((anchorMs - originMs) / DAY_MS);
  // case 级 today 覆盖在 delta=0 与 delta≠0 两条路径上行为必须一致(都显式拒绝):
  // sendOne 只按全局锚发送,c.today 早已不生效,静默忽略会让语义丢失无感知。
  for (const c of dataset.cases) {
    if (c.today) {
      throw new Error(`case ${c.id} 带 today 覆盖:动态锚平移不支持(其 golden 星期语境未知),见 README 维护节`);
    }
  }
  if (deltaDays === 0) return dataset;
  const shifted = structuredClone(dataset);
  for (const c of shifted.cases) {
    const isMonthEnd = Array.isArray(c.tags) && c.tags.includes("end-of-month");
    for (const t of c.golden.todos) {
      if (t.due_date == null) continue;
      t.due_date = isMonthEnd
        ? lastDayOfMonthISO(anchorMs)
        : toISODate(parseISODate(t.due_date, `${c.id} due_date`) + deltaDays * DAY_MS);
    }
  }
  return shifted;
}

function lastDayOfMonthISO(anchorMs) {
  const d = new Date(anchorMs);
  return toISODate(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0));
}

// ---------- 归一化(评分口径) ----------

function normRR(r) {
  if (r === null || r === undefined) return null;
  return {
    frequency: r.frequency ?? null,
    interval: r.interval ?? 1,
    weekdays: Array.isArray(r.weekdays) ? [...r.weekdays].sort((a, b) => a - b) : [],
    day_of_month: r.day_of_month ?? null,
    end_date: r.end_date ?? null
  };
}

function normTodo(t) {
  return {
    title: typeof t?.title === "string" ? t.title : "",
    due_date: t?.due_date ?? null,
    due_time: t?.due_time ?? null,
    time_bucket: t?.time_bucket ?? null,
    recurrence_rule: normRR(t?.recurrence_rule),
    recurrence_end: t?.recurrence_end ?? null,
    reminder_times: Array.isArray(t?.reminder_times) ? [...t.reminder_times].sort() : null,
    due_date_basis: t?.due_date_basis ?? null,
    priority: t?.priority ?? "normal",
    category_hint: t?.category_hint ?? null
  };
}

// 贪心配对签名:hard 字段全集(顺序无关匹配用)。
// time_bucket / recurrence_end 不进签名(只做配对后的独立比对,见 HARD_FIELDS)。
function signature(n) {
  return JSON.stringify([
    n.due_date, n.due_time, n.recurrence_rule, n.category_hint, n.priority, n.due_date_basis, n.reminder_times
  ]);
}

const HARD_FIELDS = ["due_date", "due_time", "recurrence_rule", "category_hint", "priority", "due_date_basis", "reminder_times"];
const SOFT_FIELDS = ["title", "time_bucket", "recurrence_end"];

// ---------- 发送层 ----------

async function sendOne(endpoint, token, deviceId, anchorToday, c, timeoutMs) {
  const body = { transcript: c.transcript, locale: c.locale, stream: true };
  if (c.vocabularyHints) body.vocabularyHints = c.vocabularyHints;
  if (c.personalHints) body.personalHints = c.personalHints;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${endpoint.replace(/\/$/, "")}/v1/todo-extractions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-App-Token": token,
        "X-Device-ID": deviceId,
        "X-Local-Date": anchorToday
      },
      body: JSON.stringify(body),
      signal: controller.signal
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      return { ok: false, httpStatus: res.status, error: { type: res.status === 429 ? "rate_limited" : "infra_error", message: `HTTP ${res.status}: ${text.slice(0, 300)}` } };
    }
    // 回读 worker 实际接受的配额日期:漂移校验拒绝 X-Local-Date 时它会回退
    // server UTC,prompt 参考日期跟着变,golden 全部错位 —— 必须当场暴露,不能
    // 让整轮跑成噪声。配额未启用时无此头,跳过校验。
    const quotaResetDate = res.headers.get("X-Quota-Reset-Date");
    if (quotaResetDate && quotaResetDate !== anchorToday) {
      return { ok: false, httpStatus: res.status, error: { type: "anchor_rejected", message: `X-Local-Date=${anchorToday} 被 worker 漂移校验拒绝,实际参考日期=${quotaResetDate}` } };
    }
    const { text, sseErrors } = await readSSE(res);
    const parsed = parseModelJSON(text);
    if (parsed instanceof Error) {
      return { ok: false, httpStatus: res.status, rawText: text, sseErrors, error: { type: "infra_error", message: `JSON 解析失败: ${parsed.message}` } };
    }
    if (!parsed || !Array.isArray(parsed.todos)) {
      return { ok: false, httpStatus: res.status, rawText: text, sseErrors, error: { type: "infra_error", message: "响应缺少 todos 数组" } };
    }
    return { ok: true, httpStatus: res.status, rawText: text, parsed };
  } catch (e) {
    const aborted = e?.name === "AbortError";
    return { ok: false, error: { type: "infra_error", message: `${aborted ? `超时(>${timeoutMs}ms)` : "网络错误"}: ${e?.message ?? e}` } };
  } finally {
    clearTimeout(timer);
  }
}

// SSE 拼装:按空行分事件,拼 "data:" 行;`data: [DONE]` 结束。
async function readSSE(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  const sseErrors = [];
  let buf = "";
  let text = "";
  let done = false;
  while (!done) {
    const { value, done: streamDone } = await reader.read();
    if (streamDone) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf("\n\n")) !== -1) {
      const block = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      const dataLines = block
        .split("\n")
        .filter((l) => l.startsWith("data:"))
        .map((l) => l.slice(5).replace(/^ /, ""));
      if (dataLines.length === 0) continue;
      const payload = dataLines.join("\n");
      if (payload.trim() === "[DONE]") { done = true; break; }
      try {
        const evt = JSON.parse(payload);
        if (typeof evt?.text === "string") text += evt.text;
        else sseErrors.push(`非 text 事件: ${payload.slice(0, 120)}`);
      } catch {
        sseErrors.push(`不可解析事件: ${payload.slice(0, 120)}`);
      }
    }
  }
  return { text, sseErrors };
}

// 与客户端 TodoExtractorService.parseResponse 同源逻辑:剥 markdown 围栏再 JSON.parse。
function parseModelJSON(text) {
  const stripped = String(text)
    .replace(/^\s*```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/, "")
    .trim();
  try {
    return JSON.parse(stripped);
  } catch (e) {
    return e;
  }
}

// ---------- 评分层 ----------

function scoreCase(c, parsed) {
  const goldenTodos = c.golden.todos.map(normTodo);
  const actualTodos = (parsed?.todos ?? []).map(normTodo);
  const result = {
    countMatch: goldenTodos.length === actualTodos.length,
    pairs: [],      // {goldenIdx, actualIdx | null, exact: bool}
    hardFails: [],  // {field, want, got}
    soft: {}        // {field: {match, total}}
  };

  // 第一级:严格签名贪心配对(exact = 7 个 hard 字段全等,case 过关只认它)
  const used = new Set();
  const unmatchedGolden = [];
  for (let g = 0; g < goldenTodos.length; g++) {
    const sig = signature(goldenTodos[g]);
    let matchIdx = null;
    for (let a = 0; a < actualTodos.length; a++) {
      if (used.has(a)) continue;
      if (signature(actualTodos[a]) === sig) { matchIdx = a; break; }
    }
    if (matchIdx !== null) {
      used.add(matchIdx);
      result.pairs.push({ goldenIdx: g, actualIdx: matchIdx, exact: true });
    } else {
      unmatchedGolden.push(g);
    }
  }

  // 第二级:兜底配对(只为字段级诊断,不参与过关)——
  // 未配上的 golden 与剩余 actual 按 hard 字段重合度最大者配对
  for (const g of unmatchedGolden) {
    let bestIdx = null, bestOverlap = -1;
    for (let a = 0; a < actualTodos.length; a++) {
      if (used.has(a)) continue;
      const overlap = HARD_FIELDS.filter(
        (f) => JSON.stringify(goldenTodos[g][f]) === JSON.stringify(actualTodos[a][f])
      ).length;
      if (overlap > bestOverlap) { bestOverlap = overlap; bestIdx = a; }
    }
    if (bestIdx !== null && bestOverlap > 0) {
      used.add(bestIdx);
      result.pairs.push({ goldenIdx: g, actualIdx: bestIdx, exact: false });
    } else {
      result.pairs.push({ goldenIdx: g, actualIdx: null, exact: false });
    }
  }
  result.pairs.sort((x, y) => x.goldenIdx - y.goldenIdx);

  // hard 字段失败清单:exact 配对按定义全等,只检查非 exact 的
  for (const { goldenIdx, actualIdx, exact } of result.pairs) {
    if (exact) continue;
    const want = goldenTodos[goldenIdx];
    if (actualIdx === null) {
      for (const f of HARD_FIELDS) {
        if (want[f] !== null && want[f] !== undefined) result.hardFails.push({ field: f, want: want[f], got: "<unmatched>" });
      }
      continue;
    }
    const got = actualTodos[actualIdx];
    for (const f of HARD_FIELDS) {
      if (JSON.stringify(want[f]) !== JSON.stringify(got[f])) {
        result.hardFails.push({ field: f, want: want[f], got: got[f] });
      }
    }
  }
  // 多出来的 actual(未配对)→ count 失败已由 countMatch 表达,不重复计字段

  // soft:仅配对项上报告
  for (const f of SOFT_FIELDS) {
    let match = 0, total = 0;
    for (const { goldenIdx, actualIdx } of result.pairs) {
      if (actualIdx === null) continue;
      total++;
      const w = goldenTodos[goldenIdx][f], g = actualTodos[actualIdx][f];
      const eq = f === "title"
        ? normalizeTitle(w) === normalizeTitle(g)
        : JSON.stringify(w) === JSON.stringify(g);
      if (eq) match++;
    }
    result.soft[f] = { match, total };
  }
  // ignored(soft):双空/双非空口径
  const gIgnored = c.golden.ignored ?? "";
  const aIgnored = parsed?.ignored ?? "";
  result.soft.ignored = { match: (gIgnored.length > 0) === (aIgnored.length > 0) ? 1 : 0, total: 1 };

  result.casePass = result.countMatch && result.pairs.every((p) => p.exact);
  return result;
}

function normalizeTitle(s) {
  return String(s ?? "").trim().toLowerCase().replace(/[。.,!?、!?:;""'']/g, "");
}

function scoreAll(dataset, resultsFile) {
  const byLocale = {};
  const fieldStats = {};   // hard: {match, total}
  const softStats = {};
  const failures = [];
  let scored = 0, passed = 0, goldenTodoTotal = 0, countMatch = 0;
  const latencies = [];
  const responseChars = [];
  // 先初始化全部 hard 字段行:0 个可评分 case(全 infra_error)时报告也要能打出来,
  // 而不是在 printReport 里 TypeError —— 全面失败恰恰是最需要报告的场景。
  for (const f of HARD_FIELDS) fieldStats[f] = { match: 0, total: 0 };

  for (const rc of resultsFile.cases) {
    const c = dataset.cases.find((x) => x.id === rc.id);
    if (!c) throw new Error(`results 里的 case ${rc.id} 不在 dataset 中`);
    if (!rc.ok) continue; // infra_error 不计分
    if (!rc.parsed || !Array.isArray(rc.parsed.todos)) {
      throw new Error(`results 里 case ${rc.id} 标记 ok 但 parsed.todos 缺失或非数组(手改文件?行号见 results 原文)`);
    }
    scored++;
    if (rc.elapsedMs != null) latencies.push(rc.elapsedMs);
    if (rc.rawText != null) responseChars.push(rc.rawText.length);
    const s = scoreCase(c, rc.parsed);
    if (s.casePass) passed++;
    if (s.countMatch) countMatch++;
    goldenTodoTotal += c.golden.todos.length;
    const loc = c.locale ?? "?";
    byLocale[loc] ??= { scored: 0, passed: 0 };
    byLocale[loc].scored++;
    if (s.casePass) byLocale[loc].passed++;

    for (const { goldenIdx, actualIdx } of s.pairs) {
      const want = normTodo(c.golden.todos[goldenIdx]);
      for (const f of HARD_FIELDS) {
        fieldStats[f].total++;
        const got = actualIdx === null ? undefined : normTodo(rc.parsed.todos[actualIdx])[f];
        if (JSON.stringify(want[f]) === JSON.stringify(got)) fieldStats[f].match++;
      }
    }
    for (const [f, v] of Object.entries(s.soft)) {
      softStats[f] ??= { match: 0, total: 0 };
      softStats[f].match += v.match;
      softStats[f].total += v.total;
    }
    if (!s.casePass) failures.push({ id: rc.id, locale: loc, countMatch: s.countMatch, hardFails: s.hardFails.slice(0, 6) });
  }

  latencies.sort((a, b) => a - b);
  return {
    label: resultsFile.label,
    scored,
    passed,
    passRate: pctStr(passed, scored),
    countMatchRate: pctStr(countMatch, scored),
    byLocale,
    goldenTodoTotal,
    hard: fieldStats,
    soft: softStats,
    latency: {
      mean: latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : null,
      p95: latencies.length ? latencies[Math.floor(latencies.length * 0.95)] : null,
      max: latencies.length ? latencies[latencies.length - 1] : null
    },
    avgResponseChars: responseChars.length ? Math.round(responseChars.reduce((a, b) => a + b, 0) / responseChars.length) : null,
    failures
  };
}

function printReport(r, infra) {
  console.log(`\n=== Eval 报告: ${r.label} ===`);
  console.log(`case: ${r.passed}/${r.scored} 全对(${r.passRate})  拆分数量正确: ${r.countMatchRate}  golden todo 总数: ${r.goldenTodoTotal}`);
  if (infra > 0) console.log(`⚠️  infra_error(未计分): ${infra}`);
  const locales = Object.entries(r.byLocale).map(([l, v]) => `${l} ${v.passed}/${v.scored}`).join("  ");
  console.log(`分语言: ${locales}`);
  console.log("\nhard 字段(诊断口径:兜底配对后逐字段比对;case 过关 = 全部严格签名配对):");
  for (const f of HARD_FIELDS) {
    const s = r.hard[f];
    console.log(`  ${f.padEnd(18)} ${String(s.match).padStart(3)}/${String(s.total).padEnd(3)} ${pctStr(s.match, s.total)}`);
  }
  console.log("\nsoft 字段(仅报告,不 gate):");
  for (const [f, s] of Object.entries(r.soft)) {
    console.log(`  ${f.padEnd(18)} ${String(s.match).padStart(3)}/${String(s.total).padEnd(3)} ${pctStr(s.match, s.total)}`);
  }
  const fmtMs = (v) => (v == null ? "n/a" : `${v}ms`);
  const fmtChars = (v) => (v == null ? "n/a" : `${v} chars`);
  console.log(`\n延迟: mean ${fmtMs(r.latency.mean)} / p95 ${fmtMs(r.latency.p95)} / max ${fmtMs(r.latency.max)}   响应均长: ${fmtChars(r.avgResponseChars)}`);
  if (r.failures.length) {
    console.log(`\n失败 case(${r.failures.length}):`);
    for (const f of r.failures) {
      const fails = f.hardFails.map((x) => `${x.field}: want ${JSON.stringify(x.want)} got ${JSON.stringify(x.got)}`).join("; ");
      console.log(`  ${f.id} [${f.locale}]${f.countMatch ? "" : " (数量不匹配)"} ${fails.slice(0, 200)}`);
    }
  } else {
    console.log("\n失败 case: 无");
  }
}

const pctStr = (n, d) => (d === 0 ? "n/a" : `${(100 * n / d).toFixed(1)}%`);

// ---------- 主流程 ----------

function findLatestResults(label) {
  if (!existsSync(RESULTS_DIR)) return null;
  // 精确匹配 `${label}-<ISO时间戳>.json`,不能用 startsWith(`${label}-`):
  // label "baseline" 会串档捡到 "baseline-sonnet-*.json" 的旧结果。
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^${escaped}-\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}\\.json$`);
  const files = readdirSync(RESULTS_DIR)
    .filter((f) => pattern.test(f))
    .sort();
  return files.length ? join(RESULTS_DIR, files[files.length - 1]) : null;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const datasetPath = args.dataset ?? DEFAULT_DATASET;
  const rawDataset = JSON.parse(readFileSync(datasetPath, "utf8"));

  // --replay:只评分。复用 results 里记录的锚(缺省回退 authoring 锚,兼容手造文件),
  // 保证改 golden 后重放与当时发送用同一套期望日期。
  if (args.replay) {
    const resultsFile = JSON.parse(readFileSync(args.replay, "utf8"));
    const anchor = resultsFile.anchorToday ?? rawDataset.meta.anchor_today;
    const dataset = shiftGoldenDates(rawDataset, anchor);
    const report = scoreAll(dataset, resultsFile);
    printReport(report, resultsFile.cases.filter((c) => !c.ok).length);
    const outFile = args.replay.replace(/\.json$/, ".scored.json");
    writeFileSync(outFile, JSON.stringify({ anchorToday: anchor, report, generatedAt: new Date().toISOString() }, null, 2));
    console.log(`\n评分已写入: ${outFile}(锚: ${anchor})`);
    return 0;
  }

  // 动态锚:worker 的漂移校验只容忍 ±1 天,固定写 meta.anchor_today 会被拒。
  // 锚必须是 authoring 锚的同星期(见 shiftGoldenDates 注释)。
  // --resume 必须复用上次 run 落盘的锚:周三开跑周四续跑时重选锚会让已发送 case
  // 的期望日期整体错位,评分静默全错。旧锚漂出 ±1 天窗口时新发送会触发
  // anchor_rejected 中止(见 sendOne),此时应去掉 --resume 重跑。
  const ts = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const deviceId = `eval-${args.label}-${ts}`;
  const prevResults = args.resume ? findLatestResults(args.label) : null;
  const prevCases = new Map();
  let anchor = null;
  if (prevResults) {
    const prev = JSON.parse(readFileSync(prevResults, "utf8"));
    anchor = prev.anchorToday ?? null;
    for (const rc of prev.cases) if (rc.ok) prevCases.set(rc.id, rc);
    console.log(`--resume: 复用 ${prevCases.size}/${rawDataset.cases.length} 个已完成 case(来自 ${prevResults})`);
  }
  if (!anchor) {
    anchor = pickAnchor(rawDataset.meta.anchor_weekday);
    if (!anchor) {
      const today = new Date().toISOString().slice(0, 10);
      const wd = WEEKDAY_NAMES.indexOf(rawDataset.meta.anchor_weekday);
      const window = [((wd + 6) % 7), wd, ((wd + 1) % 7)].map((i) => WEEKDAY_NAMES[i]).join("/");
      throw new Error(
        `今天(UTC ${today})的 ±1 天内没有 ${rawDataset.meta.anchor_weekday},动态锚无法选取。` +
        `worker 的 X-Local-Date 漂移校验只容忍 ±1 天,而 golden 相对日期语义按 ${rawDataset.meta.anchor_weekday} 锚定,` +
        `只能在 UTC ${window} 运行(或改 dataset.meta.anchor_weekday 并按新星期重写 golden 日期)。`
      );
    }
  }
  const dataset = shiftGoldenDates(rawDataset, anchor);
  console.log(`日期锚: ${anchor}(golden 按 authoring 锚 ${rawDataset.meta.anchor_today} 平移)`);

  const outCases = [];
  let sent = 0, retried = 0;
  for (const c of dataset.cases) {
    let rc = prevCases.get(c.id) ?? null;
    if (!rc) {
      const startedAt = Date.now();
      const r = await sendOne(args.endpoint, args.token, deviceId, anchor, c, args.timeoutMs);
      r.elapsedMs = Date.now() - startedAt;
      rc = { id: c.id, ...r };
      sent++;
      outCases.push(rc);
      if (rc.error?.type === "anchor_rejected") {
        throw new Error(
          `中止:第 ${sent} 条请求的 ${rc.error.message}。整轮期望日期已错位,继续只会烧配额产垃圾数据。` +
          (args.resume ? "跨天 --resume 的旧锚已漂出 worker ±1 天窗口,请去掉 --resume 重跑整轮" : "请检查系统时钟/时区")
        );
      }
      // 逐条落盘(崩溃可 --resume)
      const current = { label: args.label, ts, anchorToday: anchor, endpoint: args.endpoint, dataset: datasetPath, cases: mergeById(outCases, prevCases) };
      writeResults(RESULTS_DIR, `${args.label}-${ts}.json`, current);
      await sleep(args.gapMs);
    } else {
      outCases.push(rc);
    }
  }

  // infra_error 收尾重试一次(anchor_rejected 是确定性环境错误,重试无意义)
  for (const rc of outCases) {
    if (rc.ok || rc.id == null || rc.error?.type === "anchor_rejected") continue;
    const c = dataset.cases.find((x) => x.id === rc.id);
    const startedAt = Date.now();
    const r = await sendOne(args.endpoint, args.token, deviceId, anchor, c, args.timeoutMs);
    r.elapsedMs = Date.now() - startedAt;
    if (r.ok) { Object.assign(rc, r); retried++; }
    else rc.retries = [{ ...r.error }];
  }

  const resultsFile = { label: args.label, ts, anchorToday: anchor, endpoint: args.endpoint, dataset: datasetPath, cases: mergeById(outCases, prevCases) };
  const outPath = writeResults(RESULTS_DIR, `${args.label}-${ts}.json`, resultsFile);

  const infra = resultsFile.cases.filter((c) => !c.ok).length;
  const report = scoreAll(dataset, resultsFile);
  printReport(report, infra);
  const scoredPath = writeResults(RESULTS_DIR, `${args.label}-${ts}.scored.json`, { anchorToday: anchor, report, generatedAt: new Date().toISOString() });
  console.log(`\n原始结果: ${outPath}\n评分报告: ${scoredPath}`);
  console.log(`本次新发送: ${sent}  重试成功: ${retried}`);
  return infra > 0 ? 2 : 0;
}

function mergeById(outCases, prevCases) {
  const seen = new Set(outCases.map((c) => c.id));
  const merged = [...outCases];
  for (const [id, rc] of prevCases) if (!seen.has(id)) merged.push(rc);
  return merged.sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

function writeResults(dir, name, obj) {
  mkdirSync(dir, { recursive: true });
  const p = join(dir, name);
  writeFileSync(p, JSON.stringify(obj, null, 2));
  return p;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

main().then(
  (code) => process.exit(code ?? 0),
  (e) => { console.error(`\n错误: ${e.message}`); process.exit(1); }
);
