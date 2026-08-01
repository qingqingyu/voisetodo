import { AdminConfigStore, applyPrimaryOverride } from "./src/adminConfig.js";
import { ExtractionCacheStore, makeCacheKey } from "./src/extractionCache.js";
import { getAdapter } from "./src/adapters/index.js";
import { loadProviders } from "./src/config.js";
import { ProxyHTTPError } from "./src/errors.js";
import { HealthStore, configureHealthParams } from "./src/health.js";
import { logInfo, logWarn, logError, errorFields } from "./src/log.js";
import { executeWithFailover } from "./src/provider.js";
import { pickCandidates } from "./src/selector.js";
import { normalizeProviderStream } from "./src/stream.js";
import { verifySubscriptionJWS, APPLE_ROOT_CA_G3_SHA256 } from "./src/subscription.js";

// Durable Object 类必须从 worker 入口 export,Cloudflare 运行时才能识别 binding。
// Step 2:仅声明,业务路径仍走 KV;Step 3 起逐步切换读路径到 DO。
export { QuotaCounter } from "./src/do/quota-counter.js";

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

// Module-level AdminConfigStore:缓存 admin 通过 /v1/admin/providers/primary 设置的
// primary provider override。复用 AI_PROVIDER_STATE_KV(跟 health state 同 namespace,
// key 前缀 config: 区分)。30s 内存缓存,避免每请求都读 KV。
const sharedAdminConfigStore = new AdminConfigStore();

// Module-level ExtractionCacheStore:解析结果 cache。独立 KV namespace
// (CACHE_RESULT_KV),1h TTL。只缓存非流式 + 无 personalHints 的请求。
const sharedExtractionCache = new ExtractionCacheStore();

// Isolate 首请求标记:Cloudflare Workers 的 isolate 在首次请求时才真正 lazy-load
// KV/DO binding,首个 /v1/todo-extractions 请求会承担冷启动开销。本标志在 isolate
// 生命周期内只对首请求输出一次 `proxy.cold_start.warmup` 日志,后续请求不再打。
// isolate 回收后状态重置(因为模块级 let 在新 isolate 是初始值 false)。
let isolateWarmedUp = false;

// Test-only export: allows tests to reset module-level health state between runs.
export function _testResetHealth() {
  sharedHealthStore.reset();
}

// Test-only export: allows tests to reset module-level admin config state between runs.
export function _testResetAdminConfig() {
  sharedAdminConfigStore.reset();
}

// Test-only export: allows tests to reset module-level extraction cache state between runs.
export function _testResetExtractionCache() {
  sharedExtractionCache.reset();
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

    // Admin 路由:动态切换 provider 主力等运维操作。
    // 必须在 todo-extractions 主流程之前分发,避免被配额检查 / payload 解析挡住。
    if (url.pathname.startsWith("/v1/admin/")) {
      return await handleAdminRequest(request, env, requestContext, url);
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

    const quotaState = await enforceAllQuotas(request, env, requestContext, ctx);

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
    sharedAdminConfigStore.updateKv(env.AI_PROVIDER_STATE_KV || null);
    sharedExtractionCache.updateKv(env.CACHE_RESULT_KV || null);
    // 从 env 读熔断参数覆盖(每次 request 调,轻量)。未配置时保持代码默认值
    // (threshold=5, initialCooldown=10s, maxCooldown=5min)。
    configureHealthParams(env);

    // Isolate 冷启动诊断:测 updateKv 耗时(KV binding 首次解析可能慢),
    // 首请求输出一次 warmup 日志,标记本 isolate 已"热身完成"。
    // 后续请求 isolateWarmedUp=true,跳过本日志。
    if (!isolateWarmedUp) {
      isolateWarmedUp = true;
      logInfo("proxy.cold_start.warmup", {
        ...requestContext,
        coldStart: true,
        totalWarmupMs: Date.now() - requestContext.startedAt
      });
    }

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

    // 应用 admin runtime override:如果 admin 通过 /v1/admin/providers/primary
    // 设置了 primaryId,把对应 provider 的 priority 改为 1,让 selector 优先选它。
    // 30s 内存缓存,KV 读失败时静默回退到 toml 默认(不阻塞业务请求)。
    const primaryOverride = await sharedAdminConfigStore.getPrimaryOverride();
    if (primaryOverride?.primaryId) {
      const before = providers.map((p) => ({ id: p.id, priority: p.priority }));
      providers = applyPrimaryOverride(providers, primaryOverride.primaryId);
      requestContext.primaryOverride = {
        primaryId: primaryOverride.primaryId,
        updatedAt: primaryOverride.updatedAt
      };
      logInfo("proxy.providers.primary_override_applied", {
        ...requestContext,
        before,
        after: providers.map((p) => ({ id: p.id, priority: p.priority }))
      });
    }

    // 提前取 personalHints(原本在 line 197,cache 判断需要)
    const personalHints = typeof payload.personalHints === "string" ? payload.personalHints.trim() : null;

    // Cache lookup: 非流式 + 无 personalHints 才 cache
    // - 流式响应是 SSE 多事件序列,序列化复杂度高于纯 JSON,先不缓存
    // - personalHints 是用户级个人术语表,不同用户不能共享 cache(隐私 + 正确性)
    // Cache key 含 today(YYYY-MM-DD),跨天后 cache 自动失效;TTL 1h 也是兜底
    const cacheable = !stream && !personalHints;
    let cacheKey = null;
    if (cacheable) {
      cacheKey = await makeCacheKey({ transcript, locale, vocabularyHints, today: todayDate });
      const cached = await sharedExtractionCache.get(cacheKey);
      if (cached) {
        logInfo("proxy.cache.hit", { ...requestContext, cacheKey, responseChars: cached.length });
        return finishRequest(new Response(cached, {
          status: 200,
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            ...quotaHeaders(quotaState)
          }
        }), requestContext, { reason: "cache_hit", responseChars: cached.length });
      }
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

    const params = { transcript, locale, vocabularyHints, stream, today: todayDate, personalHints };
    // executeWithFailover 的所有失败出口都是 throw(候选为空 / 非重试类失败 /
    // 全部候选耗尽 / invariant_violation),所以这一层 catch 覆盖了全部
    // "用户一个字都没拿到"的情况 —— 一律退回设备额度后原样上抛。
    let result;
    try {
      result = await executeWithFailover(candidates, params, fetchImpl, requestContext, {
        healthStore: sharedHealthStore,
        // 客户端断连信号:用户划走时上游 fetch 立刻 abort,不再继续烧 token 到 timeoutMs
        abortSignal: request.signal,
        onResponse: stream
          ? ({ response, provider }) => validateProviderStreamBody(response, provider, requestContext)
          : ({ response, provider, adapter }) => readProviderText(response, provider, adapter, requestContext)
      });
    } catch (error) {
      await refundDeviceQuotaOnUpstreamFailure(request, env, requestContext, ctx, quotaState, "provider_failed");
      throw error;
    }
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
          // 流已经开始后失败:响应头(含 X-Quota-*)早就发出去了,无法改。
          // 只有"一个字都没给"才等于用户什么也没拿到 → 退配额。
          // emittedCount > 0 说明客户端已收到可用 todo,而客户端的 partial_fallback
          // (TranscriptProcessingFlow)会把它们当成功保留 —— 用户拿到了价值,不退。
          // 退款不会反映在本次响应头里,客户端下一次成功请求会拿到修正后的数值。
          onFailure: async (_error, stats) => {
            await result.confirmFailure("stream");
            if (stats?.emittedCount === 0) {
              await refundDeviceQuotaOnUpstreamFailure(
                request, env, requestContext, ctx, quotaState, "stream_failed_before_any_output"
              );
            }
          }
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
    // Cache write: 非流式 + 成功响应。异步写不阻塞响应(ctx.waitUntil)。
    // cacheKey 在前面 cache lookup 时计算(只在 cacheable 时非 null)。
    // ctx 可能没有 waitUntil(单元测试传 {} 兜底),用可选链避免抛错。
    if (cacheKey && text && typeof ctx?.waitUntil === "function") {
      ctx.waitUntil(sharedExtractionCache.set(cacheKey, text));
    } else if (cacheKey && text) {
      // 测试或老 runtime 没 waitUntil:同步触发但忽略 promise(fire-and-forget)
      sharedExtractionCache.set(cacheKey, text).catch(() => {});
    }
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

// MARK: - Admin handler (runtime provider override)
//
// /v1/admin/providers          GET     返回当前 providers(合并 override 后)+ override 状态
// /v1/admin/providers/primary  POST    { primaryId } 写 KV override,立即切主力
// /v1/admin/providers/primary  DELETE  清 KV override,回到 toml 默认
//
// 鉴权:必须带 X-Admin-Token header,值 = env.ADMIN_TOKEN(secret 注入)。
// 跟 APP_TOKEN 分离,普通客户端无法调用。

const ADMIN_TOKEN_HEADER = "X-Admin-Token";
const ADMIN_PAYLOAD_MAX_BYTES = 4 * 1024;

export async function handleAdminRequest(request, env, requestContext, url) {
  const authError = validateAdminToken(request, env);
  if (authError) {
    logWarn("proxy.admin.auth_failed", {
      ...requestContext,
      status: authError.response.status,
      reason: authError.reason
    });
    return finishRequest(authError.response, requestContext, { reason: authError.reason });
  }

  if (url.pathname === "/v1/admin/providers" && request.method === "GET") {
    return await handleAdminGetProviders(env, requestContext);
  }
  if (url.pathname === "/v1/admin/providers/primary" && request.method === "POST") {
    return await handleAdminSetPrimary(request, env, requestContext);
  }
  if (url.pathname === "/v1/admin/providers/primary" && request.method === "DELETE") {
    return await handleAdminClearPrimary(env, requestContext);
  }
  return finishRequest(new Response("Not Found", { status: 404 }), requestContext, { reason: "admin_route_not_found" });
}

async function handleAdminGetProviders(env, requestContext) {
  sharedAdminConfigStore.updateKv(env.AI_PROVIDER_STATE_KV || null);

  let providers;
  try {
    providers = loadProviders(env, {
      onSecretMissing: ({ id, secretName }) => {
        logWarn("proxy.admin.provider.secret_missing", { ...requestContext, providerId: id, secretName });
      }
    });
  } catch (error) {
    logError("proxy.admin.providers.config_failed", { ...requestContext, ...errorFields(error) });
    return finishRequest(
      jsonResponse(500, { error: "providers_config_invalid", detail: error.message }),
      requestContext,
      { reason: "providers_config_invalid" }
    );
  }

  const override = await sharedAdminConfigStore.getPrimaryOverride();
  // 应用 override 让 caller 看到实际生效的 priority(而非 toml 默认)
  const effective = override?.primaryId ? applyPrimaryOverride(providers, override.primaryId) : providers;

  // 返回精简视图:去掉 secretName / apiKey,只留 hasApiKey 布尔
  const publicProviders = effective.map((p) => ({
    id: p.id,
    type: p.type,
    model: p.model,
    priority: p.priority,
    weight: p.weight,
    enabled: p.enabled,
    timeoutMs: p.timeoutMs,
    hasApiKey: Boolean(p.apiKey)
  }));

  return finishRequest(
    jsonResponse(200, { providers: publicProviders, override }),
    requestContext,
    { reason: "admin_providers_listed" }
  );
}

async function handleAdminSetPrimary(request, env, requestContext) {
  sharedAdminConfigStore.updateKv(env.AI_PROVIDER_STATE_KV || null);

  let payload;
  try {
    payload = await readAdminPayload(request);
  } catch (error) {
    return finishRequest(
      jsonResponse(400, { error: "invalid_json" }),
      requestContext,
      { reason: "admin_invalid_json" }
    );
  }

  const primaryId = String(payload?.primaryId || "").toUpperCase();
  if (!primaryId) {
    return finishRequest(
      jsonResponse(400, { error: "missing_primary_id" }),
      requestContext,
      { reason: "admin_missing_primary_id" }
    );
  }

  // 校验 primaryId 在当前 toml 配置里存在(防止 admin 把不存在的 id 写进 KV,
  // 导致 applyPrimaryOverride 静默 noop 后 selector 行为不变却看起来"已切换")
  let providers;
  try {
    providers = loadProviders(env, { onSecretMissing: () => {} });
  } catch (error) {
    return finishRequest(
      jsonResponse(500, { error: "providers_config_invalid" }),
      requestContext,
      { reason: "providers_config_invalid" }
    );
  }
  const exists = providers.some((p) => p.id === primaryId);
  if (!exists) {
    logWarn("proxy.admin.primary_not_found", {
      ...requestContext,
      requestedId: primaryId,
      availableIds: providers.map((p) => p.id)
    });
    return finishRequest(
      jsonResponse(400, {
        error: "unknown_provider_id",
        primaryId,
        availableIds: providers.map((p) => p.id)
      }),
      requestContext,
      { reason: "admin_unknown_provider_id" }
    );
  }

  // updatedBy 用 requestContext.deviceId(已是 sha256 hash)作为审计标识
  const updatedBy = requestContext.deviceId || null;
  const override = await sharedAdminConfigStore.setPrimaryOverride(primaryId, updatedBy);
  logInfo("proxy.admin.providers_primary_set", {
    ...requestContext,
    primaryId,
    updatedAt: override.updatedAt
  });
  return finishRequest(
    jsonResponse(200, { ok: true, override }),
    requestContext,
    { reason: "admin_primary_set" }
  );
}

async function handleAdminClearPrimary(env, requestContext) {
  sharedAdminConfigStore.updateKv(env.AI_PROVIDER_STATE_KV || null);
  await sharedAdminConfigStore.clearPrimaryOverride();
  logInfo("proxy.admin.providers_primary_cleared", { ...requestContext });
  return finishRequest(
    jsonResponse(200, { ok: true, cleared: true }),
    requestContext,
    { reason: "admin_primary_cleared" }
  );
}

function validateAdminToken(request, env) {
  // ADMIN_TOKEN 必须配置;没配置直接 500,避免 admin endpoint 被误开放为无鉴权
  if (!env.ADMIN_TOKEN) {
    return {
      response: jsonResponse(500, { error: "admin_token_not_configured" }),
      reason: "admin_token_not_configured"
    };
  }
  const provided = request.headers.get(ADMIN_TOKEN_HEADER) || "";
  const expected = String(env.ADMIN_TOKEN);
  // 跟 APP_TOKEN 一致:支持明文或 `Bearer ${token}` 两种格式
  if (provided === expected || provided === `Bearer ${expected}`) {
    return null;
  }
  return {
    response: jsonResponse(401, { error: "unauthorized" }),
    reason: "unauthorized"
  };
}

async function readAdminPayload(request) {
  const text = await readRequestTextWithLimit(request, ADMIN_PAYLOAD_MAX_BYTES);
  return text ? JSON.parse(text) : {};
}

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

// MARK: - Scheduled handler (90 天 GC)

export async function handleScheduled(env, fetchImpl = fetch) {
  // 现有:telemetry GC(90 天保留)
  if (env.TELEMETRY_DB) {
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

  // 新加(P3):主动健康检查。每 30 分钟 cron 触发,并行 ping 所有 provider,
  // 成功调 recordSuccess(更新 EWMA),失败调 recordFailure(可能触发熔断)。
  // 跟真实请求共享 HealthStore 状态机,故障时 selector 提前避开不健康 provider。
  await runProviderHealthCheck(env, fetchImpl);
}

/// 主动健康检查:用最短 transcript "test" 省 token,并行 ping 所有 provider。
/// 复用 HealthStore 状态机 — 成功更新 EWMA,失败累计(达到阈值会进 open)。
/// 单个 provider 失败不影响其他(Promise.allSettled)。
async function runProviderHealthCheck(env, fetchImpl) {
  if (!env.AI_PROVIDER_STATE_KV) {
    logInfo("health_check.skipped", { reason: "kv_not_bound" });
    return;
  }
  sharedHealthStore.updateKv(env.AI_PROVIDER_STATE_KV);
  configureHealthParams(env);

  let providers;
  try {
    providers = loadProviders(env, { onSecretMissing: () => {} });
  } catch (error) {
    logError("health_check.providers_failed", errorFields(error));
    return;
  }

  const probeTranscript = "test";
  const probeLocale = "en";
  const probeTimeoutMs = 10_000;
  // buildSystemPrompt 需要 today 字段(YYYY-MM-DD),health check 无 quota 流程,
  // 用 UTC 当天日期兜底。probe 只测连通性,不关心相对日期解析准确。
  const probeToday = new Date().toISOString().slice(0, 10);

  const results = await Promise.allSettled(providers.map(async (provider) => {
    if (!provider.apiKey) {
      logWarn("health_check.skip_no_key", { providerId: provider.id });
      return { providerId: provider.id, ok: false, reason: "no_key" };
    }
    const adapter = getAdapter(provider.type);
    if (!adapter) {
      logWarn("health_check.skip_no_adapter", { providerId: provider.id, type: provider.type });
      return { providerId: provider.id, ok: false, reason: "no_adapter" };
    }

    const startedAt = Date.now();
    try {
      const { url, init } = adapter.buildRequest({
        transcript: probeTranscript,
        locale: probeLocale,
        stream: false,
        provider,
        today: probeToday,
        abortSignal: null
      });
      const response = await fetchImpl(url, {
        ...init,
        signal: AbortSignal.timeout(probeTimeoutMs)
      });
      const durationMs = Date.now() - startedAt;

      if (response.ok) {
        await sharedHealthStore.recordSuccess(provider.id, durationMs);
        logInfo("health_check.success", { providerId: provider.id, durationMs });
        return { providerId: provider.id, ok: true, durationMs };
      }
      await sharedHealthStore.recordFailure(provider.id, `http_${response.status}`);
      logWarn("health_check.http_failed", { providerId: provider.id, status: response.status });
      return { providerId: provider.id, ok: false, status: response.status };
    } catch (error) {
      const errorType = error?.name === "TimeoutError" ? "timeout" : "network";
      await sharedHealthStore.recordFailure(provider.id, errorType);
      logWarn("health_check.failed", { providerId: provider.id, errorType, message: error?.message });
      return { providerId: provider.id, ok: false, errorType };
    }
  }));

  const succeeded = results.filter((r) => r.status === "fulfilled" && r.value?.ok).length;
  const total = providers.length;
  logInfo("health_check.completed", { total, succeeded });
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

// 计费编排:Step 7 重排后的统一入口。
//
// 设计原则:
//   1. 前置检查先行:global-budget 熔断标志(KV tripped,纯读边缘缓存)+ ip-rate 限流
//      (KV RMW,会扣计数,故意不补偿 —— 这是反刷维度,被这里拒绝也算消耗一次"尝试机会")
//   2. device + ip-daily 并行扣减(Promise.allSettled),延迟从 2× 串行往返压到 1×
//   3. 失败补偿:一个 allow 一个 deny 时,给 allow 的发 refund(DO refund 原子,
//      KV refund 在 dev/test 单线程下 OK)
//   4. 全局预算 DO consume 仍异步,不阻塞响应(单例 DO 跨洲往返不可接受)
//
// 关键不变量:enforceDailyLimit / enforceIpDailyLimit reject(超限)时**没有扣 quota**
// (检查在 increment 之前,平台保证原子)。所以 refund 只在"fulfilled + 对方 rejected"
// 时触发,不会出现"两个都 reject 还要 refund"的情况。
//
// 注意:ip-rate 在 Step A 已 increment,即使后续 device reject 也**不 refund** ——
// 这是有意为之,ip-rate 是反"短时间内高频尝试"的维度,被它拒绝或被它放行后再被其他维度
// 拒绝,都应消耗一次 ip-rate 配额,避免攻击者用"device 配额耗尽重试"绕过 ip-rate。
async function enforceAllQuotas(request, env, requestContext, ctx) {
  // Step A: 前置检查
  // - global-budget:纯读 KV tripped 标志,真正零成本
  // - ip-rate:KV RMW,会扣计数(有意不补偿,见上方注释)
  await enforceGlobalBudgetHotPath(env, requestContext);
  await enforceIpRateLimit(request, env, requestContext);

  // Step B: device + ip-daily 并行扣减
  const [deviceResult, ipResult] = await Promise.allSettled([
    enforceDailyLimit(request, env, requestContext, ctx),
    enforceIpDailyLimit(request, env, requestContext, ctx)
  ]);

  // Step C: 失败补偿
  // 三种 reject 组合:
  //   - 都 reject → 两者都没扣(超限检查在前) → 抛 device 错误(优先,常是用户最关心的)
  //   - 仅 device reject → device 没扣,ip 可能已扣 → refund ip
  //   - 仅 ip reject → ip 没扣,device 可能已扣 → refund device
  //
  // 补偿 vs KV 影子写的竞态:enforceDailyLimitViaDO 在 ctx.waitUntil 里覆盖式 put KV,
  // 这里同步 refund 走 KV fallback 也会 put KV。两个 put 顺序未定,可能导致 KV 最终值
  // 是 increment 后的(没扣回),破坏 KV-as-rollback-mirror。
  //
  // 缓解:refund 成功后,把 KV 的影子值也覆盖到 refund 后的 used(再排队一个 waitUntil)。
  // 注意:Cloudflare waitUntil **不保证 FIFO 执行顺序**,因此这不是严格修复,
  // 只是大幅降低错误概率(从"必然错误"降到"网络抖动下偶发错误")。
  // DO 主路径保证正确(KV 只是镜像);KV 错误的代价是回滚到 KV 时配额偏高 1,
  // 不会泄漏给用户。若未来需要严格一致,需要让 increment 影子写读 DO 当前值再写,
  // 或改用 D1 单 SQL 事务做 KV 替代。
  if (deviceResult.status === "rejected" && ipResult.status === "fulfilled") {
    await refundIpDaily(request, env, requestContext, ctx).catch((error) => {
      // outer catch 是补偿失败的刻意吞点:用户已被拒,refund 失败只产生配额泄漏,
      // 不应再让响应 5xx。需通过日志监控 leak 率。
      logWarn("proxy.ip_quota.refund_failed", { ...requestContext, ...errorFields(error) });
    });
    throw deviceResult.reason;
  }
  if (ipResult.status === "rejected" && deviceResult.status === "fulfilled") {
    await refundDeviceQuota(request, env, requestContext, ctx).catch((error) => {
      logWarn("proxy.quota.refund_failed", { ...requestContext, ...errorFields(error) });
    });
    throw ipResult.reason;
  }
  if (deviceResult.status === "rejected") {
    // 两者都 reject,优先抛 device 错误
    throw deviceResult.reason;
  }

  // Step D: 都通过,异步递增 global budget(若 DO 未绑则同步 KV 路径)
  await enforceGlobalBudgetIncrement(env, requestContext, ctx);

  return deviceResult.value;
}

// 给 device 配额发 refund:DO 路径调 /refund,KV 路径直接 -1(degraded,dev/test 用)。
// ctx 用于 DO refund 成功后把 KV 影子值也修正到 refund 后的 used(覆盖式 put,
// 排队到原 increment 影子写之后,作为最终修正)。
//
// 调用方:(1) enforceAllQuotas 的交叉补偿(ip 拒绝但 device 已扣);
//        (2) refundDeviceQuotaOnUpstreamFailure(上游没给出结果)。
async function refundDeviceQuota(request, env, requestContext, ctx) {
  const { date: quotaDate } = resolveQuotaDate(request, requestContext);
  if (env.QUOTA_COUNTER_DO) {
    const result = await refundQuotaCounterDO(env, "device-quota", requestContext.deviceId, quotaDate, "proxy.quota.refunded");
    // DO refund 成功后,KV 影子值要同步修正(避免和 increment 时的影子写竞争)
    if (ctx?.waitUntil && env.RATE_LIMIT_KV) {
      const quotaKey = `quota:${quotaDate}:${requestContext.deviceId}`;
      ctx.waitUntil(
        env.RATE_LIMIT_KV.put(quotaKey, String(result.used), { expirationTtl: 36 * 60 * 60 })
          .catch((error) => {
            logWarn("proxy.quota.refund_kv_shadow_failed", {
              ...requestContext,
              quotaDate,
              ...errorFields(error)
            });
          })
      );
    }
    return;
  }
  // KV fallback:dev/test 环境。读改写在并发下不准,但单线程 OK。
  if (!env.RATE_LIMIT_KV) return;
  const quotaKey = `quota:${quotaDate}:${requestContext.deviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(quotaKey) || "0");
  const newValue = Math.max(0, current - 1);
  if (newValue === 0) {
    await env.RATE_LIMIT_KV.put(quotaKey, "0", { expirationTtl: 36 * 60 * 60 });
  } else {
    await env.RATE_LIMIT_KV.put(quotaKey, String(newValue), { expirationTtl: 36 * 60 * 60 });
  }
  logInfo("proxy.quota.refunded", { ...requestContext, quotaDate, used: newValue, source: "kv" });
}

// 给 ip-daily 配额发 refund:同 device。
async function refundIpDaily(request, env, requestContext, ctx) {
  const rawIp = request.headers.get("CF-Connecting-IP") || "anonymous";
  const ipHash = await safeDeviceId(rawIp, env);
  const today = new Date().toISOString().slice(0, 10);
  if (env.QUOTA_COUNTER_DO) {
    const result = await refundQuotaCounterDO(env, "ip-daily", ipHash, today, "proxy.ip_quota.refunded");
    if (ctx?.waitUntil && env.RATE_LIMIT_KV) {
      const key = `ip-quota:${today}:${ipHash}`;
      ctx.waitUntil(
        env.RATE_LIMIT_KV.put(key, String(result.used), { expirationTtl: 36 * 60 * 60 })
          .catch((error) => {
            logWarn("proxy.ip_quota.refund_kv_shadow_failed", {
              ...requestContext,
              ...errorFields(error)
            });
          })
      );
    }
    return;
  }
  if (!env.RATE_LIMIT_KV) return;
  const key = `ip-quota:${today}:${ipHash}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  const newValue = Math.max(0, current - 1);
  if (newValue === 0) {
    await env.RATE_LIMIT_KV.put(key, "0", { expirationTtl: 36 * 60 * 60 });
  } else {
    await env.RATE_LIMIT_KV.put(key, String(newValue), { expirationTtl: 36 * 60 * 60 });
  }
  logInfo("proxy.ip_quota.refunded", { ...requestContext, today, used: newValue, source: "kv" });
}

// 上游没能给出结果时把设备额度退回。
//
// 为什么要退:配额在调 AI 之前就扣了(见 enforceDailyLimit 上方注释)。那条
// "发起即计数"是为了防"靠重试绕过计费" —— 但用户什么都没拿到时不存在可绕过的计费,
// 只剩"付了额度没拿到服务"。引入退款机制的提交(3e53ef2)在 Why 里就把
// "用户被扣配额却拿不到服务且无回滚"列为待修缺陷,这里是补齐那一半。
//
// 客户端 NetworkConfig.retryCount = 2(单次提取最多 3 个请求),不退的话上游抖动一次
// 就烧掉 3 条额度。免费档只有 2 条时,一次故障就把用户当天打光。
//
// **只退 device 额度**:ip-rate / ip-daily / global-budget 一律保持"发起即计数、
// 永不退款"。这是安全边界 —— 即使有人故意制造失败来白烧上游 token,那三层天花板
// 照常收紧,不会退化成无限量白嫖。
//
// 退款失败只 logWarn,不改变响应状态:用户已经拿到错误了,再叠一个 5xx 没有意义。
// 代价是配额泄漏(用户少扣一次),需要靠日志监控泄漏率。
async function refundDeviceQuotaOnUpstreamFailure(request, env, requestContext, ctx, quotaState, reason) {
  // 配额未启用(KV/limit 没配)时压根没扣过,退了只会产生噪声日志和无意义的 KV 写。
  if (!quotaState || quotaState.skipped) return;
  try {
    await refundDeviceQuota(request, env, requestContext, ctx);
    logInfo("proxy.quota.refunded_upstream_failure", { ...requestContext, reason });
  } catch (error) {
    logWarn("proxy.quota.refund_upstream_failure_failed", {
      ...requestContext,
      reason,
      ...errorFields(error)
    });
  }
}

// 共用 DO refund 调用。失败时抛错,由调用方决定如何处理(CLAUDE.md:错误显式传播)。
// 日志在调用方写,这里只做 fetch + 状态码校验。
// logEvent 显式传:不同 subject 在日志里的事件名不同(device-quota→quota, ip-daily→ip_quota),
// 显式参数避免调用点用三元运算硬编码,新增 subject 不会误归入既有事件。
async function refundQuotaCounterDO(env, subjectKey, subjectId, date, logEvent) {
  const doName = `${subjectKey}:${subjectId}`;
  const id = env.QUOTA_COUNTER_DO.idFromName(doName);
  const stub = env.QUOTA_COUNTER_DO.get(id);
  const response = await stub.fetch(new Request("https://quota-counter.local/refund", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key: subjectKey, date, amount: 1 })
  }));
  if (!response.ok) {
    throw new Error(`DO refund returned status ${response.status}`);
  }
  const result = await response.json();
  logInfo(logEvent, {
    date,
    subjectId,
    used: result.used,
    source: "do"
  });
  return result;
}

// 免费档每日上限（DAILY_REQUEST_LIMIT）与 Pro 档每日上限（PAID_DAILY_LIMIT）。
// 配额 key 由客户端本地日期 + 设备摘要构成：发起即计数（含后续 AI 调用失败），
// 避免靠重试绕过计费。代理是唯一可信强制点，客户端只负责展示。
//
// Step 4 起:env.QUOTA_COUNTER_DO 绑定时走 DO 强一致主路径(解决 KV 并发丢失更新)。
// DO 故障(fetch 抛错 / 非 200)自动回退到 KV 路径并 log warn —— KV 虽有丢失更新,
// 但单线程下仍正确,作为 degraded 模式比纯 fail-open 安全。
// 测试/dev 环境不绑定 DO 时直接走 KV 路径,行为与 Step 3 前一致。
async function enforceDailyLimit(request, env, requestContext, ctx) {
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

  if (env.QUOTA_COUNTER_DO) {
    return enforceDailyLimitViaDO(env, requestContext, ctx, { tier, limit, productId, quotaDate, dateSource: source });
  }
  return enforceDailyLimitViaKV(env, requestContext, ctx, { tier, limit, productId, quotaDate, dateSource: source });
}

// DO 主路径:强一致 consume。失败时 fallback 到 KV 路径。
// 成功后 KV 影子写(覆盖式 put,不读),保留 KV 作为可回滚镜像。
async function enforceDailyLimitViaDO(env, requestContext, ctx, params) {
  const { tier, limit, productId, quotaDate, dateSource } = params;
  const subjectKey = "device-quota";
  const doName = `${subjectKey}:${requestContext.deviceId}`;

  let result;
  try {
    const id = env.QUOTA_COUNTER_DO.idFromName(doName);
    const stub = env.QUOTA_COUNTER_DO.get(id);
    const response = await stub.fetch(new Request("https://quota-counter.local/consume", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: subjectKey, date: quotaDate, limit, amount: 1 })
    }));
    if (!response.ok) {
      throw new Error(`DO consume returned status ${response.status}`);
    }
    result = await response.json();
  } catch (error) {
    // DO 故障 → 回退到 KV 路径(degraded mode)。KV 单线程下正确,并发下漏,
    // 但比纯 fail-open 安全。
    logWarn("proxy.quota.do_failed_fallback_kv", {
      ...requestContext,
      quotaDate,
      plan: tier,
      ...errorFields(error)
    });
    return enforceDailyLimitViaKV(env, requestContext, ctx, params);
  }

  if (!result.allowed) {
    logWarn("proxy.quota.exceeded", {
      ...requestContext,
      quotaDate,
      dateSource,
      plan: tier,
      productId,
      current: result.used,
      limit,
      remaining: 0,
      source: "do"
    });
    throw new ProxyHTTPError(429, "Daily quota exceeded", {
      errorType: "quota_exceeded",
      rateLimitType: "quota",
      body: { error: "quota_exceeded", tier, remaining: 0, resetAt: quotaDate },
      headers: {
        "X-RateLimit-Type": "quota",
        "Retry-After": String(secondsUntilNextLocalDay(quotaDate)),
        ...quotaHeaders({ plan: tier, limit, used: result.used, remaining: 0, resetDate: quotaDate })
      }
    });
  }

  const used = result.used;
  const remaining = Math.max(0, limit - used);
  logInfo("proxy.quota.incremented", {
    ...requestContext,
    quotaDate,
    dateSource,
    plan: tier,
    productId,
    limit,
    used,
    remaining,
    source: "do"
  });

  // KV 影子写:覆盖式 put 当前 used(不读不增)。作为可回滚镜像保留。
  if (ctx?.waitUntil && env.RATE_LIMIT_KV) {
    const quotaKey = `quota:${quotaDate}:${requestContext.deviceId}`;
    ctx.waitUntil(
      env.RATE_LIMIT_KV.put(quotaKey, String(used), { expirationTtl: 36 * 60 * 60 })
        .catch((error) => {
          logWarn("proxy.quota.kv_shadow_write_failed", {
            ...requestContext,
            ...errorFields(error)
          });
        })
    );
  }

  return { skipped: false, plan: tier, limit, used, remaining, resetDate: quotaDate };
}

// KV 路径(degraded / dev / test)。保留 Step 3 前的 read-modify-write 语义。
// 注意:此路径在并发下丢失更新,仅作为 fallback。
// ctx 不被 KV 路径使用,但保留在签名里与 DO 路径对称 —— 上层 enforceDailyLimit
// 不区分路径,统一传 ctx。
async function enforceDailyLimitViaKV(env, requestContext, _ctx, params) {
  const { tier, limit, productId, quotaDate, dateSource } = params;
  // requestContext.deviceId 已加盐 sha256，避免 KV 落明文设备号且与日志口径一致。
  const quotaKey = `quota:${quotaDate}:${requestContext.deviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(quotaKey) || "0");
  if (current >= limit) {
    logWarn("proxy.quota.exceeded", { ...requestContext, quotaKey, quotaDate, dateSource, plan: tier, productId, current, limit, remaining: 0, source: "kv" });
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
  logInfo("proxy.quota.incremented", { ...requestContext, quotaKey, quotaDate, dateSource, plan: tier, productId, limit, used, remaining, source: "kv" });
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
// 把"无限身份的分布式刷"的财务风险锁成可设的上限。
//
// Step 7 起拆成两个独立函数,enforceAllQuotas 分别编排:
//   - enforceGlobalBudgetHotPath:零成本前置(KV tripped 标志位)
//   - enforceGlobalBudgetIncrement:device/ip 通过后异步递增(DO consume + 写 tripped)
//
// DO 是单例(全网一个实例),同步调用会被 pin 在一个地理位置跨洲往返(~150ms),
// 对国内用户不可接受。改成:每个请求只读 KV 标志位(边缘缓存,几乎零成本),
// DO consume 异步进行(不阻塞响应);DO 检测到超限时写 KV 标志位,后续请求读到就 503。
// 代价:从"真实越限"到"全网生效"有 KV 传播延迟(~60s),会超发一些 —— 但相比 KV 时代
// "计数器根本不涨、上限形同虚设",这是从"漏"到"精确到分钟级"的改变。

// 热路径:读 KV tripped 标志位,熔断时立即 503。
async function enforceGlobalBudgetHotPath(env, requestContext) {
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
  const trippedKey = `global-budget-tripped:${today}`;
  const tripped = await env.RATE_LIMIT_KV.get(trippedKey);
  if (tripped === "1") {
    logWarn("proxy.global_budget.tripped", { ...requestContext, today, limit });
    throw new ProxyHTTPError(503, "Service temporarily unavailable", {
      errorType: "global_budget_exceeded",
      body: { error: "global_budget_exceeded" }
    });
  }
}

// 增量路径:device/ip 都通过后调用。DO 异步 consume + 写 tripped(若超限)。
// KV 路径(degraded)直接同步 increment。
async function enforceGlobalBudgetIncrement(env, requestContext, ctx) {
  if (!env.RATE_LIMIT_KV || !env.GLOBAL_DAILY_LIMIT) return;
  const limit = Number(env.GLOBAL_DAILY_LIMIT);
  if (!Number.isFinite(limit) || limit <= 0) return;
  const today = new Date().toISOString().slice(0, 10);

  if (env.QUOTA_COUNTER_DO) {
    enforceGlobalBudgetViaDOIncrement(env, requestContext, ctx, { today, limit });
    return;
  }
  await enforceGlobalBudgetViaKV(env, requestContext, { today, limit });
}

// DO 异步增量路径:ctx.waitUntil 包好,本次响应不阻塞。
function enforceGlobalBudgetViaDOIncrement(env, requestContext, ctx, params) {
  const { today, limit } = params;
  const trippedKey = `global-budget-tripped:${today}`;
  if (!ctx?.waitUntil) {
    // 生产路径 ctx 必然存在;缺失表示调用方契约违反(测试 mock 不全 / 运行时异常)。
    // 显式 warn 而非静默 —— 否则 global budget 会被无声地跳过。
    logWarn("proxy.global_budget.wait_until_missing", {
      ...requestContext,
      today,
      limit
    });
    return;
  }
  ctx.waitUntil(
    (async () => {
      try {
        const id = env.QUOTA_COUNTER_DO.idFromName("global-budget");
        const stub = env.QUOTA_COUNTER_DO.get(id);
        const response = await stub.fetch(new Request("https://quota-counter.local/consume", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ key: "global-budget", date: today, limit, amount: 1 })
        }));
        if (!response.ok) {
          logWarn("proxy.global_budget.do_http_error", {
            ...requestContext,
            status: response.status
          });
          return;
        }
        const result = await response.json();
        if (!result.allowed) {
          await env.RATE_LIMIT_KV.put(trippedKey, "1", { expirationTtl: 36 * 60 * 60 });
          logWarn("proxy.global_budget.tripped_set", {
            ...requestContext,
            today,
            used: result.used,
            limit
          });
        } else {
          logInfo("proxy.global_budget.incremented", {
            ...requestContext,
            used: result.used,
            limit,
            source: "do"
          });
        }
      } catch (error) {
        logWarn("proxy.global_budget.do_failed", {
          ...requestContext,
          ...errorFields(error)
        });
      }
    })()
  );
}

// KV 路径(degraded / dev / test):保留 Step 5 前的 read-modify-write 语义。
async function enforceGlobalBudgetViaKV(env, requestContext, params) {
  const { today, limit } = params;
  const key = `global-quota:${today}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  if (current >= limit) {
    logWarn("proxy.global_budget.exceeded", { ...requestContext, current, limit, source: "kv" });
    throw new ProxyHTTPError(503, "Service temporarily unavailable", {
      errorType: "global_budget_exceeded",
      body: { error: "global_budget_exceeded" }
    });
  }
  await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
  logInfo("proxy.global_budget.incremented", { ...requestContext, current: current + 1, limit, source: "kv" });
}

// 独立于设备的 IP 限流：始终按 CF-Connecting-IP 计，挡"单 IP 轮换 X-Device-ID 刷配额"。
//
// Step 7 起拆成两个独立函数,enforceAllQuotas 分别编排:
//   - enforceIpRateLimit:KV 路径,零成本前置(热路径)
//   - enforceIpDailyLimit:DO 主路径(DO 故障 fallback KV),与 device 配额并行扣减
//
// ip-rate 保留 KV,精度收益不抵成本(每分钟 × 每 IP 一个 DO 实例太多)。

async function enforceIpRateLimit(request, env, requestContext) {
  if (!env.RATE_LIMIT_KV) return;
  const perMinute = Number(env.IP_RATE_PER_MINUTE || 0);
  if (!Number.isFinite(perMinute) || perMinute <= 0) return;

  const rawIp = request.headers.get("CF-Connecting-IP") || "anonymous";
  const ipHash = await safeDeviceId(rawIp, env);
  const minuteBucket = new Date().toISOString().slice(0, 16);
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

async function enforceIpDailyLimit(request, env, requestContext, ctx) {
  if (!env.RATE_LIMIT_KV) return;
  const perDay = Number(env.IP_DAILY_LIMIT || 0);
  if (!Number.isFinite(perDay) || perDay <= 0) return;

  const rawIp = request.headers.get("CF-Connecting-IP") || "anonymous";
  const ipHash = await safeDeviceId(rawIp, env);
  const today = new Date().toISOString().slice(0, 10);

  if (env.QUOTA_COUNTER_DO) {
    await enforceIpDailyLimitViaDO(env, requestContext, ctx, { ipHash, today, perDay });
  } else {
    await enforceIpDailyLimitViaKV(env, requestContext, { ipHash, today, perDay });
  }
}

// ip-daily 的 DO 主路径。
async function enforceIpDailyLimitViaDO(env, requestContext, ctx, params) {
  const { ipHash, today, perDay } = params;
  const subjectKey = "ip-daily";
  const doName = `${subjectKey}:${ipHash}`;

  let result;
  try {
    const id = env.QUOTA_COUNTER_DO.idFromName(doName);
    const stub = env.QUOTA_COUNTER_DO.get(id);
    const response = await stub.fetch(new Request("https://quota-counter.local/consume", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: subjectKey, date: today, limit: perDay, amount: 1 })
    }));
    if (!response.ok) {
      throw new Error(`DO consume returned status ${response.status}`);
    }
    result = await response.json();
  } catch (error) {
    logWarn("proxy.ip_quota.do_failed_fallback_kv", {
      ...requestContext,
      ...errorFields(error)
    });
    await enforceIpDailyLimitViaKV(env, requestContext, params);
    return;
  }

  if (!result.allowed) {
    logWarn("proxy.ip_quota.exceeded", {
      ...requestContext,
      current: result.used,
      limit: perDay,
      source: "do"
    });
    throw new ProxyHTTPError(429, "Too many requests from this IP", {
      errorType: "rate_limited",
      rateLimitType: "ip_daily",
      body: { error: "rate_limited", retryAfter: secondsUntilNextLocalDay(today) },
      headers: { "X-RateLimit-Type": "ip_daily", "Retry-After": String(secondsUntilNextLocalDay(today)) }
    });
  }

  // KV 影子写
  if (ctx?.waitUntil && env.RATE_LIMIT_KV) {
    const key = `ip-quota:${today}:${ipHash}`;
    ctx.waitUntil(
      env.RATE_LIMIT_KV.put(key, String(result.used), { expirationTtl: 36 * 60 * 60 })
        .catch((error) => {
          logWarn("proxy.ip_quota.kv_shadow_write_failed", {
            ...requestContext,
            ...errorFields(error)
          });
        })
    );
  }
}

// ip-daily 的 KV 路径(degraded / dev / test)。
// 返回 void —— 调用方(Promise.allSettled)只看 status,不用返回值。
// 与 enforceDailyLimitViaKV 返回 quota state 不对称,因为 IP 限流不向客户端
// 暴露 X-Quota-* 头(IP 是反刷维度,非用户配额)。
async function enforceIpDailyLimitViaKV(env, requestContext, params) {
  const { ipHash, today, perDay } = params;
  const key = `ip-quota:${today}:${ipHash}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  if (current >= perDay) {
    logWarn("proxy.ip_quota.exceeded", { ...requestContext, current, limit: perDay, source: "kv" });
    throw new ProxyHTTPError(429, "Too many requests from this IP", {
      errorType: "rate_limited",
      rateLimitType: "ip_daily",
      body: { error: "rate_limited", retryAfter: secondsUntilNextLocalDay(today) },
      headers: { "X-RateLimit-Type": "ip_daily", "Retry-After": String(secondsUntilNextLocalDay(today)) }
    });
  }
  await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
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
