#!/usr/bin/env node
// 进程内并发压测(docs/concurrency-hardening-task.md §2)。
//
// 原理:直接 import worker 的 handleRequest,把第 4 参 fetchImpl 替换成「mock 上游」
// (与 worker.test.js 的 stub fetch 同一接缝,天然不打真实网络;config.js 的
// https:// 校验照常通过,因为 mock URL 也是 https)。不消耗 z.ai 真实额度,
// 不占生产并发名额,结果可重复(固定 seed)。
//
// 时间缩放:SCALE=10。真实世界 6s 单次解析 → mock 600ms;客户端退避 1s/2s →
// 100/200ms;熔断冷却 10s/5min → 1000ms/30000ms(env CIRCUIT_*_MS);provider
// timeoutMs 30s → 3000ms。所有时间参数同比例缩,报告里的 ms 一律 ×SCALE 换算回
// 真实时间。唯一例外:闸门 429 的 Retry-After 是服务端写死的常数(60s/次日),
// 客户端判断 retryAfter>8s 放弃——两个世界里决策一致,无需缩放。
//
// 用法:
//   node loadtest/run.mjs --users 100 --mode burst                 # 单场景
//   node loadtest/run.mjs --matrix --label before                  # §2.3 矩阵(改前)
//   node loadtest/run.mjs --matrix --balance --label after         # 矩阵 + 余额耗尽组(改后)
//   node loadtest/run.mjs --users 100 --gates prod                 # 生产真实闸门值
// 结果 JSON 落 loadtest/results/<label>-<name>.json,摘要表打 stdout。
// loadtest/ 不进 npm test(§2.4)。

import { parseArgs } from "node:util";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  handleRequest,
  _testResetHealth,
  _testResetAdminConfig,
  _testResetExtractionCache,
  _testResetAlertState,
  _testResetProbeCache
} from "../worker.js";

const SCALE = 10; // 真实 ms = 模拟 ms × SCALE

// ─── 可复现随机(固定 seed 的 LCG)──────────────────────────────────────────
function makeRng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ─── z.ai 真实错误体(docs.z.ai/api-reference/api-code)────────────────────
// 1302/429 = "Rate limit reached for requests"(忙)
// 1305/429 = "The service may be temporarily overloaded, please try again later."(忙)
// 1113/429 = "Insufficient balance or no resource package. Please recharge."(余额耗尽)
function zai429(code, message) {
  return new Response(
    JSON.stringify({ type: "error", error: { type: "rate_limit_error", code, message } }),
    { status: 429, headers: { "Content-Type": "application/json" } }
  );
}
const BUSY_429 = () => zai429("1302", "Rate limit reached for requests");
const QUOTA_429 = () => zai429("1113", "Insufficient balance or no resource package. Please recharge.");

// ─── mock 上游:每 provider 独立并发计数器,超限即 429──────────────────────
function makeMockUpstream({ limits, latencyMs, balanceExhausted, rng }) {
  const inFlight = { AIR: 0, SONNET: 0 };
  const stats = {
    AIR: { requests: 0, busy429: 0, quota429: 0, success: 0 },
    SONNET: { requests: 0, busy429: 0, quota429: 0, success: 0 }
  };
  const extraction = JSON.stringify({
    todos: [{
      title: "压测待办", detail: "loadtest", due_date: null, due_hint: null, due_time: null,
      time_bucket: null, recurrence_rule: null, recurrence_end: null, due_date_basis: null,
      reminder_times: null, reminder_offset_minutes: null, priority: "normal", category_hint: "other"
    }],
    ignored: ""
  });
  const sseBody = [
    `data: ${JSON.stringify({ type: "message_start" })}`,
    `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: extraction } })}`,
    `data: ${JSON.stringify({ type: "message_stop" })}`,
    ""
  ].join("\n\n");

  async function mockFetch(url) {
    const providerId = String(url).includes("mock-air") ? "AIR" : "SONNET";
    const counter = stats[providerId];
    counter.requests += 1;
    if (balanceExhausted.has(providerId)) {
      counter.quota429 += 1;
      return QUOTA_429();
    }
    if (inFlight[providerId] >= limits[providerId]) {
      counter.busy429 += 1;
      return BUSY_429();
    }
    inFlight[providerId] += 1;
    try {
      // 生成期间连接全程占用(流式),加 ±10% 抖动模拟真实生成时长差异
      await sleep(latencyMs * (0.9 + 0.2 * rng()));
      counter.success += 1;
      return new Response(sseBody, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" }
      });
    } finally {
      inFlight[providerId] -= 1;
    }
  }
  return { mockFetch, stats };
}

// ─── 测试同款内存基建(与 worker.test.js 同口径)────────────────────────────
class MemoryKV {
  constructor(initial = new Map()) {
    this.values = initial;
  }
  async get(key, options) {
    const value = this.values.get(key);
    if (value === undefined || value === null) return null;
    if (options && options.type === "json") {
      try { return JSON.parse(value); } catch { return value; }
    }
    return value;
  }
  async put(key, value, options) {
    this.values.set(key, String(value));
    void options;
  }
  async delete(key) {
    this.values.delete(key);
  }
}

function makeFakeQuotaCounterDO() {
  const store = new Map();
  const pad = (n) => String(n).padStart(2, "0");
  const bucketOf = (ms) => {
    const d = new Date(ms);
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}`;
  };
  const stub = {
    async fetch(req) {
      const body = JSON.parse(await req.text());
      const url = new URL(req.url);
      if (url.pathname === "/consume-rolling") {
        const hourMs = Date.parse(`${body.hour}:00:00.000Z`);
        let windowUsed = 0;
        for (let i = 0; i < body.windowHours; i += 1) {
          windowUsed += store.get(`${bucketOf(hourMs - i * 3600 * 1000)}:${body.key}`) || 0;
        }
        if (windowUsed >= body.limit) {
          return new Response(JSON.stringify({ allowed: false, used: windowUsed, remaining: 0, limit: body.limit, taken: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
        }
        const take = Math.min(body.amount || 1, body.limit - windowUsed);
        const storageKey = `${body.hour}:${body.key}`;
        store.set(storageKey, (store.get(storageKey) || 0) + take);
        return new Response(JSON.stringify({ allowed: true, used: windowUsed + take, remaining: body.limit - windowUsed - take, limit: body.limit, taken: take }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      const storageKey = `${body.date}:${body.key}`;
      const current = store.get(storageKey) || 0;
      if (url.pathname === "/refund") {
        const decrement = Math.min(body.amount || 1, current);
        const newUsed = current - decrement;
        if (newUsed === 0) store.delete(storageKey);
        else store.set(storageKey, newUsed);
        return new Response(JSON.stringify({ refunded: decrement, used: newUsed }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      // 默认 /consume
      const limit = body.limit;
      if (current >= limit) {
        return new Response(JSON.stringify({ allowed: false, used: current, remaining: 0, limit, taken: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      const take = Math.min(body.amount || 1, limit - current);
      const newUsed = current + take;
      store.set(storageKey, newUsed);
      return new Response(JSON.stringify({ allowed: true, used: newUsed, remaining: limit - newUsed, limit, taken: take }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
  };
  return {
    idFromName(name) { return { name }; },
    get() { return stub; },
    _store: store
  };
}

// ─── 日志拦截:log.js 全部走 console.*,解析 event 计数,默认不打印──────
function makeLogCollector({ verbose }) {
  const events = new Map(); // "event" -> count
  const failures = new Map(); // "providerId|errorType" -> count
  const circuit = { opened: 0, reopened: 0, closed: 0, openMsByProvider: { AIR: 0, SONNET: 0 }, openSince: { AIR: null, SONNET: null } };
  let noCandidates503 = 0;
  const originals = {
    log: console.log,
    warn: console.warn,
    error: console.error
  };
  function handle(line) {
    let parsed;
    try { parsed = JSON.parse(line); } catch { return; }
    const name = parsed.event || "unknown";
    events.set(name, (events.get(name) || 0) + 1);
    if (name === "proxy.provider.call_failed") {
      const key = `${parsed.providerId}|${parsed.errorType}`;
      failures.set(key, (failures.get(key) || 0) + 1);
    } else if (name === "proxy.circuit.opened" || name === "proxy.circuit.reopened") {
      if (name === "proxy.circuit.opened") circuit.opened += 1;
      else circuit.reopened += 1;
      if (circuit.openSince[parsed.providerId] === null || circuit.openSince[parsed.providerId] === undefined) {
        circuit.openSince[parsed.providerId] = Date.now();
      }
    } else if (name === "proxy.circuit.closed") {
      circuit.closed += 1;
      if (circuit.openSince[parsed.providerId]) {
        circuit.openMsByProvider[parsed.providerId] += Date.now() - circuit.openSince[parsed.providerId];
        circuit.openSince[parsed.providerId] = null;
      }
    } else if (name === "proxy.selector.no_candidates") {
      noCandidates503 += 1;
    }
    if (verbose) {
      originals.log(line);
    }
  }
  console.log = (v) => handle(String(v));
  console.warn = (v) => handle(String(v));
  console.error = (v) => handle(String(v));
  return {
    restore() {
      console.log = originals.log;
      console.warn = originals.warn;
      console.error = originals.error;
    },
    done() {
      // 场景结束时仍在 open 的,把余下时长计入
      const now = Date.now();
      for (const id of Object.keys(circuit.openSince)) {
        if (circuit.openSince[id]) {
          circuit.openMsByProvider[id] += now - circuit.openSince[id];
          circuit.openSince[id] = null;
        }
      }
      return { events, failures, circuit, noCandidates503 };
    }
  };
}

// ─── 场景执行────────────────────────────────────────────────────────────
const GATES = {
  open: {
    DAILY_REQUEST_LIMIT: "1000000",
    GLOBAL_DAILY_LIMIT: "100000000",
    IP_RATE_PER_MINUTE: "1000000",
    IP_DAILY_LIMIT: "1000000"
  },
  prod: {
    DAILY_REQUEST_LIMIT: "3",
    PAID_DAILY_LIMIT: "100",
    GLOBAL_DAILY_LIMIT: "5000",
    GLOBAL_BUDGET_WINDOW_HOURS: "6",
    IP_RATE_PER_MINUTE: "10",
    IP_DAILY_LIMIT: "500"
  }
};

function buildEnv({ gates, rateKv, stateKv, doBinding }) {
  return {
    APP_TOKEN: "loadtest-token",
    LOG_HASH_SALT: "loadtest-salt",
    PROVIDERS: JSON.stringify([
      {
        id: "ZAI_ANTHROPIC",
        type: "anthropic",
        url: "https://mock-sonnet.invalid/api/anthropic/v1/messages",
        model: "claude-sonnet-4-5-20250929",
        priority: 1,
        weight: 10,
        enabled: true,
        secretName: "PROVIDER_KEY_ZAI_ANTHROPIC_2",
        timeoutMs: 3000 // 30s / SCALE
      },
      {
        id: "ZAI_ANTHROPIC_AIR",
        type: "anthropic",
        url: "https://mock-air.invalid/api/anthropic/v1/messages",
        model: "glm-4.5-air",
        priority: 3,
        weight: 10,
        enabled: true,
        secretName: "PROVIDER_KEY_ZAI_ANTHROPIC",
        timeoutMs: 3000
      }
    ]),
    PROVIDER_KEY_ZAI_ANTHROPIC_2: "sonnet-key",
    PROVIDER_KEY_ZAI_ANTHROPIC: "air-key",
    AI_PROVIDER_MAX_ATTEMPTS: "2",
    // 时间缩放后的熔断参数(10s→1s,5min→30s);threshold 是计数不是时间,保持 5
    CIRCUIT_OPEN_THRESHOLD: "5",
    CIRCUIT_INITIAL_COOLDOWN_MS: String(10_000 / SCALE),
    CIRCUIT_MAX_COOLDOWN_MS: String(300_000 / SCALE),
    RATE_LIMIT_KV: rateKv,
    AI_PROVIDER_STATE_KV: stateKv,
    QUOTA_COUNTER_DO: doBinding
    // CACHE_RESULT_KV 故意不绑:压测 transcript 每人不同,且缓存命中会掩盖上游并发行为
  };
}

async function runScenario({ name, label, users, mode, gates, limitAir, limitSonnet, balanceExhausted, seed, verbose }) {
  // 模块级单例隔离(同 worker.test.js beforeEach 语义)
  _testResetHealth();
  _testResetAdminConfig();
  _testResetExtractionCache();
  _testResetAlertState();
  _testResetProbeCache();

  const rng = makeRng(seed);
  const rateKv = new MemoryKV();
  const stateKv = new MemoryKV();
  const doBinding = makeFakeQuotaCounterDO();
  // admin 钉头 = AIR(与线上 2026-09-22 灰度一致)
  await stateKv.put("config:providers_primary", JSON.stringify({ primaryId: "ZAI_ANTHROPIC_AIR", updatedAt: Date.now(), updatedBy: "loadtest" }));
  const env = buildEnv({ gates: GATES[gates], rateKv, stateKv, doBinding });

  const { mockFetch, stats: upstreamStats } = makeMockUpstream({
    limits: { AIR: limitAir, SONNET: limitSonnet },
    latencyMs: 6000 / SCALE,
    balanceExhausted,
    rng
  });

  const ctxPending = [];
  const ctx = { waitUntil(p) { ctxPending.push(Promise.resolve(p).catch(() => {})); } };

  const collector = makeLogCollector({ verbose });
  const userResults = [];

  const makeRequest = (i, attempt) => new Request("https://proxy.loadtest/v1/todo-extractions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-App-Token": "loadtest-token",
      "X-Device-ID": `loadtest-user-${i}`,
      // 每人独立 IP,避免撞 IP 限流(§2.2.3)
      "CF-Connecting-IP": `10.${Math.floor(i / 65536) % 256}.${Math.floor(i / 256) % 256}.${i % 256}`
    },
    body: JSON.stringify({
      transcript: `压测第 ${i} 号用户的待办事项 ${attempt}`,
      locale: "zh",
      stream: true
    })
  });

  // 客户端真实重试策略(TodoExtractorService):最多 3 次;退避 1s/2s + 0~30% 抖动
  // (×1/SCALE);503/5xx 重试;429 quota/ip_daily 不重试;velocity 429 仅当
  // retryAfter ≤ 8s 时重试。
  async function virtualUser(i, arriveAt) {
    const outcome = { user: i, success: false, attemptsUsed: 0, firstTrySuccess: false, durationMs: 0, failureKind: null };
    const startReal = Date.now();
    let nextDelayOverrideMs = null;
    for (let attempt = 0; attempt <= 2; attempt++) {
      if (attempt > 0) {
        let delayMs;
        if (nextDelayOverrideMs !== null) {
          delayMs = nextDelayOverrideMs;
          nextDelayOverrideMs = null;
        } else {
          const base = attempt === 1 ? 1000 / SCALE : 2000 / SCALE;
          delayMs = base * (1 + 0.3 * rng()); // 0~30% 抖动
        }
        await sleep(delayMs);
      }
      outcome.attemptsUsed = attempt + 1;
      let response;
      try {
        response = await handleRequest(makeRequest(i, attempt), env, ctx, mockFetch);
      } catch (error) {
        // handleRequest 自身不抛(全走 Response),防御性记录
        outcome.failureKind = `client_throw:${error?.name || "unknown"}`;
        break;
      }
      const bodyText = await response.text();
      if (response.status === 200) {
        outcome.success = true;
        if (attempt === 0) outcome.firstTrySuccess = true;
        break;
      }
      if (response.status === 429) {
        let body = {};
        try { body = JSON.parse(bodyText); } catch { body = {}; }
        if (body.error === "quota_exceeded") { outcome.failureKind = "quota_exceeded"; break; }
        const rateLimitType = response.headers.get("X-RateLimit-Type");
        if (rateLimitType === "ip_daily") { outcome.failureKind = "ip_daily"; break; }
        // .rateLimited(retryAfter):仅 retryAfter ∈ [0,8s] 且还有重试机会时继续
        const retryAfter = body.retryAfter ?? Number(response.headers.get("Retry-After") ?? NaN);
        const retryable = Number.isFinite(retryAfter) && retryAfter >= 0 && retryAfter <= 8 && attempt < 2;
        if (!retryable) { outcome.failureKind = `rate_limited:${rateLimitType || "generic"}`; break; }
        nextDelayOverrideMs = retryAfter * 1000 / SCALE;
        continue;
      }
      if (response.status >= 500 && response.status < 600) {
        // serviceUnavailable / apiServerError → 指数退避重试
        continue;
      }
      // 4xx 非限流(400/401/413…)→ 不重试
      outcome.failureKind = `status_${response.status}`;
      break;
    }
    outcome.durationMs = Date.now() - startReal;
    userResults.push(outcome);
    void arriveAt;
  }

  const scenarioStart = Date.now();
  const userPromises = [];
  if (mode === "burst") {
    for (let i = 0; i < users; i++) userPromises.push(virtualUser(i, scenarioStart));
  } else {
    // 一分钟内均匀到达(60s 真实 → 60_000/SCALE 模拟)
    const windowMs = 60_000 / SCALE;
    for (let i = 0; i < users; i++) {
      const offset = (windowMs * i) / users + (windowMs / users) * 0.5 * rng();
      userPromises.push(sleep(offset).then(() => virtualUser(i, scenarioStart + offset)));
    }
  }
  await Promise.all(userPromises);
  await Promise.all(ctxPending); // 排干 waitUntil(全局预算增量、KV 影子写)
  const wallMs = Date.now() - scenarioStart;
  const collected = collector.done();
  collector.restore();

  // ── 统计 ──
  const success = userResults.filter((u) => u.success);
  const pending = userResults.filter((u) => !u.success);
  const durations = userResults.map((u) => u.durationMs).sort((a, b) => a - b);
  const successDurations = success.map((u) => u.durationMs).sort((a, b) => a - b);
  const pick = (sorted, q) => (sorted.length === 0 ? null : sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]);
  const failureKinds = {};
  for (const u of pending) failureKinds[u.failureKind] = (failureKinds[u.failureKind] || 0) + 1;
  const attemptsHistogram = { 1: 0, 2: 0, 3: 0 };
  for (const u of userResults) attemptsHistogram[u.attemptsUsed] += 1;

  const result = {
    scenario: name,
    label,
    users,
    mode,
    gates,
    upstreamLimits: { AIR: limitAir, SONNET: limitSonnet },
    balanceExhausted: [...balanceExhausted],
    scale: SCALE,
    wallMsSim: wallMs,
    wallMsReal: wallMs * SCALE,
    immediateSuccessRate: success.filter((u) => u.firstTrySuccess).length / users,
    finalSuccessRate: success.length / users,
    pendingRate: pending.length / users,
    failureKinds,
    attemptsHistogram,
    latencyP50SimMs: pick(durations, 0.5),
    latencyP95SimMs: pick(durations, 0.95),
    successLatencyP50SimMs: pick(successDurations, 0.5),
    successLatencyP95SimMs: pick(successDurations, 0.95),
    upstream: upstreamStats,
    workerFailures: Object.fromEntries(collected.failures),
    circuit: {
      opened: collected.circuit.opened,
      reopened: collected.circuit.reopened,
      closed: collected.circuit.closed,
      openSimMs: collected.circuit.openMsByProvider,
      openRealMs: Object.fromEntries(Object.entries(collected.circuit.openMsByProvider).map(([k, v]) => [k, v * SCALE]))
    },
    zeroAttempt503: collected.noCandidates503,
    eventCounts: Object.fromEntries(collected.events)
  };
  return result;
}

// ─── CLI ─────────────────────────────────────────────────────────────────
const { values: args } = parseArgs({
  options: {
    users: { type: "string", default: "100" },
    mode: { type: "string", default: "burst" },
    gates: { type: "string", default: "open" },
    "limit-air": { type: "string", default: "10" },
    "limit-sonnet": { type: "string", default: "10" },
    balance: { type: "boolean", default: false }, // 单场景:--balance-exhausted AIR 的快捷方式
    matrix: { type: "boolean", default: false },
    label: { type: "string", default: "adhoc" },
    seed: { type: "string", default: "42" },
    verbose: { type: "boolean", default: false }
  }
});

const here = path.dirname(fileURLToPath(import.meta.url));
const resultsDir = path.join(here, "results");
mkdirSync(resultsDir, { recursive: true });

function printSummary(r) {
  const pct = (x) => `${(x * 100).toFixed(1)}%`;
  console.error(
    `[${r.label}] ${r.scenario}: 即时 ${pct(r.immediateSuccessRate)} / 最终 ${pct(r.finalSuccessRate)} / pending ${pct(r.pendingRate)}` +
    ` | AIR req=${r.upstream.AIR.requests} 429busy=${r.upstream.AIR.busy429} 429quota=${r.upstream.AIR.quota429} ok=${r.upstream.AIR.success}` +
    ` | SONNET req=${r.upstream.SONNET.requests} 429busy=${r.upstream.SONNET.busy429} ok=${r.upstream.SONNET.success}` +
    ` | 熔断 open=${r.circuit.opened} reopen=${r.circuit.reopened} 时长(真实s) AIR=${(r.circuit.openRealMs.AIR / 1000).toFixed(1)} SONNET=${(r.circuit.openRealMs.SONNET / 1000).toFixed(1)}` +
    ` | 0尝试503=${r.zeroAttempt503} | P95(真实s)=${(r.latencyP95SimMs * SCALE / 1000).toFixed(1)}`
  );
}

async function main() {
  const seed = Number(args.seed);
  const common = {
    limitAir: Number(args["limit-air"]),
    limitSonnet: Number(args["limit-sonnet"]),
    seed,
    verbose: args.verbose
  };
  const scenarios = [];
  if (args.matrix) {
    // §2.3 矩阵
    for (const n of [20, 50, 100, 200, 1000]) {
      scenarios.push({ name: `burst-${n}-open`, users: n, mode: "burst", gates: "open", balanceExhausted: new Set() });
    }
    for (const n of [100, 200, 500]) {
      scenarios.push({ name: `minute-${n}-open`, users: n, mode: "minute", gates: "open", balanceExhausted: new Set() });
    }
    // 生产真实闸门组(§2.2.4):单独报告闸门本身在高峰时拦掉多少
    for (const n of [100, 200, 500, 1000]) {
      scenarios.push({ name: `burst-${n}-prodgates`, users: n, mode: "burst", gates: "prod", balanceExhausted: new Set() });
    }
  }
  if (args.balance) {
    scenarios.push({ name: "burst-100-air-exhausted", users: 100, mode: "burst", gates: "open", balanceExhausted: new Set(["AIR"]) });
  }
  if (!args.matrix && !args.balance) {
    scenarios.push({
      name: `${args.mode}-${args.users}-${args.gates}`,
      users: Number(args.users),
      mode: args.mode,
      gates: args.gates,
      balanceExhausted: new Set()
    });
  }

  const all = [];
  for (const scenario of scenarios) {
    const result = await runScenario({ ...scenario, ...common, label: args.label });
    all.push(result);
    writeFileSync(path.join(resultsDir, `${args.label}-${result.scenario}.json`), JSON.stringify(result, null, 2));
    printSummary(result);
  }
  writeFileSync(path.join(resultsDir, `${args.label}-all.json`), JSON.stringify(all, null, 2));
  console.error(`\n${all.length} 个场景完成,JSON 落 ${resultsDir}/`);
}

main().then(
  () => {
    // AbortSignal.timeout 的定时器会把进程挂住最多 timeoutMs(3s),显式退出
    process.exit(0);
  },
  (error) => {
    console.error("loadtest failed:", error);
    process.exit(1);
  }
);
