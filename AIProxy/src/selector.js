// Provider candidate selector.
//
// Inputs:
//   - providerConfigs : ProviderConfig[] from config.js
//   - healthStore     : HealthStore (P4 onwards; null means "treat all as closed")
//   - now             : epoch ms (injectable for tests)
//   - options.maxAttempts : cap on candidate count (default = filtered list length)
//   - options.random       : injectable RNG for deterministic cold-start weighted sampling
//   - options.primaryId    : admin override primary id — pinned to the FRONT of the
//                            candidate list if present (see worker.js admin override)
//
// Output: ordered ProviderConfig[] for executeWithFailover to walk in order.
//
// Ordering (P5 = circuit-aware + latency-aware + cold-start weighted):
//   1. Drop disabled providers, providers without a configured secret, and providers
//      whose circuit is `open`.
//   2. Split remaining into:
//        warm    — closed AND has EWMA latency data  → sort by latency ascending
//        cold    — closed AND no latency data        → weighted random shuffle
//        halfOpen — half-open                         → defer to end (single-trial slot)
//   3. Concatenate: [...warm, ...cold, ...halfOpen].
//   4. If options.primaryId matches a surviving candidate, move it to the front.
//      ⚠️ 没有这一步,admin override 只是改 priority 字段,而 warm 桶按延迟排序、
//      cold 桶排在 warm 之后 —— priority 在两条路径上都不起作用,override 静默失效
//      (2026-09-22 生产复现:warm 的旧主力永远压住 cold 的新主力)。
//   5. Cap at maxAttempts.
//
// The two-bucket rule gives latency-priority when we have data, falls back to a
// weight-aware distribution when we don't — so cold starts don't hammer provider #1.
// The explicit primaryId pin is the ONLY way an admin override can beat the
// latency ordering; if the pinned provider is disabled / keyless / circuit-open,
// it already got dropped in step 1 and the pin is a no-op (fail-safe to P5 order).

const DEFAULT_MAX_ATTEMPTS = Infinity;

export async function pickCandidates(providerConfigs, healthStore = null, now = Date.now(), options = {}) {
  const random = options.random || Math.random;
  const warm = [];
  const cold = [];
  const halfOpen = [];

  for (const provider of providerConfigs) {
    if (provider.enabled === false) continue;
    if (!provider.apiKey) continue;
    if (!healthStore) {
      cold.push(provider);
      continue;
    }
    const snapshot = await healthStore.snapshot(provider.id, now);
    if (snapshot.state === "open") continue;
    if (snapshot.state === "half-open") {
      halfOpen.push(provider);
      continue;
    }
    if (snapshot.ewmaLatencyMs > 0) {
      warm.push({ provider, latency: snapshot.ewmaLatencyMs });
    } else {
      cold.push(provider);
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
    const index = combined.findIndex((p) => p.id === options.primaryId);
    if (index > 0) {
      combined = [combined[index], ...combined.slice(0, index), ...combined.slice(index + 1)];
    }
  }
  const cap = resolveMaxAttempts(options.maxAttempts, combined.length);
  return combined.slice(0, cap);
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
