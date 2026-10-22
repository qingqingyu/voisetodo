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
//   node loadtest/run.mjs --scenario-a --label a-main              # A 场景容量(capacity-scenario-a-task.md §5)
// 结果 JSON 落 loadtest/results/<label>-<name>.json,摘要表打 stdout。
// loadtest/ 不进 npm test(§2.4)。
//
// A 场景(--scenario-a):单条目多 key 池 × 泊松到达(1000 人/60s)× 闸门开/关对比。
// mock 上游按 Authorization 分 key 记账,每 key 独立并发上限;闸门开 = 条目配
// maxConcurrencyPerKey(走 DO /gate/*),闸门关 = 只靠上游 429 + key 级重试。
// 验收线(§5.5):最终 ≥99% / 即时 ≥95% / 用户侧 P95 ≤10s(真实时间)/ 闸门开时上游忙 429≈0。

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

// ─── A 场景:单条目多 key 池 mock 上游(按 Authorization 分 key 记账) ────────
// 上游视角:每 key 独立并发上限,流式生成期间占连接(latencyMs ± 10% 抖动);
// 超限返回忙 429(z.ai 1302 同款体,openai adapter 归类 status_429 不计熔断)。
function makePoolUpstream({ keyCount, limit, latencyMs, rng }) {
  const stats = {};
  const statOf = (key) => stats[key] || (stats[key] = { requests: 0, busy429: 0, success: 0, inFlight: 0, maxInFlight: 0 });
  const extraction = JSON.stringify({
    todos: [{
      title: "A场景压测待办", detail: "loadtest-a", due_date: null, due_hint: null, due_time: null,
      time_bucket: null, recurrence_rule: null, recurrence_end: null, due_date_basis: null,
      reminder_times: null, reminder_offset_minutes: null, priority: "normal", category_hint: "other"
    }],
    ignored: ""
  });
  const encoder = new TextEncoder();
  const ssePayload = [
    `data: ${JSON.stringify({ choices: [{ delta: { content: extraction } }] })}`,
    `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] })}`,
    "data: [DONE]",
    ""
  ].join("\n\n");

  async function mockFetch(url, init) {
    const key = String(init?.headers?.Authorization || "").replace(/^Bearer /, "");
    const s = statOf(key);
    s.requests += 1;
    if (s.inFlight >= limit) {
      s.busy429 += 1;
      return BUSY_429();
    }
    s.inFlight += 1;
    s.maxInFlight = Math.max(s.maxInFlight, s.inFlight);
    let released = false;
    let timer = null;
    const dec = () => {
      if (!released) { released = true; s.inFlight -= 1; }
    };
    const body = new ReadableStream({
      start(controller) {
        timer = setTimeout(() => {
          try {
            s.success += 1;
            controller.enqueue(encoder.encode(ssePayload));
            controller.close();
          } finally {
            dec();
          }
        }, Math.max(1, Math.round(latencyMs * (0.9 + 0.2 * rng()))));
      },
      cancel() {
        if (timer) clearTimeout(timer);
        dec();
      }
    });
    return new Response(body, { status: 200, headers: { "Content-Type": "text/event-stream" } });
  }
  return { mockFetch, stats };
}

function buildPoolEnv({ gates, rateKv, stateKv, doBinding, pool }) {
  const secretNames = Array.from({ length: pool.keys }, (_, i) => `POOL_KEY_${i}`);
  const entry = {
    id: "KEY_POOL",
    type: "openai",
    url: "https://mock-pool.invalid/v1/chat/completions",
    model: "glm-pool",
    priority: 1,
    weight: 1,
    enabled: true,
    secretNames,
    timeoutMs: 3000 // 30s / SCALE
  };
  if (pool.gate) entry.maxConcurrencyPerKey = pool.perKeyLimit;
  return {
    APP_TOKEN: "loadtest-token",
    LOG_HASH_SALT: "loadtest-salt",
    PROVIDERS: JSON.stringify([entry]),
    ...Object.fromEntries(secretNames.map((name, i) => [name, `pool-key-${i}`])),
    AI_PROVIDER_MAX_ATTEMPTS: "2",
    CIRCUIT_OPEN_THRESHOLD: "5",
    CIRCUIT_INITIAL_COOLDOWN_MS: String(10_000 / SCALE),
    CIRCUIT_MAX_COOLDOWN_MS: String(300_000 / SCALE),
    // A2 闸门参数(全部按 SCALE 缩放;lease 余量 10s→1s)
    KEY_GATE_MAX_WAIT_MS: String(3000 / SCALE),
    KEY_GATE_POLL_MS: String(100 / SCALE),
    KEY_GATE_LEASE_MARGIN_MS: String(10_000 / SCALE),
    KEY_GATE_CALL_TIMEOUT_MS: "200",
    RATE_LIMIT_KV: rateKv,
    AI_PROVIDER_STATE_KV: stateKv,
    QUOTA_COUNTER_DO: doBinding,
    ...gates
  };
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
  // A2 闸门:每 DO 实例(gate:<entry>#<i>)独立租约账本 + 调用日志(ops/s 统计)。
  const gateLeases = new Map();      // name -> Map(leaseId -> expiresAt)
  const gateLeaseSeq = new Map();    // name -> counter
  const gateCallLog = [];            // { t, name, path }
  const gateLeasesOf = (name) => {
    if (!gateLeases.has(name)) gateLeases.set(name, new Map());
    return gateLeases.get(name);
  };
  const stub = {
    async fetch(req, doName = "default") {
      const body = JSON.parse(await req.text());
      const url = new URL(req.url);
      if (url.pathname.startsWith("/gate/")) {
        gateCallLog.push({ t: Date.now(), name: doName, path: url.pathname });
        const leases = gateLeasesOf(doName);
        const sweep = () => {
          const now = Date.now();
          for (const [leaseId, expiresAt] of leases) {
            if (expiresAt <= now) leases.delete(leaseId);
          }
        };
        if (url.pathname === "/gate/acquire") {
          sweep();
          if (leases.size >= body.limit) {
            return new Response(JSON.stringify({ allowed: false, inFlight: leases.size }), { status: 200, headers: { "Content-Type": "application/json" } });
          }
          const seq = (gateLeaseSeq.get(doName) || 0) + 1;
          gateLeaseSeq.set(doName, seq);
          const leaseId = `lease-${seq}`;
          leases.set(leaseId, Date.now() + body.leaseMs);
          return new Response(JSON.stringify({ allowed: true, inFlight: leases.size + 1, leaseId }), { status: 200, headers: { "Content-Type": "application/json" } });
        }
        if (url.pathname === "/gate/release") {
          sweep();
          return new Response(JSON.stringify({ released: leases.delete(body.leaseId) }), { status: 200, headers: { "Content-Type": "application/json" } });
        }
        if (url.pathname === "/gate/count") {
          sweep();
          return new Response(JSON.stringify({ inFlight: leases.size }), { status: 200, headers: { "Content-Type": "application/json" } });
        }
        return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
      }
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
  const perNameGates = new Map();
  const gateStubFor = (name) => {
    if (!perNameGates.has(name)) {
      perNameGates.set(name, { fetch: (req) => stub.fetch(req, name) });
    }
    return perNameGates.get(name);
  };
  return {
    idFromName(name) { return { name }; },
    get(id = { name: "default" }) {
      return {
        fetch: (req) => (new URL(req.url).pathname.startsWith("/gate/")
          ? gateStubFor(id.name).fetch(req)
          : stub.fetch(req))
      };
    },
    _store: store,
    _gateCallLog: gateCallLog,
    _gateLeases: gateLeases
  };
}

// ─── 日志拦截:log.js 全部走 console.*,解析 event 计数,默认不打印──────
function makeLogCollector({ verbose }) {
  const events = new Map(); // "event" -> count
  const failures = new Map(); // "providerId|errorType" -> count
  // 键是真实 providerId(如 ZAI_ANTHROPIC_AIR),动态创建
  const circuit = { opened: 0, reopened: 0, closed: 0, openMsByProvider: {}, openSince: {} };
  let noCandidates503 = 0;
  // A 场景闸门指标:等待耗时分布(slot_acquired_after_wait 事件)与池满计数
  const gateWaitMs = [];
  let gatePoolFull = 0;
  let gateCallFailed = 0;
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
      if (circuit.openSince[parsed.providerId] == null) {
        circuit.openSince[parsed.providerId] = Date.now();
        circuit.openMsByProvider[parsed.providerId] = circuit.openMsByProvider[parsed.providerId] || 0;
      }
    } else if (name === "proxy.circuit.closed") {
      circuit.closed += 1;
      if (circuit.openSince[parsed.providerId]) {
        circuit.openMsByProvider[parsed.providerId] += Date.now() - circuit.openSince[parsed.providerId];
        circuit.openSince[parsed.providerId] = null;
      }
    } else if (name === "proxy.selector.no_candidates") {
      noCandidates503 += 1;
    } else if (name === "proxy.gate.slot_acquired_after_wait") {
      gateWaitMs.push(Number(parsed.waitMs) || 0);
    } else if (name === "proxy.gate.pool_full") {
      gatePoolFull += 1;
    } else if (name === "proxy.gate.call_failed") {
      gateCallFailed += 1;
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
      return { events, failures, circuit, noCandidates503, gateWaitMs, gatePoolFull, gateCallFailed };
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

async function runScenario({ name, label, users, mode, gates, limitAir, limitSonnet, balanceExhausted, seed, verbose, trailingUsers = 0, trailingDelaySimMs = 0, pool = null }) {
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

  let env;
  let mockFetch;
  let upstreamStats;
  if (pool) {
    // A 场景:单条目 key 池(无 admin 钉头,单条目无意义)
    env = buildPoolEnv({ gates: GATES[gates], rateKv, stateKv, doBinding, pool });
    const poolUpstream = makePoolUpstream({
      keyCount: pool.keys,
      limit: pool.perKeyLimit,
      latencyMs: 6000 / SCALE,
      rng
    });
    mockFetch = poolUpstream.mockFetch;
    upstreamStats = poolUpstream.stats;
  } else {
    // admin 钉头 = AIR(与线上 2026-09-22 灰度一致)
    await stateKv.put("config:providers_primary", JSON.stringify({ primaryId: "ZAI_ANTHROPIC_AIR", updatedAt: Date.now(), updatedBy: "loadtest" }));
    env = buildEnv({ gates: GATES[gates], rateKv, stateKv, doBinding });
    const airUpstream = makeMockUpstream({
      limits: { AIR: limitAir, SONNET: limitSonnet },
      latencyMs: 6000 / SCALE,
      balanceExhausted,
      rng
    });
    mockFetch = airUpstream.mockFetch;
    upstreamStats = airUpstream.stats;
  }

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
  async function virtualUser(i, arriveAt, isTrailing = false) {
    const outcome = { user: i, success: false, attemptsUsed: 0, firstTrySuccess: false, durationMs: 0, failureKind: null, trailing: isTrailing };
    const startReal = Date.now();
    let nextDelayOverrideMs = null;
    let lastStatus = null;
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
      lastStatus = response.status;
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
    if (!outcome.success && outcome.failureKind === null) {
      // 重试全部耗尽(503/5xx 连续)→ 客户端原文落 pending,前台恢复再补解析
      outcome.failureKind = `exhausted_status_${lastStatus}`;
    }
    userResults.push(outcome);
    void arriveAt;
  }

  const scenarioStart = Date.now();
  const userPromises = [];
  if (mode === "poisson") {
    // A 场景:60s(真实)内泊松到达。指数间隔 -ln(U)/λ;绝对时间调度
    // (每个用户独立 setTimeout 到目标时刻),避免顺序 sleep 的累计漂移。
    const windowMs = 60_000 / SCALE;
    const rate = users / windowMs;
    let t = 0;
    for (let i = 0; i < users; i++) {
      t += -Math.log(1 - rng()) / rate;
      const target = scenarioStart + t;
      userPromises.push(
        (async () => {
          const delay = target - Date.now();
          if (delay > 0) await sleep(delay);
          return virtualUser(i, t);
        })()
      );
    }
  } else if (mode === "burst") {
    for (let i = 0; i < users; i++) userPromises.push(virtualUser(i, scenarioStart));
    // 尾随用户:主峰后 delaySimMs(模拟 ms)到达——度量「高峰刚过,代理是否还
    // 活着」。改前的伤害面正是这里:熔断冷却期(10s)内到达的用户吃 0 尝试 503。
    if (trailingUsers > 0) {
      const delayMs = trailingDelaySimMs / SCALE;
      for (let j = 0; j < trailingUsers; j++) {
        const idx = users + j;
        userPromises.push(sleep(delayMs).then(() => virtualUser(idx, scenarioStart + delayMs, true)));
      }
    }
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

  // ── 统计 ──(主峰口径:成功率/直方图/分位数只算主峰用户;尾随用户单列)
  const mainUsers = userResults.filter((u) => !u.trailing);
  const success = mainUsers.filter((u) => u.success);
  const pending = mainUsers.filter((u) => !u.success);
  const durations = mainUsers.map((u) => u.durationMs).sort((a, b) => a - b);
  const successDurations = success.map((u) => u.durationMs).sort((a, b) => a - b);
  const pick = (sorted, q) => (sorted.length === 0 ? null : sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]);
  const failureKinds = {};
  for (const u of pending) failureKinds[u.failureKind] = (failureKinds[u.failureKind] || 0) + 1;
  const attemptsHistogram = { 1: 0, 2: 0, 3: 0 };
  for (const u of mainUsers) attemptsHistogram[u.attemptsUsed] += 1;
  const trailingUsersTotal = userResults.filter((u) => u.trailing);
  const trailingSuccess = trailingUsersTotal.filter((u) => u.success).length;

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
    trailing: trailingUsersTotal.length
      ? { users: trailingUsersTotal.length, successRate: trailingSuccess / trailingUsersTotal.length }
      : null,
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
    // 场景结束时的熔断记录快照(health:<id> KV 原文):state/consecutiveFailures/
    // lastErrorType 是「是否被计入熔断」的直接证据
    finalHealthRecords: {
      ZAI_ANTHROPIC_AIR: JSON.parse((await stateKv.get("health:ZAI_ANTHROPIC_AIR")) || "null"),
      ZAI_ANTHROPIC: JSON.parse((await stateKv.get("health:ZAI_ANTHROPIC")) || "null")
    },
    zeroAttempt503: collected.noCandidates503,
    eventCounts: Object.fromEntries(collected.events)
  };

  if (pool) {
    const perKey = Object.entries(upstreamStats).map(([key, s]) => ({
      key,
      requests: s.requests,
      busy429: s.busy429,
      success: s.success,
      maxInFlight: s.maxInFlight
    }));
    const waits = collected.gateWaitMs.slice().sort((a, b) => a - b);
    const pickQ = (sorted, q) => (sorted.length === 0 ? null : sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]);
    // DO ops/s 峰值:按 1s(模拟)桶聚合 gate 调用
    const buckets = new Map();
    for (const call of doBinding._gateCallLog) {
      const bucket = Math.floor((call.t - scenarioStart) / 1000);
      buckets.set(bucket, (buckets.get(bucket) || 0) + 1);
    }
    const doPeakOpsPerSecSim = buckets.size ? Math.max(...buckets.values()) : 0;
    result.keyPool = {
      keys: pool.keys,
      perKeyLimit: pool.perKeyLimit,
      gateEnabled: Boolean(pool.gate),
      totalSlots: pool.keys * pool.perKeyLimit
    };
    result.upstreamPerKey = perKey;
    result.gateMetrics = {
      waitedAcquires: waits.length,
      waitP50SimMs: pickQ(waits, 0.5),
      waitP95SimMs: pickQ(waits, 0.95),
      poolFullEvents: collected.gatePoolFull,
      callFailedEvents: collected.gateCallFailed,
      doPeakOpsPerSecSim,
      doPeakOpsPerSecReal: doPeakOpsPerSecSim / SCALE
    };
    result.keyPoolMaxInFlight = Math.max(0, ...perKey.map((k) => k.maxInFlight));
    result.upstreamBusy429Total = perKey.reduce((sum, k) => sum + k.busy429, 0);
  }
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
    trailing: { type: "boolean", default: false },
    "scenario-a": { type: "boolean", default: false },
    "a-users": { type: "string", default: "1000" },
    "a-keys": { type: "string", default: "13" },
    "a-limit": { type: "string", default: "10" },
    "a-100-keys": { type: "string", default: "10" }, // 名额=100 组的 key 数(× a-limit)
    label: { type: "string", default: "adhoc" },
    seed: { type: "string", default: "42" },
    verbose: { type: "boolean", default: false }
  }
});

const here = path.dirname(fileURLToPath(import.meta.url));
const resultsDir = path.join(here, "results");
mkdirSync(resultsDir, { recursive: true });

// A 场景摘要 + 验收判定(§5.5:最终≥99% / 即时≥95% / P95真实≤10s / 闸门开→busy429≈0)
function printScenarioA(r) {
  const pct = (x) => `${(x * 100).toFixed(1)}%`;
  const p95RealS = ((r.latencyP95SimMs ?? 0) * SCALE / 1000).toFixed(1);
  const limit = r.keyPool.perKeyLimit;
  const busy = r.upstreamBusy429Total ?? 0;
  const checks = [
    r.finalSuccessRate >= 0.99,
    r.immediateSuccessRate >= 0.95,
    (r.latencyP95SimMs ?? Infinity) * SCALE <= 10_000,
    ...(r.keyPool.gateEnabled ? [busy <= Math.max(2, Math.round(r.users * 0.001))] : [])
  ];
  const pass = checks.every(Boolean);
  const wait = r.gateMetrics;
  console.error(
    `[${r.label}] ${r.scenario}: 即时 ${pct(r.immediateSuccessRate)} / 最终 ${pct(r.finalSuccessRate)} / P95(真实s)=${p95RealS}` +
    ` | 上游 busy429=${busy} maxKeyInFlight=${r.keyPoolMaxInFlight}/${limit}` +
    ` | 闸门: 等待acquire=${wait.waitedAcquires} waitP95(sim)=${wait.waitP95SimMs ?? "-"}ms poolFull=${wait.poolFullEvents} failOpen=${wait.callFailedEvents}` +
    ` DO峰值=${wait.doPeakOpsPerSecSim}ops/s(sim)/${wait.doPeakOpsPerSecReal.toFixed(1)}(real)` +
    ` | 验收 ${pass ? "PASS" : "FAIL " + checks.map((c, i) => (c ? "" : ["最终<99%", "即时<95%", "P95>10s", "busy429≠0"][i]).trim()).filter(Boolean).join(",")}`
  );
}

function printSummary(r) {
  const pct = (x) => `${(x * 100).toFixed(1)}%`;
  const openS = Object.entries(r.circuit.openRealMs)
    .map(([id, ms]) => `${id.replace("ZAI_ANTHROPIC", "S").replace("_AIR", "")}=${(Number(ms) / 1000).toFixed(1)}s`)
    .join(" ");
  console.error(
    `[${r.label}] ${r.scenario}: 即时 ${pct(r.immediateSuccessRate)} / 最终 ${pct(r.finalSuccessRate)} / pending ${pct(r.pendingRate)}` +
    ` | AIR req=${r.upstream.AIR.requests} 429busy=${r.upstream.AIR.busy429} 429quota=${r.upstream.AIR.quota429} ok=${r.upstream.AIR.success}` +
    ` | SONNET req=${r.upstream.SONNET.requests} 429busy=${r.upstream.SONNET.busy429} ok=${r.upstream.SONNET.success}` +
    ` | 熔断 open=${r.circuit.opened} reopen=${r.circuit.reopened} 时长(真实s) ${openS || "无"}` +
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
  if (args.trailing) {
    // 主峰 100 人 + 5s(模拟)后 20 个尾随用户:度量熔断冷却期内的伤害面
    scenarios.push({ name: "burst-100-trail20", users: 100, mode: "burst", gates: "open", balanceExhausted: new Set(), trailingUsers: 20, trailingDelaySimMs: 5000 });
  }
  if (args["scenario-a"]) {
    const aUsers = Number(args["a-users"]);
    const aKeys = Number(args["a-keys"]);
    const aLimit = Number(args["a-limit"]);
    const a100Keys = Number(args["a-100-keys"]);
    scenarios.push(
      { name: `a-poisson-${aUsers}-gate-on-${aKeys}x${aLimit}`, users: aUsers, mode: "poisson", gates: "open", balanceExhausted: new Set(), pool: { keys: aKeys, perKeyLimit: aLimit, gate: true } },
      { name: `a-poisson-${aUsers}-gate-off-${aKeys}x${aLimit}`, users: aUsers, mode: "poisson", gates: "open", balanceExhausted: new Set(), pool: { keys: aKeys, perKeyLimit: aLimit, gate: false } },
      { name: `a-poisson-${aUsers}-slots${a100Keys * aLimit}-gate-on`, users: aUsers, mode: "poisson", gates: "open", balanceExhausted: new Set(), pool: { keys: a100Keys, perKeyLimit: aLimit, gate: true } },
      { name: `a-poisson-${aUsers}-slots${a100Keys * aLimit}-gate-off`, users: aUsers, mode: "poisson", gates: "open", balanceExhausted: new Set(), pool: { keys: a100Keys, perKeyLimit: aLimit, gate: false } }
    );
  }
  if (!args.matrix && !args.balance && !args["scenario-a"]) {
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
    if (scenario.pool) printScenarioA(result);
    else printSummary(result);
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
