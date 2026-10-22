// Provider candidate selector.
//
// Inputs:
//   - providerConfigs : ProviderConfig[] from config.js
//   - healthStore     : HealthStore (P4 onwards; null means "treat all as closed")
//   - now             : epoch ms (injectable for tests)
//   - options.maxAttempts : cap on candidate ENTRY count (default = filtered list length)
//   - options.random       : injectable RNG for deterministic cold-start weighted sampling
//   - options.primaryId    : admin override primary id — pinned to the FRONT of the
//                            candidate list if present (see worker.js admin override)
//
// Output: ordered ProviderConfig[] for executeWithFailover to walk in order.
// 每个 element 是「条目」(一家服务商 + 一个模型),携带 candidateKeys
// (熔断未开的可用 key 列表)供执行层做条目内选 key(R2:在途最少,并列随机)。
//
// Ordering (P5 = circuit-aware + latency-aware + cold-start weighted):
//   1. Drop disabled entries, entries without any usable key (secret 缺失), and
//      entries whose keys are ALL circuit-open. 熔断按 key 记账(A1 R1:healthId =
//      条目id#序号),条目只要还有一个非 open 的 key 就仍可服务。
//   2. Split remaining entries into:
//        warm    — closed AND has EWMA latency data  → sort by latency ascending
//        cold    — closed AND no latency data        → weighted random shuffle
//        halfOpen — half-open                        → defer to end (single-trial slot)
//      条目级判定从 per-key 快照聚合:
//        - 任一可用 key closed → 条目 closed;EWMA 取各 closed key 的最小值
//          (最快的健康 key 代表该条目当前能给的服务水平)。
//        - 全部可用 key half-open → 条目 half-open(单次试探槽,挑一个 key 试)。
//   3. Concatenate: [...warm, ...cold, ...halfOpen].
//   4. If options.primaryId matches a surviving candidate in the warm/cold portion,
//      move it to the front. Half-open candidates are NEVER promoted: deferring
//      them to the end is deliberate (single-trial slot) — pinning a half-open
//      provider to the front would make every request's first hop hit a provider
//      that may not have recovered, and with a small maxAttempts it would squeeze
//      healthy candidates out of the window entirely.
//      ⚠️ 没有这一步,admin override 只是改 priority 字段,而 warm 桶按延迟排序、
//      cold 桶排在 warm 之后 —— priority 在两条路径上都不起作用,override 静默失效
//      (2026-09-22 生产复现:warm 的旧主力永远压住 cold 的新主力)。
//   5. Cap at maxAttempts(条目数口径:key 级重试不占条目尝试数,A1 R4——
//      条目内换 key 由执行层完成,不经过这里的截断)。
//
// The two-bucket rule gives latency-priority when we have data, falls back to a
// weight-aware distribution when we don't — so cold starts don't hammer provider #1.
// The explicit primaryId pin is the ONLY way an admin override can beat the
// latency ordering; if the pinned provider is disabled / keyless / circuit-open,
// it already got dropped in step 1, and if it is half-open it stays deferred at
// the end — either way the pin is a no-op (fail-safe to P5 order).

const DEFAULT_MAX_ATTEMPTS = Infinity;

export async function pickCandidates(providerConfigs, healthStore = null, now = Date.now(), options = {}) {
  const random = options.random || Math.random;
  const warm = [];
  const cold = [];
  const halfOpen = [];

  for (const provider of providerConfigs) {
    if (provider.enabled === false) continue;
    // keys[] 形状见 config.js:secret 缺失的 key 在加载时已被剔除,
    // keys 为空 = 整条目无可用 key(等价于旧 apiKey="" 谓词)。
    // 旧形状条目(无 keys 数组,单测直造)回退合成单 key,healthId = 条目 id。
    const usableKeys = entryUsableKeys(provider);
    if (usableKeys.length === 0) continue;
    if (!healthStore) {
      cold.push(withCandidateKeys(provider, usableKeys));
      continue;
    }

    // 熔断按 key 记账:逐 key 取快照,聚合出条目级状态。
    const snapshots = await Promise.all(
      usableKeys.map((key) => healthStore.snapshot(key.healthId, now))
    );
    const openIdx = new Set(snapshots.flatMap((s, i) => (s.state === "open" ? [i] : [])));
    const nonOpenKeys = usableKeys.filter((_, i) => !openIdx.has(i));
    if (nonOpenKeys.length === 0) continue; // 全部 key 熔断 → 条目出局

    const closedLatencies = snapshots
      .filter((s) => s.state === "closed" && s.ewmaLatencyMs > 0)
      .map((s) => s.ewmaLatencyMs);
    const hasClosedKey = snapshots.some((s) => s.state === "closed");
    const candidate = withCandidateKeys(provider, nonOpenKeys);

    if (closedLatencies.length > 0) {
      warm.push({ provider: candidate, latency: Math.min(...closedLatencies) });
    } else if (hasClosedKey) {
      // 有 closed key(只是还没延迟样本)→ 条目是冷启动,不该因为有兄弟 key
      // 处于 half-open 就被 defer 到末尾——closed key 本可正常服务。
      cold.push(candidate);
    } else {
      // 非 open 的 key 全部 half-open → 条目 half-open(单次试探槽)
      halfOpen.push(candidate);
    }
  }

  const sortedWarm = warm
    .sort((a, b) => a.latency - b.latency)
    .map((entry) => entry.provider);

  const shuffledCold = weightedShuffle(cold, random);
  const sortedHalfOpen = sortByPriority(halfOpen);

  let combined = [...sortedWarm, ...shuffledCold, ...sortedHalfOpen];
  if (options.primaryId) {
    // admin override 钉头:被 override 的 provider 强制排最前。
    // 不在 combined 里(disabled/无 key/熔断 open 已被摘除)时是 no-op,fail-safe 回落 P5 顺序。
    // half-open 一律不钉(第三轮 review 新问题 4):它被 defer 到末尾是有意的
    // (单次试探槽)——钉到最前会让每个请求的第一跳都砸向疑似未恢复的 provider,
    // 叠加小的 maxAttempts 还会把健康候选挤出候选窗。正在灰度钉头新主力时,
    // 被钉者一熔断进 half-open 就是活场景,不是理论问题。
    const pinnable = sortedWarm.length + shuffledCold.length;
    const index = combined.findIndex((p) => p.id === options.primaryId);
    if (index > 0 && index < pinnable) {
      combined = [combined[index], ...combined.slice(0, index), ...combined.slice(index + 1)];
    }
  }
  const cap = resolveMaxAttempts(options.maxAttempts, combined.length);
  return combined.slice(0, cap);
}

// 浅拷贝 + 挂 candidateKeys(执行层条目内选 key 用)。不 mutate 原 config 对象:
// 同一 provider 对象可能被并发请求共享。
function withCandidateKeys(provider, keys) {
  return { ...provider, candidateKeys: keys };
}

// 条目的可用 key 列表(config.js 正常产出 keys[];旧形状/直造条目合成单 key)。
export function entryUsableKeys(entry) {
  if (Array.isArray(entry.keys)) {
    const withKey = entry.keys.filter((k) => k.apiKey);
    if (withKey.length > 0) return withKey;
  }
  if (entry.apiKey) {
    return [{ index: 0, secretName: entry.secretName, apiKey: entry.apiKey, healthId: entry.id }];
  }
  return [];
}

function sortByPriority(providers) {
  return providers.slice().sort((a, b) => {
    const pa = Number.isFinite(a.priority) ? a.priority : Number.MAX_SAFE_INTEGER;
    const pb = Number.isFinite(b.priority) ? b.priority : Number.MAX_SAFE_INTEGER;
    return pa - pb;
  });
}

// Efraimidis-Spirakis weighted sampling: assign each item a key random()^(1/w),
// then sort descending. Produces a weighted random permutation where high-weight
// items tend to appear earlier.
//
// When all providers have equal (or default) weights, weighted sampling would just
// produce noise — there's no signal in the weights. We fall back to priority order
// so cold starts are deterministic unless the operator has explicitly configured
// distinct weights to spread load.
function weightedShuffle(providers, random) {
  if (providers.length <= 1) {
    return providers.slice();
  }
  const weights = providers.map((p) => Number.isFinite(p.weight) && p.weight > 0 ? p.weight : 1);
  const allEqual = weights.every((w) => w === weights[0]);
  if (allEqual) {
    return sortByPriority(providers);
  }
  return providers
    .map((provider, index) => {
      const weight = weights[index];
      const draw = random();
      const key = draw > 0 ? Math.pow(draw, 1 / weight) : 0;
      return { provider, key };
    })
    .sort((a, b) => b.key - a.key)
    .map((entry) => entry.provider);
}

function resolveMaxAttempts(configured, available) {
  if (!Number.isFinite(configured) || configured <= 0) {
    return Math.min(available, DEFAULT_MAX_ATTEMPTS);
  }
  return Math.min(configured, available);
}
