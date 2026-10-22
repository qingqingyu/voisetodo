// A2:每 key 并发闸门的 Worker 侧客户端(docs/capacity-scenario-a-task.md §2)。
//
// 目标:让 proxy 在本地就知道哪个 key 有空位,而不是把请求打出去等上游 429。
// 每 key 一个 Durable Object 实例(name = "gate:<条目id>#<序号>",QuotaCounter
// 类的 /gate/* 端点,见 src/do/quota-counter.js),负责该 key 的在途计数。
//
// 租约制:acquire 返回带过期时间的租约(leaseMs = 条目 timeoutMs + 10s,由调用方
// 传入);请求结束(成功/失败/客户端断开)都 release;漏 release 由 DO 侧 TTL 回收。
//
// fail-open:任何一次闸门 DO 调用失败或超时(callTimeoutMs,默认 200ms)→ 跳过
// 闸门直接打上游并记 warn。闸门是优化,不能变成新的单点故障;上游 429 的现有
// 处理(provider.js 忙 429 不计熔断 + 条目内换 key 重试)会兜底。
//
// 每请求 DO 调用次数(结果文档 §改动摘要要求写明):
//   常规路径 = keys.length 次 /gate/count(并行)+ 1 次 acquire + 1 次 release;
//   全部满且无备选条目时,每 pollMs 再来一轮 count(直至 maxWaitMs)。

import { logInfo, logWarn, errorFields } from "./log.js";

export const KEY_GATE_DEFAULT_MAX_WAIT_MS = 3000;
export const KEY_GATE_DEFAULT_POLL_MS = 100;
export const KEY_GATE_DEFAULT_CALL_TIMEOUT_MS = 200;
// 租约时长的固定余量:lease = timeoutMs + 10s(任务书 §2.2)。超时后上游 fetch
// 早已被 abort,名额最多被多占 10s 就会被 TTL 回收。
export const KEY_GATE_LEASE_MARGIN_MS = 10_000;

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export class KeyGate {
  constructor({ binding, maxWaitMs = KEY_GATE_DEFAULT_MAX_WAIT_MS, pollMs = KEY_GATE_DEFAULT_POLL_MS, callTimeoutMs = KEY_GATE_DEFAULT_CALL_TIMEOUT_MS, leaseMarginMs = KEY_GATE_LEASE_MARGIN_MS, random = Math.random, sleep = defaultSleep, now = Date.now } = {}) {
    this.binding = binding || null;
    this.maxWaitMs = maxWaitMs;
    this.pollMs = pollMs;
    this.callTimeoutMs = callTimeoutMs;
    this.leaseMarginMs = leaseMarginMs;
    this.random = random;
    this.sleep = sleep;
    this.now = now;
  }

  /// 条目是否走闸门:配置了 maxConcurrencyPerKey 且 DO binding 存在。
  /// 未配置的条目(如按量付费不限并发)不走闸门(任务书 §2.2.6)。
  enabledFor(entry) {
    return Boolean(this.binding)
      && Number.isInteger(entry?.maxConcurrencyPerKey)
      && entry.maxConcurrencyPerKey > 0
      && Array.isArray(entry?.candidateKeys)
      && entry.candidateKeys.length > 0;
  }

  /// 条目内选 key 并拿租约(R2:在途最少,并列随机)。
  ///
  /// 返回三种结果之一:
  ///   { lease, key }          正常:lease 可能是 null(fail-open 时,无租约直接放行)
  ///   { failOpen: true, key } DO 调用失败 → 跳过闸门,随机选 key
  ///   { full: true }          全部 key 满:wait=true 时已等满 maxWaitMs
  ///
  /// wait=false(还有备选条目)时只试一轮不等待——条目池满应立刻 failover 到
  /// 下一条目(那里可能有空位),等待只该发生在「没有别的条目可去」时。
  /// 这个解释记录在 docs/capacity-scenario-a-results.md(任务书 §2.2.4 的
  /// 「全部 key 满」按「最后可用条目」口径执行)。
  async acquireEntrySlot(entry, keys, { wait }) {
    const startedAt = this.now();
    const deadline = startedAt + this.maxWaitMs;
    while (true) {
      const counts = await Promise.all(keys.map((key) => this.count(entry, key)));
      if (counts.some((c) => c === null)) {
        // 任何一路 DO 读失败 → 整个选 key 过程 fail-open(不能拿残缺的
        // 在途数当排序依据,否则会把流量压到「读不到」的 key 上)。
        logWarn("proxy.gate.call_failed", {
          providerId: entry.id,
          action: "count",
          reason: "count_unavailable"
        });
        return { failOpen: true, key: pickRandom(keys, this.random) };
      }
      // 修复1(2026-10-22):按在途数升序(并列随机,保持 R2 均衡),跳过已满的 key,
      // 依次申请——第一个被抢满就试下一个,不再把整个条目判满。
      // 改前:只申请「在途最少」那一个,被拒(读数与申请之间被抢)就直接 full,
      // 同条目其他有空位的 key 白白闲置(多条目时还会白白切条目)。
      const limit = entry.maxConcurrencyPerKey;
      const order = keys
        .map((key, i) => ({ key, count: counts[i], tie: this.random() }))
        .filter((cand) => cand.count < limit)
        .sort((a, b) => a.count - b.count || a.tie - b.tie);
      for (const cand of order) {
        const acquire = await this.acquire(entry, cand.key, {
          limit,
          leaseMs: entry.timeoutMs + this.leaseMarginMs
        });
        if (acquire === null) {
          logWarn("proxy.gate.call_failed", {
            providerId: entry.id,
            action: "acquire",
            keySlot: keySlotId(entry, cand.key),
            reason: "acquire_unavailable"
          });
          return { failOpen: true, key: cand.key };
        }
        if (acquire.allowed) {
          // 拿到名额时记录等待耗时(从进闸门到 acquire 成功)。≈0 = 有空位直进;
          // >0 = 池满轮询等来的。观测闸门压力分布(loadtest 也从这里取 P50/P95)。
          const waitMs = this.now() - startedAt;
          if (waitMs > 0) {
            logInfo("proxy.gate.slot_acquired_after_wait", {
              providerId: entry.id,
              keySlot: keySlotId(entry, cand.key),
              waitMs
            });
          }
          return { lease: new GateLease(this, entry, cand.key, acquire.leaseId), key: cand.key, waitMs };
        }
        // 被拒(count 与 acquire 之间被抢满)→ 试下一个 key
      }
      // 全部被拒或全部已满
      if (!wait || this.now() >= deadline) {
        return { full: true };
      }
      const remaining = deadline - this.now();
      await this.sleep(Math.min(this.pollMs, Math.max(1, remaining)));
    }
  }

  async count(entry, key) {
    try {
      const body = await this.callDo(entry, key, "/gate/count", {});
      return Number.isFinite(body?.inFlight) ? body.inFlight : null;
    } catch (error) {
      return null;
    }
  }

  async acquire(entry, key, { limit, leaseMs }) {
    try {
      return await this.callDo(entry, key, "/gate/acquire", { limit, leaseMs });
    } catch (error) {
      return null;
    }
  }

  async release(entry, key, leaseId) {
    try {
      return await this.callDo(entry, key, "/gate/release", { leaseId });
    } catch (error) {
      // release 失败只 warn:租约 TTL(timeoutMs + 10s)会回收名额,不永久泄漏。
      logWarn("proxy.gate.release_failed", {
        providerId: entry.id,
        keySlot: keySlotId(entry, key),
        leaseId,
        ...errorFields(error)
      });
      return null;
    }
  }

  async callDo(entry, key, path, body) {
    const stub = this.binding.get(this.binding.idFromName(gateDoName(entry, key)));
    const response = await stub.fetch(new Request(`https://key-gate.do${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.callTimeoutMs)
    }));
    if (!response.ok) {
      throw new Error(`gate DO ${path} returned ${response.status}`);
    }
    return await response.json();
  }

  /// 等待统计(loadtest 用):某条目各 key 的在途数快照,DO 不可用返回 null。
  async snapshotInFlight(entry, keys) {
    const counts = await Promise.all(keys.map((key) => this.count(entry, key)));
    return counts.some((c) => c === null) ? null : counts;
  }
}

export class GateLease {
  constructor(gate, entry, key, leaseId) {
    this.gate = gate;
    this.entry = entry;
    this.key = key;
    this.leaseId = leaseId;
    this.released = false;
    this.acquiredAt = gate.now();
  }

  /// 幂等 release。所有 return/throw 路径都该调它;漏掉的由租约 TTL 兜底。
  async release() {
    if (this.released) return;
    this.released = true;
    await this.gate.release(this.entry, this.key, this.leaseId);
  }
}

function gateDoName(entry, key) {
  return `gate:${keySlotId(entry, key)}`;
}

// 修复3:key 身份用 secret 名(条目id#<secretName>)而非列表序号——
// 调整 secretNames 顺序或删掉中间某个 key,DO 名/日志/健康记录都不漂移。
function keySlotId(entry, key) {
  return `${entry.id}#${key.secretName}`;
}

function pickRandom(items, random) {
  if (items.length === 1) return items[0];
  return items[Math.floor(random() * items.length)];
}

/// 从 env 构造 KeyGate;无 QUOTA_COUNTER_DO binding 时返回 null(闸门整体不启用)。
export function makeKeyGateFromEnv(env) {
  if (!env?.QUOTA_COUNTER_DO) return null;
  const readPositiveInt = (name, fallback) => {
    const value = Number(env[name]);
    return Number.isInteger(value) && value > 0 ? value : fallback;
  };
  return new KeyGate({
    binding: env.QUOTA_COUNTER_DO,
    maxWaitMs: readPositiveInt("KEY_GATE_MAX_WAIT_MS", KEY_GATE_DEFAULT_MAX_WAIT_MS),
    pollMs: readPositiveInt("KEY_GATE_POLL_MS", KEY_GATE_DEFAULT_POLL_MS),
    callTimeoutMs: readPositiveInt("KEY_GATE_CALL_TIMEOUT_MS", KEY_GATE_DEFAULT_CALL_TIMEOUT_MS),
    // 正常不改:lease = timeoutMs + 10s(任务书 §2.2)。loadtest 时间缩放时按 SCALE 调小。
    leaseMarginMs: readPositiveInt("KEY_GATE_LEASE_MARGIN_MS", KEY_GATE_LEASE_MARGIN_MS)
  });
}
