// Provider candidate selector.
//
// Inputs:
//   - providerConfigs : ProviderConfig[] from config.js
//   - healthStore     : HealthStore (P4 onwards; null means "treat all as closed")
//   - now             : epoch ms (injectable for tests)
//   - options.maxAttempts : cap on candidate count (default = filtered list length)
//   - options.random       : injectable RNG for deterministic cold-start weighted sampling
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
//   4. Cap at maxAttempts.
//
// The two-bucket rule gives latency-priority when we have data, falls back to a
// weight-aware distribution when we don't — so cold starts don't hammer provider #1.

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

  const combined = [...sortedWarm, ...shuffledCold, ...sortedHalfOpen];
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
