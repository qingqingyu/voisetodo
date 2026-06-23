// HealthStore: per-provider health state with circuit breaker.
//
// Backed by `env.AI_PROVIDER_STATE_KV` (a dedicated namespace — kept separate from
// RATE_LIMIT_KV so health writes can't evict quota entries and vice versa). Falls
// back to per-isolate in-memory state when KV is absent or fails, so failover still
// works even if the operator hasn't wired the namespace yet.
//
// Circuit breaker (state machine):
//   - state="closed"    → healthy; failure count tracked
//   - consecutiveFailures >= 3 (retryable)        → state="open" + cooldownMs
//   - now >= openedAt + cooldownMs (read-time)    → reported as "half-open"
//   - half-open trial success                     → state="closed" (reset)
//   - half-open trial failure                     → state="open", cooldownMs *= 2 (cap 5m)
//   - non-retryable 4xx (request_body)            → NOT counted
//
// Explicit `state` field (rather than encoding via openedAt=0) avoids the ambiguity
// between "never opened" and "opened at epoch zero" that breaks time-mocked tests.
//
// Write throttling: state transitions always write. Sample-only updates write when
// sampleCount crosses the configured interval (every 10 successes) — keeps KV cost
// bounded while still converging latency stats for P5.

import { logInfo, logWarn, errorFields } from "./log.js";

const CIRCUIT_OPEN_THRESHOLD = 3;
const CIRCUIT_INITIAL_COOLDOWN_MS = 30_000;
const CIRCUIT_MAX_COOLDOWN_MS = 5 * 60_000;
const SUCCESS_WRITE_INTERVAL = 10;
const RECORD_TTL_SECONDS = 24 * 3600;
const LATENCY_EWMA_ALPHA = 0.3;
const LATENCY_DRIFT_WRITE_RATIO = 0.2;

export class HealthStore {
  constructor({ kv = null, now = Date.now } = {}) {
    this.kv = kv || null;
    this.now = now;
    this.memory = new Map();
    this.degraded = false;
  }

  // Update KV binding for a new request's env without losing in-memory state.
  // Cloudflare Workers pass a fresh `env` per request, but isolates are reused,
  // so the module-level HealthStore keeps its memory Map across requests.
  updateKv(kv) {
    this.kv = kv || null;
    this.degraded = false;
  }

  // Test-only: clear in-memory state to isolate tests.
  reset() {
    this.memory.clear();
    this.degraded = false;
  }

  async circuitState(providerId, atNow = this.now()) {
    const record = await this.load(providerId);
    return classifyState(record, atNow);
  }

  // Snapshot exposes the read-side fields selectors need (state + latency). Single KV
  // read per provider per request — circuitState and snapshot share the same load.
  async snapshot(providerId, atNow = this.now()) {
    const record = await this.load(providerId);
    return {
      state: classifyState(record, atNow),
      ewmaLatencyMs: record.ewmaLatencyMs || 0,
      sampleCount: record.sampleCount || 0,
      lastSuccessAt: record.lastSuccessAt || 0
    };
  }

  async recordSuccess(providerId, latencyMs = 0) {
    const now = this.now();
    const record = await this.load(providerId);
    const previousState = classifyState(record, now);
    const previousEwma = record.ewmaLatencyMs || 0;

    record.sampleCount += 1;
    record.lastSuccessAt = now;
    record.lastErrorType = "";
    record.consecutiveFailures = 0;
    record.updatedAt = now;

    // EWMA: only meaningful on closed providers. Open/half-open trials that succeed
    // are not representative of steady-state latency (cold reconnect, different path).
    if (previousState === "closed" && Number.isFinite(latencyMs) && latencyMs > 0) {
      record.ewmaLatencyMs = previousEwma > 0
        ? (1 - LATENCY_EWMA_ALPHA) * previousEwma + LATENCY_EWMA_ALPHA * latencyMs
        : latencyMs;
    }

    if (previousState === "half-open" || previousState === "open") {
      // Half-open trial succeeded (or stale open we still want to close) → close.
      record.state = "closed";
      record.openedAt = 0;
      record.cooldownMs = 0;
      await this.save(providerId, record, { force: true });
      logInfo("proxy.circuit.closed", { providerId });
      return;
    }

    // Write throttle: also force a write if latency drifted enough to matter.
    const driftRatio = previousEwma > 0
      ? Math.abs(record.ewmaLatencyMs - previousEwma) / previousEwma
      : 1;
    const force = driftRatio >= LATENCY_DRIFT_WRITE_RATIO;
    await this.save(providerId, record, { force });
  }

  async recordFailure(providerId, errorType) {
    const now = this.now();
    const record = await this.load(providerId);
    const previousState = classifyState(record, now);

    record.lastFailureAt = now;
    record.lastErrorType = String(errorType || "unknown");
    record.consecutiveFailures += 1;
    record.updatedAt = now;

    if (previousState === "half-open") {
      // Half-open trial failed — re-open with doubled cooldown (capped).
      record.state = "open";
      record.openedAt = now;
      record.cooldownMs = nextCooldown(record.cooldownMs);
      logWarn("proxy.circuit.reopened", {
        providerId,
        errorType: record.lastErrorType,
        cooldownMs: record.cooldownMs
      });
    } else if (previousState === "closed" && record.consecutiveFailures >= CIRCUIT_OPEN_THRESHOLD) {
      record.state = "open";
      record.openedAt = now;
      record.cooldownMs = nextCooldown(record.cooldownMs || 0);
      logWarn("proxy.circuit.opened", {
        providerId,
        errorType: record.lastErrorType,
        consecutiveFailures: record.consecutiveFailures,
        cooldownMs: record.cooldownMs
      });
    }

    // Failure writes are always forced — the breaker needs consecutive failure
    // count to accumulate across requests/isolates, otherwise the threshold
    // can never be reached. Cost is bounded by failure rate; healthy providers
    // produce zero writes.
    await this.save(providerId, record, { force: true });
  }

  async load(providerId) {
    const memoryRecord = this.memory.get(providerId);
    if (!this.kv || this.degraded) {
      return memoryRecord ? clone(memoryRecord) : freshRecord();
    }
    try {
      const raw = await this.kv.get(`health:${providerId}`);
      if (!raw) {
        return memoryRecord ? clone(memoryRecord) : freshRecord();
      }
      const kvRecord = normaliseRecord(JSON.parse(raw));
      if (memoryRecord && recordFreshness(memoryRecord) >= recordFreshness(kvRecord)) {
        return clone(memoryRecord);
      }
      return kvRecord;
    } catch (error) {
      if (!this.degraded) {
        this.degraded = true;
        logWarn("health.kv.read_failed_degraded", { providerId, ...errorFields(error) });
      }
      return memoryRecord ? clone(memoryRecord) : freshRecord();
    }
  }

  async save(providerId, record, { force = false } = {}) {
    // Always keep in-memory copy fresh so subsequent reads in the same isolate see it.
    this.memory.set(providerId, clone(record));

    if (!this.kv || this.degraded) {
      return;
    }
    if (!force && !shouldThrottledWrite(record)) {
      return;
    }
    try {
      await this.kv.put(`health:${providerId}`, JSON.stringify(record), {
        expirationTtl: RECORD_TTL_SECONDS
      });
    } catch (error) {
      if (!this.degraded) {
        this.degraded = true;
        logWarn("health.kv.write_failed_degraded", { providerId, ...errorFields(error) });
      }
    }
  }
}

function freshRecord() {
  return {
    state: "closed",
    consecutiveFailures: 0,
    openedAt: 0,
    cooldownMs: 0,
    ewmaLatencyMs: 0,
    sampleCount: 0,
    lastSuccessAt: 0,
    lastFailureAt: 0,
    lastErrorType: "",
    updatedAt: 0
  };
}

function normaliseRecord(parsed) {
  // Merge defensively: an older record in KV might miss newer fields.
  const record = { ...freshRecord(), ...(parsed && typeof parsed === "object" ? parsed : {}) };
  if (record.state !== "open" && record.state !== "closed" && record.state !== "half-open") {
    record.state = "closed";
  }
  if (!Number.isFinite(record.updatedAt) || record.updatedAt <= 0) {
    record.updatedAt = recordFreshness(record);
  }
  return record;
}

function clone(record) {
  return { ...record };
}

function classifyState(record, now) {
  if (record.state !== "open") {
    return record.state === "half-open" ? "half-open" : "closed";
  }
  // state === "open": check whether cooldown has elapsed.
  const cooldown = record.cooldownMs > 0 ? record.cooldownMs : CIRCUIT_INITIAL_COOLDOWN_MS;
  return now - record.openedAt >= cooldown ? "half-open" : "open";
}

function nextCooldown(current) {
  if (!current || current <= 0) {
    return CIRCUIT_INITIAL_COOLDOWN_MS;
  }
  return Math.min(current * 2, CIRCUIT_MAX_COOLDOWN_MS);
}

function recordFreshness(record) {
  return Math.max(
    Number(record?.updatedAt) || 0,
    Number(record?.lastSuccessAt) || 0,
    Number(record?.lastFailureAt) || 0,
    Number(record?.openedAt) || 0
  );
}

function shouldThrottledWrite(record) {
  if (record.sampleCount > 0 && record.sampleCount % SUCCESS_WRITE_INTERVAL === 0) {
    return true;
  }
  return false;
}
