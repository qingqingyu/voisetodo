#!/usr/bin/env node
// AI 抽取质量评测 runner(零依赖,Node >= 18)。
//
// 用法:
//   发送 + 评分(经部署/本地 wrangler dev 的 HTTP 端点):
//     node run.mjs --endpoint http://localhost:8787 --token <APP_TOKEN> --label baseline-sonnet
//   进程内直连指定 provider 条目(A4,换服务商评测;不起 wrangler、不走已部署代理):
//     OPENROUTER_KEY=sk-or-... node run.mjs --provider-file providers/openrouter-glm-4.5-air.json \
//        --key-env OPENROUTER_KEY --label or-glm-air
//     (--provider-file 是不含 key 的条目描述;key 只从 env 读,不进仓库/命令行)
//   对比表(把多轮 scored.json 合成一张服务商对比表):
//     node run.mjs --table results/a.scored.json results/b.scored.json ...
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
import { execFile } from "node:child_process";

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
      case "--provider-file": args.providerFile = next(); break;
      case "--key-env": args.keyEnv = next(); break;
      case "--proxy": args.proxy = next(); break;
      case "--table":
        // --table f1 f2 f3:一个 flag 后跟多个文件(遇到下一个 -- 停)
        args.table = args.table || [];
        args.table.push(next());
        while (i + 1 < argv.length && !argv[i + 1].startsWith("--")) {
          args.table.push(argv[++i]);
        }
        break;
      default: throw new Error(`未知参数: ${a}`);
    }
  }
  if (args.table) return args;
  if (args.replay) return args;
  if (args.providerFile) {
    if (!args.label) throw new Error("--provider-file 模式也需要 --label");
    return args;
  }
  if (!args.endpoint || !args.token || !args.label) {
    throw new Error("需要 --endpoint --token --label(或 --provider-file <json> [--key-env VAR],或 --replay <file>)");
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

// 进程内评测的代理 fetch(--proxy):Node 23 的全局 fetch 不认 HTTP(S)_PROXY,
// 而自建 CONNECT 隧道 + Node TLS 的 ClientHello 会被 openrouter 前面的
// Cloudflare 按 TLS 指纹拦 403(实测 UA/cipher 伪装均无效;同一隧道 curl 放行)。
// 因此直接子进程 curl:TLS 栈由 curl 呈现,响应头/体从 stdout 解析,
// 返回 WHATWG Response 供 worker 管线消费。流式场景整包缓冲后交付——
// 上游视角与逐块读取一致(eval 无中途断开场景)。
function makeProxyFetch(proxyUrl) {
  return async function proxyFetch(url, init = {}) {
    const args = ["-sS", "-x", String(proxyUrl), "--max-time", "150", "--dump-header", "-"];
    args.push("-X", init.method || "GET");
    for (const [name, value] of Object.entries(init.headers || {})) {
      if (String(name).toLowerCase() === "content-length") continue; // curl 自算
      args.push("-H", `${name}: ${value}`);
    }
    const hasBody = init.body != null;
    if (hasBody) args.push("--data-binary", "@-");
    args.push(String(url));
    const { stdout } = await new Promise((resolve, reject) => {
      const child = execFile("curl", args, { encoding: "buffer", maxBuffer: 64 * 1024 * 1024, signal: init.signal || undefined },
        (error, stdout, stderr) => {
          if (error && !(stdout && stdout.length)) {
            const message = stderr && stderr.length ? `: ${stderr.toString().slice(0, 200)}` : "";
            const err = new Error(`curl proxy fetch failed${message}`);
            if (error.name === "AbortError" || String(error.message || "").includes("SIGTERM")) err.name = "AbortError";
            reject(err);
            return;
          }
          resolve({ stdout: stdout || Buffer.alloc(0) });
        });
      if (hasBody) child.stdin.end(Buffer.from(String(init.body)));
      else child.stdin.end();
    });
    // stdout = 响应头块(\r\n 行)+ 空行 + 体
    const headerEnd = stdout.indexOf("\r\n\r\n");
    if (headerEnd === -1) throw new Error("curl output missing header/body separator");
    const headerBlock = stdout.subarray(0, headerEnd).toString("utf8");
    const bodyBuffer = stdout.subarray(headerEnd + 4);
    const headerLines = headerBlock.split("\r\n");
    const statusMatch = headerLines[0].match(/^HTTP\/\S+\s+(\d+)/);
    const status = statusMatch ? Number(statusMatch[1]) : 502;
    const headers = [];
    for (const line of headerLines.slice(1)) {
      const idx = line.indexOf(":");
      if (idx > 0) headers.push([line.slice(0, idx).trim(), line.slice(idx + 1).trim()]);
    }
    return new Response(bodyBuffer, { status, headers });
  };
}

// 进程内 transport(A4):直接 import worker 的 handleRequest,fetchImpl 用真实
// global fetch 打上游 —— 与生产完全同一套 adapter/分类/failover 代码,唯一区别是
// 不经已部署代理(env 是本地构造的,只有目标 provider 一条 + 免费额度全开)。
// key 从 env 变量读(默认 EVAL_PROVIDER_KEY),不进命令行(ps 可见)不进仓库。
async function makeInProcessTransport(providerFile, keyEnvName) {
  const apiKey = process.env[keyEnvName];
  if (!apiKey) {
    throw new Error(`环境变量 ${keyEnvName} 未设置:进程内评测的 provider key 只从 env 读(不写进 --provider-file / 命令行)`);
  }
  const { handleRequest, _testResetHealth, _testResetAdminConfig, _testResetExtractionCache, _testResetAlertState, _testResetProbeCache } = await import("../worker.js");
  // 进程内模式的降噪:worker 每请求打 10+ 行 JSON 日志(生产走 wrangler tails,
  // 这里会淹没评测报告)。只过滤结构化日志行,run.mjs 自身的报告输出不受影响。
  const originalLog = console.log;
  console.log = (value) => {
    const line = String(value);
    if (line.startsWith("{") && line.includes("\"event\"")) return;
    originalLog(value);
  };
  // 单例隔离:同 worker.test.js beforeEach 语义;每次 run 一个干净 HealthStore
  _testResetHealth();
  _testResetAdminConfig();
  _testResetExtractionCache();
  _testResetAlertState();
  _testResetProbeCache();
  const raw = JSON.parse(readFileSync(providerFile, "utf8"));
  if (!raw.url || !raw.model || !raw.type) {
    throw new Error(`--provider-file 需要 type/url/model 字段(不含 key): ${providerFile}`);
  }
  const providerMeta = {
    file: providerFile,
    type: raw.type,
    url: raw.url,
    model: raw.model,
    extraHeaders: raw.extraHeaders ?? null,
    extraBody: raw.extraBody ?? null,
    disableResponseFormat: raw.disableResponseFormat === true,
    maxConcurrencyPerKey: raw.maxConcurrencyPerKey ?? null,
    timeoutMs: raw.timeoutMs ?? null
  };
  const fetchImpl = globalThis.__evalProxyFetch || fetch;
  const env = {
    APP_TOKEN: "eval-inprocess",
    PROVIDERS: JSON.stringify([{
      id: "EVAL_TARGET",
      priority: 1,
      weight: 1,
      enabled: true,
      ...raw,
      secretName: "EVAL_PROVIDER_KEY"
    }]),
    EVAL_PROVIDER_KEY: apiKey,
    // 单条目 + 1 次尝试:失败即 infra_error,不混样(README §1.1 同理由)
    AI_PROVIDER_MAX_ATTEMPTS: "1"
    // 故意不绑 RATE_LIMIT_KV / AI_PROVIDER_STATE_KV / QUOTA_COUNTER_DO / CACHE_RESULT_KV:
    // 本地跑不受生产配额/熔断/缓存影响;X-Quota-Reset-Date 头缺失时锚校验自动跳过
  };
  const send = async (deviceId, anchorToday, c, timeoutMs) => {
    const body = { transcript: c.transcript, locale: c.locale, stream: true };
    if (c.vocabularyHints) body.vocabularyHints = c.vocabularyHints;
    if (c.personalHints) body.personalHints = c.personalHints;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await handleRequest(
        new Request("https://eval.inprocess/v1/todo-extractions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-App-Token": "eval-inprocess",
            "X-Device-ID": deviceId,
            "X-Local-Date": anchorToday
          },
          body: JSON.stringify(body),
          signal: controller.signal
        }),
        env,
        { waitUntil() {} },
        fetchImpl
      );
      return res;
    } finally {
      clearTimeout(timer);
    }
  };
  return { send, providerMeta };
}

async function sendOne(endpoint, token, deviceId, anchorToday, c, timeoutMs, transport = null) {
  const body = { transcript: c.transcript, locale: c.locale, stream: true };
  if (c.vocabularyHints) body.vocabularyHints = c.vocabularyHints;
  if (c.personalHints) body.personalHints = c.personalHints;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = transport
      ? await transport.send(deviceId, anchorToday, c, timeoutMs)
      : await fetch(`${endpoint.replace(/\/$/, "")}/v1/todo-extractions`, {
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
      p50: latencies.length ? latencies[Math.floor(latencies.length * 0.5)] : null,
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
  console.log(`\n延迟: mean ${fmtMs(r.latency.mean)} / p50 ${fmtMs(r.latency.p50)} / p95 ${fmtMs(r.latency.p95)} / max ${fmtMs(r.latency.max)}   响应均长: ${fmtChars(r.avgResponseChars)}`);
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

  // --table:把多轮 scored.json 合成对比表(服务商 × 模型 × 开关 → 准确率/P50/P95)
  if (args.table) {
    printComparisonTable(args.table);
    return 0;
  }

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
    writeFileSync(outFile, JSON.stringify({ anchorToday: anchor, ...(resultsFile.providerMeta ? { providerMeta: resultsFile.providerMeta } : {}), report, generatedAt: new Date().toISOString() }, null, 2));
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

  // 进程内模式:构造 transport(校验 key/env);HTTP 模式 transport=null。
  // --proxy:经本地/远端 HTTP 代理出海(如 sing-box 转发的 ss/vless 节点)。
  if (args.proxy) {
    globalThis.__evalProxyFetch = makeProxyFetch(args.proxy);
    console.log(`上游经由代理: ${args.proxy}`);
  }
  const transport = args.providerFile
    ? await makeInProcessTransport(args.providerFile, args.keyEnv || "EVAL_PROVIDER_KEY")
    : null;
  if (transport) {
    console.log(`provider(进程内直连): ${transport.providerMeta.model} @ ${transport.providerMeta.url}`);
  }

  const outCases = [];
  let sent = 0, retried = 0;
  for (const c of dataset.cases) {
    let rc = prevCases.get(c.id) ?? null;
    if (!rc) {
      const startedAt = Date.now();
      const r = await sendOne(args.endpoint, args.token, deviceId, anchor, c, args.timeoutMs, transport);
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
      const current = { label: args.label, ts, anchorToday: anchor, endpoint: args.endpoint, dataset: datasetPath, ...(transport ? { providerMeta: transport.providerMeta } : {}), cases: mergeById(outCases, prevCases) };
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
    const r = await sendOne(args.endpoint, args.token, deviceId, anchor, c, args.timeoutMs, transport);
    r.elapsedMs = Date.now() - startedAt;
    if (r.ok) { Object.assign(rc, r); retried++; }
    else rc.retries = [{ ...r.error }];
  }

  const resultsFile = { label: args.label, ts, anchorToday: anchor, endpoint: args.endpoint, dataset: datasetPath, ...(transport ? { providerMeta: transport.providerMeta } : {}), cases: mergeById(outCases, prevCases) };
  const outPath = writeResults(RESULTS_DIR, `${args.label}-${ts}.json`, resultsFile);

  const infra = resultsFile.cases.filter((c) => !c.ok).length;
  const report = scoreAll(dataset, resultsFile);
  printReport(report, infra);
  const scoredPath = writeResults(RESULTS_DIR, `${args.label}-${ts}.scored.json`, { anchorToday: anchor, ...(transport?.providerMeta ? { providerMeta: transport.providerMeta } : {}), report, generatedAt: new Date().toISOString() });
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


// ---------- 对比表(A4:服务商 × 模型 × 开关 → 准确率 / P50 / P95) ----------
//
// 输入是各轮 run 落盘的 *.scored.json(含 providerMeta 时优先用其 model/url,
// 否则退回 label)。token 数没有上游 usage 数据,列留空由人工按 console 校准
// (README §5 已有同款口径)。
function printComparisonTable(files) {
  const rows = [];
  for (const file of files) {
    const parsed = JSON.parse(readFileSync(file, "utf8"));
    const report = parsed.report ?? parsed;
    const meta = parsed.providerMeta ?? {};
    rows.push({
      file,
      label: report.label ?? "?",
      model: meta.model ?? report.label ?? "?",
      platform: String(meta.url ?? "").includes("openrouter") ? "OpenRouter" : (meta.url ? new URL(meta.url).host : "?"),
      thinking: meta.extraBody && Object.keys(meta.extraBody).length > 0
        ? JSON.stringify(meta.extraBody)
        : (meta.disableResponseFormat ? "no-response-format" : "default"),
      pass: `${report.passed ?? report.passRate ?? "?"}/${report.scored ?? "?"}`,
      passRate: report.passRate ?? "?",
      infra: parsed.cases ? parsed.cases.filter((c) => !c.ok).length : "?",
      p50: report.latency?.p50 ?? null,
      p95: report.latency?.p95 ?? null,
      mean: report.latency?.mean ?? null
    });
  }
  const fmt = (v) => (v == null ? "-" : `${Math.round(v / 100) / 10}s`);
  console.log("| 平台 | 模型 | 开关 | case 全对 | infra_error | mean | P50 | P95 | label |");
  console.log("|---|---|---|---|---|---|---|---|---|");
  for (const r of rows) {
    console.log(`| ${r.platform} | ${r.model} | ${r.thinking} | ${r.pass} (${r.passRate}) | ${r.infra} | ${fmt(r.mean)} | ${fmt(r.p50)} | ${fmt(r.p95)} | ${r.label} |`);
  }
  console.log("\ntoken 用量列留空:上游 usage 不随 SSE 透出,按各服务商 console 校准(eval/README.md §5 同口径)。");
}
