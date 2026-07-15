import { loadProviders } from "./src/config.js";
import { ProxyHTTPError } from "./src/errors.js";
import { HealthStore } from "./src/health.js";
import { logInfo, logWarn, logError, errorFields } from "./src/log.js";
import { executeWithFailover } from "./src/provider.js";
import { pickCandidates } from "./src/selector.js";
import { normalizeProviderStream } from "./src/stream.js";
import { verifySubscriptionJWS, APPLE_ROOT_CA_G3_SHA256 } from "./src/subscription.js";

const MAX_BODY_BYTES = 16 * 1024;
const MAX_TRANSCRIPT_CHARS = 4000;
const MAX_VOCABULARY_HINTS = 30;
const MAX_VOCABULARY_HINT_CHARS = 32;
const MAX_TELEMETRY_BODY_BYTES = 256 * 1024;
const MAX_TELEMETRY_EVENTS_PER_BATCH = 100;
const TELEMETRY_RETENTION_DAYS = 90;

// Module-level HealthStore: isolates are reused across requests in Cloudflare Workers,
// so this keeps in-memory circuit-breaker / EWMA state alive between requests without
// requiring KV on every read. KV binding is refreshed per-request via updateKv().
const sharedHealthStore = new HealthStore();

// Test-only export: allows tests to reset module-level health state between runs.
export function _testResetHealth() {
  sharedHealthStore.reset();
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, ctx, fetch);
  },
  async scheduled(event, env, ctx) {
    ctx.waitUntil(handleScheduled(env));
  }
};

export async function handleRequest(request, env = {}, ctx = {}, fetchImpl = fetch) {
  const requestContext = await makeRequestContext(request, env);
  logInfo("proxy.request.received", requestContext);
  try {
    const url = new URL(request.url);

    // Telemetry 路由：批量上报匿名事件到 D1
    if (url.pathname === "/v1/telemetry/events") {
      return await handleTelemetryBatch(request, env, requestContext);
    }

    if (url.pathname !== "/v1/todo-extractions") {
      return finishRequest(new Response("Not Found", { status: 404 }), requestContext, { reason: "not_found" });
    }
    if (request.method !== "POST") {
      return finishRequest(new Response("Method Not Allowed", { status: 405 }), requestContext, { reason: "method_not_allowed" });
    }

    const authError = validateAppToken(request, env);
    if (authError) {
      logWarn("proxy.auth.failed", {
        ...requestContext,
        status: authError.response.status,
        reason: authError.reason
      });
      return finishRequest(authError.response, requestContext, { reason: authError.reason });
    }
    logInfo("proxy.auth.ok", requestContext);

    const declaredLength = Number(request.headers.get("content-length") || "0");
    if (declaredLength > MAX_BODY_BYTES) {
      return finishRequest(new Response("Request too large", { status: 413 }), requestContext, {
        reason: "declared_body_too_large",
        declaredLength
      });
    }

    const payload = await readPayload(request);
    const transcript = String(payload.transcript || "").trim();
    if (!transcript) {
      return finishRequest(new Response("Missing transcript", { status: 400 }), requestContext, { reason: "missing_transcript" });
    }
    if (transcript.length > MAX_TRANSCRIPT_CHARS) {
      return finishRequest(new Response("Transcript too large", { status: 413 }), requestContext, {
        reason: "transcript_too_large",
        transcriptChars: transcript.length
      });
    }

    const locale = normalizeLocale(payload.locale);
    const stream = payload.stream === true;
    const vocabularyHints = normalizeVocabularyHints(payload.vocabularyHints);
    requestContext.locale = locale;
    requestContext.stream = stream;
    requestContext.transcriptChars = transcript.length;
    requestContext.vocabularyHintCount = vocabularyHints.length;
    logInfo("proxy.payload.accepted", requestContext);

    const quotaState = await enforceDailyLimit(request, env, requestContext);
    await enforcePerIpLimit(request, env, requestContext);
    await enforceGlobalBudget(env, requestContext);

    // enforceDailyLimit 现在总会返回 resetDate（无论是否 skipped），
    // 直接复用作为 today 注入 prompt，避免重复调用 resolveQuotaDate 产生重复漂移校验日志。
    // 防御性检查：若未来 enforceDailyLimit 重构遗漏 resetDate，立即抛错而非静默注入 undefined。
    const todayDate = quotaState.resetDate;
    if (!todayDate) {
      throw new ProxyHTTPError(500, "enforceDailyLimit returned no resetDate", {
        errorType: "invariant_violation",
        body: { error: "invariant_violation", detail: "resetDate missing" }
      });
    }

    sharedHealthStore.updateKv(env.AI_PROVIDER_STATE_KV || null);

    let providers;
    try {
      providers = loadProviders(env, {
        onSecretMissing: ({ id, secretName }) => {
          logWarn("proxy.provider.secret_missing", { ...requestContext, providerId: id, secretName });
        }
      });
    } catch (error) {
      logError("proxy.providers.config_failed", { ...requestContext, ...errorFields(error) });
      return finishRequest(new Response("AI proxy failed", { status: 500 }), requestContext, { error: "providers_config_invalid" });
    }
    if (providers.length === 0) {
      logError("proxy.providers.empty", { ...requestContext });
      return finishRequest(new Response("AI proxy failed", { status: 500 }), requestContext, { error: "providers_empty" });
    }

    const candidates = await pickCandidates(providers, sharedHealthStore, Date.now(), {
      maxAttempts: resolveMaxAttempts(env)
    });
    if (candidates.length === 0) {
      logError("proxy.selector.no_candidates", { ...requestContext });
      // All filtered out (missing keys or disabled) — distinct from config-invalid.
      return finishRequest(new Response("AI proxy failed", { status: 503 }), requestContext, { error: "no_providers_available" });
    }
    requestContext.candidateCount = candidates.length;

    const personalHints = typeof payload.personalHints === "string" ? payload.personalHints.trim() : null;
    const params = { transcript, locale, vocabularyHints, stream, today: todayDate, personalHints };
    const result = await executeWithFailover(candidates, params, fetchImpl, requestContext, {
      healthStore: sharedHealthStore,
      onResponse: stream
        ? ({ response, provider }) => validateProviderStreamBody(response, provider, requestContext)
        : ({ response, provider, adapter }) => readProviderText(response, provider, adapter, requestContext)
    });
    requestContext.provider = result.provider.type;
    requestContext.providerId = result.provider.id;

    if (stream) {
      const response = new Response(normalizeProviderStream(
        result.response.body,
        result.provider,
        result.adapter,
        requestContext,
        {
          onSuccess: result.confirmSuccess,
          onFailure: () => result.confirmFailure("stream")
        }
      ), {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream; charset=utf-8",
          "Cache-Control": "no-store",
          "Connection": "keep-alive",
          ...quotaHeaders(quotaState)
        }
      });
      return finishRequest(response, requestContext, { streamingBodyContinues: true });
    }

    const text = result.bodyResult.text;
    await result.confirmSuccess();
    logInfo("proxy.provider.text_success", { ...requestContext, provider: result.provider.type, responseChars: text.length });
    return finishRequest(new Response(text, {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        ...quotaHeaders(quotaState)
      }
    }), requestContext, { responseChars: text.length });
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      if (error.body !== null) {
        logWarn("proxy.request.http_error", { ...requestContext, status: error.status, rateLimitType: error.rateLimitType || null, ...errorFields(error) });
        const structured = new Response(JSON.stringify(error.body), {
          status: error.status,
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            ...(error.headers || {})
          }
        });
        return finishRequest(structured, requestContext, { error: error.body.error || error.message });
      }
      const clientMessage = error.status >= 500 ? "AI proxy failed" : error.message;
      logWarn("proxy.request.http_error", { ...requestContext, status: error.status, ...errorFields(error) });
      return finishRequest(new Response(clientMessage, { status: error.status }), requestContext, { error: clientMessage });
    }
    logError("proxy.request.failed", { ...requestContext, ...errorFields(error) });
    return finishRequest(new Response("AI proxy failed", { status: 502 }), requestContext, { error: "AI proxy failed" });
  }
}

function resolveMaxAttempts(env) {
  const configured = Number(env.AI_PROVIDER_MAX_ATTEMPTS);
  if (!Number.isFinite(configured) || configured <= 0) {
    return undefined;
  }
  return Math.floor(configured);
}

// MARK: - Telemetry batch handler

export async function handleTelemetryBatch(request, env, requestContext) {
  if (request.method !== "POST") {
    return finishRequest(new Response("Method Not Allowed", { status: 405 }), requestContext, { reason: "method_not_allowed" });
  }

  const authError = validateAppToken(request, env);
  if (authError) {
    logWarn("telemetry.auth.failed", { ...requestContext, status: authError.response.status, reason: authError.reason });
    return finishRequest(authError.response, requestContext, { reason: authError.reason });
  }

  if (!env.TELEMETRY_DB) {
    logWarn("telemetry.db_not_configured", requestContext);
    return finishRequest(new Response("Telemetry DB not configured", { status: 503 }), requestContext, { reason: "db_not_configured" });
  }

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (declaredLength > MAX_TELEMETRY_BODY_BYTES) {
    return finishRequest(new Response("Request too large", { status: 413 }), requestContext, {
      reason: "telemetry_body_too_large",
      declaredLength
    });
  }

  const payload = await readPayloadWithLimit(request, MAX_TELEMETRY_BODY_BYTES);
  const originalCount = Array.isArray(payload.events) ? payload.events.length : 0;
  const rawEvents = Array.isArray(payload.events) ? payload.events.slice(0, MAX_TELEMETRY_EVENTS_PER_BATCH) : [];
  if (rawEvents.length === 0) {
    return finishRequest(new Response("No events", { status: 400 }), requestContext, { reason: "no_events" });
  }

  const validEvents = rawEvents.filter(isValidTelemetryEvent);
  if (validEvents.length === 0) {
    logWarn("telemetry.no_valid_events", { ...requestContext, rawCount: rawEvents.length });
    return finishRequest(new Response("No valid events", { status: 400 }), requestContext, { reason: "no_valid_events" });
  }

  // 设备级配额（默认 500/天，可通过 TELEMETRY_DAILY_LIMIT 配置）
  const quotaResult = await enforceTelemetryQuota(env, requestContext.deviceId, validEvents.length, requestContext);
  const acceptedEvents = validEvents.slice(0, quotaResult.acceptable);
  const dropped = originalCount - acceptedEvents.length;

  const receivedAt = Date.now();
  const stmt = env.TELEMETRY_DB.prepare(
    `INSERT INTO telemetry_events
       (received_at, event_name, event_timestamp, session_id, device_id, app_version, ios_version, params)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );
  const statements = acceptedEvents.map((event) => stmt.bind(
    receivedAt,
    String(event.name),
    Number(event.timestamp) || receivedAt,
    String(event.sessionID || "missing"),
    requestContext.deviceId,  // 用 requestContext 的 sha256 hash，不信任 client 提交的 deviceID
    String(event.appVersion || "unknown"),
    String(event.iosVersion || "unknown"),
    JSON.stringify(event.params || {})
  ));
  await env.TELEMETRY_DB.batch(statements);

  logInfo("telemetry.events.accepted", {
    ...requestContext,
    accepted: acceptedEvents.length,
    dropped,
    quotaRemaining: quotaResult.remainingAfter
  });

  return finishRequest(new Response(JSON.stringify({
    accepted: acceptedEvents.length,
    dropped
  }), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
  }), requestContext, {
    accepted: acceptedEvents.length,
    dropped
  });
}

function isValidTelemetryEvent(event) {
  if (!event || typeof event !== "object") return false;
  if (typeof event.name !== "string" || event.name.length === 0 || event.name.length > 64) return false;
  if (typeof event.timestamp !== "number" || !Number.isFinite(event.timestamp)) return false;
  // params 上限保护
  const params = event.params;
  if (params !== undefined && params !== null) {
    if (typeof params !== "object" || Array.isArray(params)) return false;
    const entries = Object.entries(params);
    if (entries.length > 32) return false;
    for (const [key, value] of entries) {
      if (typeof key !== "string" || key.length > 64) return false;
      if (typeof value !== "string" || value.length > 256) return false;
    }
  }
  return true;
}

async function enforceTelemetryQuota(env, hashedDeviceId, requested, requestContext) {
  const limit = Number(env.TELEMETRY_DAILY_LIMIT || 500);
  if (!env.RATE_LIMIT_KV) {
    logInfo("telemetry.quota.skipped", { ...requestContext, reason: "kv_not_configured" });
    return { acceptable: requested, remainingAfter: Infinity };
  }
  if (!Number.isFinite(limit) || limit <= 0) {
    logWarn("telemetry.quota.skipped", { ...requestContext, reason: "invalid_limit", configuredLimit: env.TELEMETRY_DAILY_LIMIT });
    return { acceptable: requested, remainingAfter: Infinity };
  }

  const today = new Date().toISOString().slice(0, 10);
  const key = `telemetry-quota:${today}:${hashedDeviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  const remaining = Math.max(0, limit - current);
  if (remaining === 0) {
    logWarn("telemetry.quota.exceeded", { ...requestContext, current, limit });
    throw new ProxyHTTPError(429, "Telemetry daily quota exceeded");
  }
  const acceptable = Math.min(requested, remaining);
  await env.RATE_LIMIT_KV.put(key, String(current + acceptable), { expirationTtl: 36 * 60 * 60 });
  logInfo("telemetry.quota.incremented", { ...requestContext, current: current + acceptable, limit });
  return { acceptable, remainingAfter: limit - current - acceptable };
}

async function readPayloadWithLimit(request, maxBytes) {
  try {
    const text = await readRequestTextWithLimit(request, maxBytes);
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      throw error;
    }
    throw new ProxyHTTPError(400, "Invalid JSON", { cause: error });
  }
}

// MARK: - Scheduled handler (90 天 GC)

export async function handleScheduled(env) {
  if (!env.TELEMETRY_DB) {
    logInfo("telemetry.cron.skipped", { reason: "db_not_configured" });
    return;
  }
  const cutoff = Date.now() - TELEMETRY_RETENTION_DAYS * 24 * 3600 * 1000;
  try {
    const result = await env.TELEMETRY_DB.prepare("DELETE FROM telemetry_events WHERE received_at < ?")
      .bind(cutoff)
      .run();
    logInfo("telemetry.cron.gc_done", { cutoff, deleted: result.meta?.changes ?? "unknown" });
  } catch (error) {
    logError("telemetry.cron.gc_failed", errorFields(error));
  }
}

async function readPayload(request) {
  try {
    const text = await readRequestTextWithLimit(request, MAX_BODY_BYTES);
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      throw error;
    }
    throw new ProxyHTTPError(400, "Invalid JSON", { cause: error });
  }
}

async function readRequestTextWithLimit(request, maxBytes) {
  if (!request.body) {
    return "";
  }

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let totalBytes = 0;
  let text = "";

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel("Request too large");
        throw new ProxyHTTPError(413, "Request too large");
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } finally {
    reader.releaseLock();
  }
}

function validateAppToken(request, env) {
  if (!env.APP_TOKEN) {
    if (env.ALLOW_UNAUTHENTICATED_PROXY === "true") {
      return null;
    }
    return {
      response: new Response("AI proxy failed", { status: 500 }),
      reason: "app_token_not_configured"
    };
  }
  const provided = request.headers.get("X-App-Token") || "";
  const expected = String(env.APP_TOKEN);
  if (provided === expected || provided === `Bearer ${expected}`) {
    return null;
  }
  return {
    response: new Response("Unauthorized", { status: 401 }),
    reason: "unauthorized"
  };
}

// 免费档每日上限（DAILY_REQUEST_LIMIT）与 Pro 档每日上限（PAID_DAILY_LIMIT）。
// 配额 key 由客户端本地日期 + 设备摘要构成：发起即计数（含后续 AI 调用失败），
// 避免靠重试绕过计费。代理是唯一可信强制点，客户端只负责展示。
async function enforceDailyLimit(request, env, requestContext) {
  // 即使配额未启用也预先解析 quotaDate，让调用方（today 注入）能复用而无需重复调用
  // resolveQuotaDate（避免重复漂移校验日志）。
  const { date: quotaDate, source } = resolveQuotaDate(request, requestContext);
  if (!env.RATE_LIMIT_KV || !env.DAILY_REQUEST_LIMIT) {
    logInfo("proxy.quota.skipped", { ...requestContext, reason: "not_configured" });
    return { skipped: true, resetDate: quotaDate, dateSource: source };
  }
  const freeLimit = Number(env.DAILY_REQUEST_LIMIT);
  if (!Number.isFinite(freeLimit) || freeLimit <= 0) {
    logWarn("proxy.quota.skipped", { ...requestContext, reason: "invalid_limit", configuredLimit: env.DAILY_REQUEST_LIMIT });
    return { skipped: true, resetDate: quotaDate, dateSource: source };
  }

  const { tier, limit, productId } = await resolveSubscriptionTier(request, env, requestContext);
  // requestContext.deviceId 已加盐 sha256，避免 KV 落明文设备号且与日志口径一致。
  const quotaKey = `quota:${quotaDate}:${requestContext.deviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(quotaKey) || "0");
  if (current >= limit) {
    logWarn("proxy.quota.exceeded", { ...requestContext, quotaKey, quotaDate, dateSource: source, plan: tier, productId, current, limit, remaining: 0 });
    throw new ProxyHTTPError(429, "Daily quota exceeded", {
      errorType: "quota_exceeded",
      rateLimitType: "quota",
      body: { error: "quota_exceeded", tier, remaining: 0, resetAt: quotaDate },
      headers: {
        "X-RateLimit-Type": "quota",
        "Retry-After": String(secondsUntilNextLocalDay(quotaDate)),
        ...quotaHeaders({ plan: tier, limit, used: current, remaining: 0, resetDate: quotaDate })
      }
    });
  }
  const used = current + 1;
  await env.RATE_LIMIT_KV.put(quotaKey, String(used), { expirationTtl: 36 * 60 * 60 });
  const remaining = Math.max(0, limit - used);
  logInfo("proxy.quota.incremented", { ...requestContext, quotaKey, quotaDate, dateSource: source, plan: tier, productId, limit, used, remaining });
  return { skipped: false, plan: tier, limit, used, remaining, resetDate: quotaDate };
}

// 解析配额日期：优先信任客户端 X-Local-Date（设备时区 YYYY-MM-DD），但做格式与漂移校验。
// 格式非法/缺失 → 回退服务端 UTC 日期 + 记 invalid_local_date 日志（不静默）。
// 漂移 > 1 天（典型伪造到未来提前重置）→ 回退 UTC + 记 local_date_drift_rejected。
// 漂移容忍 ±1 天兼顾跨时区用户的合法边界。
function resolveQuotaDate(request, requestContext) {
  const serverToday = new Date().toISOString().slice(0, 10);
  const raw = (request.headers.get("X-Local-Date") || "").trim();
  if (!raw || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    logInfo("proxy.quota.local_date_invalid", { ...requestContext, reason: "invalid_local_date", hasHeader: raw.length > 0 });
    return { date: serverToday, source: "server_utc" };
  }
  const localMs = Date.parse(`${raw}T00:00:00.000Z`);
  const serverMs = Date.parse(`${serverToday}T00:00:00.000Z`);
  if (!Number.isFinite(localMs) || !Number.isFinite(serverMs)) {
    logInfo("proxy.quota.local_date_invalid", { ...requestContext, reason: "invalid_local_date", localDate: raw });
    return { date: serverToday, source: "server_utc" };
  }
  const driftDays = Math.abs(localMs - serverMs) / (24 * 3600 * 1000);
  if (driftDays > 1) {
    logWarn("proxy.quota.local_date_drift_rejected", { ...requestContext, reason: "local_date_drift_rejected", localDate: raw, serverDate: serverToday, driftDays });
    return { date: serverToday, source: "server_utc" };
  }
  return { date: raw, source: "client_local" };
}

// 判定订阅档位：读 X-Subscription-JWS → 验签（零信任）→ Pro / 免费档。
// fail-safe 到免费档：无 JWS / 过期 / 验签失败 / 产品 ID 不匹配 / bundle 不匹配 一律按免费并记日志，
// 绝不 fail-open（不默认当已付费）。验签结果 KV 缓存以分摊单请求成本。
async function resolveSubscriptionTier(request, env, requestContext) {
  const freeLimit = Number(env.DAILY_REQUEST_LIMIT);
  const paidLimit = Number(env.PAID_DAILY_LIMIT);
  const hasPaidLimit = Number.isFinite(paidLimit) && paidLimit > 0;
  const jws = request.headers.get("X-Subscription-JWS");

  // 无 JWS 或未配 Pro 上限 → 免费档
  if (!jws || !hasPaidLimit) {
    return { tier: "free", limit: freeLimit, productId: null };
  }

  // KV 缓存：命中且订阅未过期直接用（避免每请求都做 ES256 + 链校验）
  const cacheKey = `sub:${requestContext.deviceId}`;
  if (env.RATE_LIMIT_KV) {
    try {
      const cached = await env.RATE_LIMIT_KV.get(cacheKey, { type: "json" });
      if (
        cached
        && cached.tier === "pro"
        && typeof cached.expiresAt === "number"
        && Number.isFinite(cached.expiresAt)
        && cached.expiresAt > Date.now()
      ) {
        return {
          tier: cached.tier,
          limit: cached.tier === "pro" ? paidLimit : freeLimit,
          productId: cached.productId,
          cached: true
        };
      }
    } catch (error) {
      logWarn("proxy.subscription.cache_read_failed", { ...requestContext, ...errorFields(error) });
    }
  }

  // 零信任验签：ES256 签名 + x5c 链锚定 Apple Root CA - G3 + payload 声明
  const verifyStart = Date.now();
  try {
    const proProductIDs = env.PRO_PRODUCT_IDS
      ? String(env.PRO_PRODUCT_IDS).split(",").map((s) => s.trim()).filter(Boolean)
      : ["com.voicetodo.pro.monthly", "com.voicetodo.pro.yearly"];
    const result = await verifySubscriptionJWS(jws, {
      expectedBundleId: env.APP_BUNDLE_ID || "com.voicetodo.app",
      productIDs: proProductIDs,
      rootFingerprint: env.SUBSCRIPTION_ROOT_SHA256 || APPLE_ROOT_CA_G3_SHA256
    });
    const ttl = Math.min(Math.max(60, Math.floor((result.expiresAt - Date.now()) / 1000)), 15 * 60);
    if (env.RATE_LIMIT_KV && result.expiresAt > 0) {
      try {
        await env.RATE_LIMIT_KV.put(cacheKey, JSON.stringify({ tier: "pro", productId: result.productId, expiresAt: result.expiresAt }), { expirationTtl: ttl });
      } catch (error) {
        logWarn("proxy.subscription.cache_write_failed", { ...requestContext, ...errorFields(error) });
      }
    }
    logInfo("proxy.subscription.verified", { ...requestContext, tier: "pro", productId: result.productId, verifyMs: Date.now() - verifyStart, cached: false });
    return { tier: "pro", limit: paidLimit, productId: result.productId };
  } catch (error) {
    // fail-safe 到免费档（不 fail-open，不 500）
    logWarn("proxy.subscription.verify_failed", { ...requestContext, reason: "verify_failed", verifyMs: Date.now() - verifyStart, ...errorFields(error) });
    return { tier: "free", limit: freeLimit, productId: null };
  }
}

function quotaHeaders(state) {
  // state 可能为 null（未启用配额）或 { skipped: true, resetDate, dateSource }（启用但跳过）。
  // 两种情况都不应输出 undefined 头字段。
  if (!state || state.skipped) return {};
  return {
    "X-Quota-Plan": state.plan,
    "X-Quota-Limit": String(state.limit),
    "X-Quota-Used": String(state.used),
    "X-Quota-Remaining": String(state.remaining),
    "X-Quota-Reset-Date": state.resetDate
  };
}

// 距下一个本地日期边界（UTC 0 点近似）的秒数，用于配额耗尽时的 Retry-After 提示。
function secondsUntilNextLocalDay(quotaDate) {
  const next = Date.parse(`${quotaDate}T00:00:00.000Z`) + 24 * 3600 * 1000;
  const delta = Math.ceil((next - Date.now()) / 1000);
  return Number.isFinite(delta) && delta > 0 ? delta : 3600;
}

// 全局每日预算熔断：当天全网调用量超过 GLOBAL_DAILY_LIMIT 即对所有人返回 503，
// 把"无限身份的分布式刷"的财务风险锁成可设的上限。粗粒度（KV 最终一致），作为预算兜底足够。
async function enforceGlobalBudget(env, requestContext) {
  if (!env.RATE_LIMIT_KV || !env.GLOBAL_DAILY_LIMIT) {
    logInfo("proxy.global_budget.skipped", { ...requestContext, reason: "not_configured" });
    return;
  }
  const limit = Number(env.GLOBAL_DAILY_LIMIT);
  if (!Number.isFinite(limit) || limit <= 0) {
    logWarn("proxy.global_budget.skipped", { ...requestContext, reason: "invalid_limit", configuredLimit: env.GLOBAL_DAILY_LIMIT });
    return;
  }
  const today = new Date().toISOString().slice(0, 10);
  const key = `global-quota:${today}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  if (current >= limit) {
    logWarn("proxy.global_budget.exceeded", { ...requestContext, current, limit });
    throw new ProxyHTTPError(503, "Service temporarily unavailable", {
      errorType: "global_budget_exceeded",
      body: { error: "global_budget_exceeded" }
    });
  }
  await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
  logInfo("proxy.global_budget.incremented", { ...requestContext, current: current + 1, limit });
}

// 独立于设备的 IP 限流：始终按 CF-Connecting-IP 计，挡"单 IP 轮换 X-Device-ID 刷配额"。
// 两层均按需开启（未配置对应 env 即跳过）：分钟级突发 IP_RATE_PER_MINUTE + 每日 IP_DAILY_LIMIT。
async function enforcePerIpLimit(request, env, requestContext) {
  if (!env.RATE_LIMIT_KV) {
    return;
  }
  const rawIp = request.headers.get("CF-Connecting-IP") || "anonymous";
  const ipHash = await safeDeviceId(rawIp, env);  // 复用加盐哈希，KV key 不落明文 IP
  const now = new Date();

  const perMinute = Number(env.IP_RATE_PER_MINUTE || 0);
  if (Number.isFinite(perMinute) && perMinute > 0) {
    const minuteBucket = now.toISOString().slice(0, 16);  // YYYY-MM-DDTHH:MM
    const key = `ip-rate:${minuteBucket}:${ipHash}`;
    const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
    if (current >= perMinute) {
      logWarn("proxy.ip_rate.exceeded", { ...requestContext, current, limit: perMinute });
      throw new ProxyHTTPError(429, "Too many requests", {
        errorType: "rate_limited",
        rateLimitType: "velocity",
        body: { error: "rate_limited", retryAfter: 60 },
        headers: { "X-RateLimit-Type": "velocity", "Retry-After": "60" }
      });
    }
    await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 120 });
  }

  const perDay = Number(env.IP_DAILY_LIMIT || 0);
  if (Number.isFinite(perDay) && perDay > 0) {
    const today = now.toISOString().slice(0, 10);
    const key = `ip-quota:${today}:${ipHash}`;
    const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
    if (current >= perDay) {
      logWarn("proxy.ip_quota.exceeded", { ...requestContext, current, limit: perDay });
      throw new ProxyHTTPError(429, "Too many requests from this IP", {
        errorType: "rate_limited",
        rateLimitType: "ip_daily",
        body: { error: "rate_limited", retryAfter: secondsUntilNextLocalDay(today) },
        headers: { "X-RateLimit-Type": "ip_daily", "Retry-After": String(secondsUntilNextLocalDay(today)) }
      });
    }
    await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
  }
}

function normalizeLocale(locale) {
  const raw = String(locale || "en");
  return raw.toLowerCase().startsWith("zh") ? "zh" : "en";
}

function normalizeVocabularyHints(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  const hints = [];
  const seen = new Set();
  for (const item of value) {
    if (typeof item !== "string") {
      continue;
    }
    const term = item.trim().replace(/\s+/g, " ");
    if (term.length < 2 || term.length > MAX_VOCABULARY_HINT_CHARS || /[\r\n]/.test(term)) {
      continue;
    }
    const key = term.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    hints.push(term);
    if (hints.length >= MAX_VOCABULARY_HINTS) {
      break;
    }
  }
  return hints;
}

function validateProviderStreamBody(response, provider, requestContext) {
  if (!response.body) {
    logError("proxy.provider.stream_missing_body", {
      ...requestContext,
      provider: provider.type,
      providerId: provider.id
    });
    throw new ProxyHTTPError(502, "AI provider streaming response missing body", { errorType: "stream_missing_body" });
  }
  return null;
}

async function readProviderText(response, provider, adapter, requestContext) {
  const data = await readProviderJSON(response, provider, requestContext);
  const text = adapter.extractText(data);
  if (text === null) {
    logError("proxy.provider.missing_text", {
      ...requestContext,
      provider: provider.type,
      providerId: provider.id
    });
    throw new ProxyHTTPError(502, `${provider.type} response missing text`, { errorType: "missing_text" });
  }
  return { text };
}

async function readProviderJSON(response, provider, requestContext) {
  try {
    return await response.json();
  } catch (error) {
    logError("proxy.provider.invalid_json", {
      ...requestContext,
      provider: provider.type,
      providerId: provider.id,
      ...errorFields(error)
    });
    throw new ProxyHTTPError(502, "AI provider returned invalid JSON", { cause: error, errorType: "invalid_json" });
  }
}

async function makeRequestContext(request, env) {
  const url = new URL(request.url);
  const rawDeviceId = request.headers.get("X-Device-ID")
    || request.headers.get("CF-Connecting-IP")
    || "anonymous";
  return {
    requestId: makeRequestId(),
    startedAt: Date.now(),
    method: request.method,
    path: url.pathname,
    contentLength: request.headers.get("content-length") || "unknown",
    deviceId: await safeDeviceId(rawDeviceId, env)
  };
}

function makeRequestId() {
  if (globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }
  return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function finishRequest(response, requestContext, extra = {}) {
  logInfo("proxy.request.finished", {
    ...requestContext,
    ...extra,
    status: response.status,
    durationMs: Date.now() - requestContext.startedAt
  });
  return response;
}

async function safeDeviceId(deviceId, env = {}) {
  const value = String(deviceId || "missing");
  const salt = String(env.LOG_HASH_SALT || env.APP_TOKEN || "voicetodo");
  return `sha256:${await shortHash(`${salt}:${value}`)}`;
}

async function shortHash(value) {
  const data = new TextEncoder().encode(String(value));
  const digest = await globalThis.crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .slice(0, 8)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
