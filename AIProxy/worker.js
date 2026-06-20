const MAX_BODY_BYTES = 16 * 1024;
const MAX_TRANSCRIPT_CHARS = 4000;
const MAX_VOCABULARY_HINTS = 30;
const MAX_VOCABULARY_HINT_CHARS = 32;
const DEFAULT_PROVIDER_TIMEOUT_MS = 20_000;
const MAX_TELEMETRY_BODY_BYTES = 256 * 1024;
const MAX_TELEMETRY_EVENTS_PER_BATCH = 100;
const TELEMETRY_RETENTION_DAYS = 90;

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
    requestContext.locale = locale;
    requestContext.stream = payload.stream === true;
    requestContext.transcriptChars = transcript.length;
    requestContext.provider = normalizeProvider(env.AI_PROVIDER);
    const vocabularyHints = normalizeVocabularyHints(payload.vocabularyHints);
    requestContext.vocabularyHintCount = vocabularyHints.length;
    logInfo("proxy.payload.accepted", requestContext);

    await enforceDailyLimit(request, env, requestContext);

    const provider = requestContext.provider;
    if (payload.stream === true) {
      const response = await streamProviderResponse(provider, transcript, locale, vocabularyHints, env, fetchImpl, requestContext);
      return finishRequest(response, requestContext, { streamingBodyContinues: true });
    }

    const text = await callProviderText(provider, transcript, locale, vocabularyHints, env, fetchImpl, requestContext);
    return finishRequest(new Response(text, {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store"
      }
    }), requestContext, { responseChars: text.length });
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      const clientMessage = error.status >= 500 ? "AI proxy failed" : error.message;
      logWarn("proxy.request.http_error", { ...requestContext, status: error.status, ...errorFields(error) });
      return finishRequest(new Response(clientMessage, { status: error.status }), requestContext, { error: clientMessage });
    }
    logError("proxy.request.failed", { ...requestContext, ...errorFields(error) });
    return finishRequest(new Response("AI proxy failed", { status: 502 }), requestContext, { error: "AI proxy failed" });
  }
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

async function enforceDailyLimit(request, env, requestContext) {
  if (!env.RATE_LIMIT_KV || !env.DAILY_REQUEST_LIMIT) {
    logInfo("proxy.quota.skipped", { ...requestContext, reason: "not_configured" });
    return;
  }
  const limit = Number(env.DAILY_REQUEST_LIMIT);
  if (!Number.isFinite(limit) || limit <= 0) {
    logWarn("proxy.quota.skipped", { ...requestContext, reason: "invalid_limit", configuredLimit: env.DAILY_REQUEST_LIMIT });
    return;
  }

  const deviceId = request.headers.get("X-Device-ID")
    || request.headers.get("CF-Connecting-IP")
    || "anonymous";
  const today = new Date().toISOString().slice(0, 10);
  const key = `quota:${today}:${deviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  if (current >= limit) {
    logWarn("proxy.quota.exceeded", { ...requestContext, current, limit });
    throw new ProxyHTTPError(429, "Daily quota exceeded");
  }
  await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
  logInfo("proxy.quota.incremented", { ...requestContext, current: current + 1, limit });
}

function normalizeLocale(locale) {
  const raw = String(locale || "en");
  return raw.toLowerCase().startsWith("zh") ? "zh" : "en";
}

function normalizeProvider(provider) {
  const value = String(provider || "anthropic").toLowerCase();
  if (value === "openai") {
    return "openai";
  }
  return "anthropic";
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

async function callProviderText(provider, transcript, locale, vocabularyHints, env, fetchImpl, requestContext) {
  const response = await callProvider(provider, transcript, locale, vocabularyHints, env, fetchImpl, false, requestContext);
  const data = await readProviderJSON(response, provider, requestContext);

  if (provider === "openai") {
    const text = data?.choices?.[0]?.message?.content;
    if (!text) {
      logError("proxy.provider.missing_text", { ...requestContext, provider });
      throw new ProxyHTTPError(502, "OpenAI response missing text");
    }
    const stripped = stripMarkdownFence(text);
    logInfo("proxy.provider.text_success", { ...requestContext, provider, responseChars: stripped.length });
    return stripped;
  }

  const text = data?.content?.find((part) => part.type === "text")?.text
    || data?.content?.[0]?.text;
  if (!text) {
    logError("proxy.provider.missing_text", { ...requestContext, provider });
    throw new ProxyHTTPError(502, "Anthropic response missing text");
  }
  const stripped = stripMarkdownFence(text);
  logInfo("proxy.provider.text_success", { ...requestContext, provider, responseChars: stripped.length });
  return stripped;
}

async function streamProviderResponse(provider, transcript, locale, vocabularyHints, env, fetchImpl, requestContext) {
  const response = await callProvider(provider, transcript, locale, vocabularyHints, env, fetchImpl, true, requestContext);
  if (!response.body) {
    logError("proxy.provider.stream_missing_body", { ...requestContext, provider });
    throw new ProxyHTTPError(502, "AI provider streaming response missing body");
  }

  return new Response(normalizeProviderStream(response.body, provider, requestContext), {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-store",
      "Connection": "keep-alive"
    }
  });
}

async function callProvider(provider, transcript, locale, vocabularyHints, env, fetchImpl, stream, requestContext) {
  const startedAt = Date.now();
  logInfo("proxy.provider.call_start", { ...requestContext, provider, stream });
  const response = provider === "openai"
    ? await callOpenAI(transcript, locale, vocabularyHints, env, fetchImpl, stream)
    : await callAnthropic(transcript, locale, vocabularyHints, env, fetchImpl, stream);

  if (!response.ok) {
    const status = response.status === 429 ? 429 : 502;
    logWarn("proxy.provider.call_failed", {
      ...requestContext,
      provider,
      stream,
      providerStatus: response.status,
      durationMs: Date.now() - startedAt
    });
    throw new ProxyHTTPError(status, "AI provider error");
  }
  logInfo("proxy.provider.call_success", {
    ...requestContext,
    provider,
    stream,
    providerStatus: response.status,
    durationMs: Date.now() - startedAt
  });
  return response;
}

async function callAnthropic(transcript, locale, vocabularyHints, env, fetchImpl, stream) {
  if (!env.ANTHROPIC_API_KEY) {
    throw new ProxyHTTPError(500, "Anthropic key not configured");
  }

  return fetchImpl("https://api.anthropic.com/v1/messages", {
    method: "POST",
    signal: providerTimeoutSignal(env),
    headers: {
      "Content-Type": "application/json",
      "anthropic-version": "2023-06-01",
      "x-api-key": env.ANTHROPIC_API_KEY
    },
    body: JSON.stringify({
      model: env.ANTHROPIC_MODEL || "claude-sonnet-4-20250514",
      max_tokens: 500,
      temperature: 0.1,
      stream,
      system: systemPrompt(locale, vocabularyHints),
      messages: [{ role: "user", content: transcript }]
    })
  });
}

async function callOpenAI(transcript, locale, vocabularyHints, env, fetchImpl, stream) {
  if (!env.OPENAI_API_KEY) {
    throw new ProxyHTTPError(500, "OpenAI key not configured");
  }
  if (!env.OPENAI_MODEL) {
    throw new ProxyHTTPError(500, "OpenAI model not configured");
  }

  return fetchImpl("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    signal: providerTimeoutSignal(env),
    headers: {
      "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: env.OPENAI_MODEL,
      temperature: 0.1,
      stream,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: systemPrompt(locale, vocabularyHints) },
        { role: "user", content: transcript }
      ]
    })
  });
}

function providerTimeoutSignal(env) {
  const configuredTimeout = Number(env.AI_PROVIDER_TIMEOUT_MS);
  const timeoutMs = Number.isFinite(configuredTimeout) && configuredTimeout > 0
    ? Math.min(configuredTimeout, 60_000)
    : DEFAULT_PROVIDER_TIMEOUT_MS;
  return AbortSignal.timeout(timeoutMs);
}

async function readProviderJSON(response, provider, requestContext) {
  try {
    return await response.json();
  } catch (error) {
    logError("proxy.provider.invalid_json", { ...requestContext, provider, ...errorFields(error) });
    throw new ProxyHTTPError(502, "AI provider returned invalid JSON", { cause: error });
  }
}

function normalizeProviderStream(body, provider, requestContext) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let buffer = "";
  let finished = false;
  let chunkCount = 0;
  let emittedCount = 0;
  let emittedChars = 0;
  const startedAt = Date.now();

  return new ReadableStream({
    async start(controller) {
      const reader = body.getReader();
      let sendDone = false;
      try {
        while (!finished) {
          const { value, done } = await reader.read();
          if (done) {
            break;
          }
          chunkCount += 1;
          buffer += decoder.decode(value, { stream: true });
          let newlineIndex;
          while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, newlineIndex).trim();
            buffer = buffer.slice(newlineIndex + 1);
            if (!line.startsWith("data:")) {
              continue;
            }
            const normalized = normalizeSSEData(line.slice(5).trim(), provider);
            if (normalized.done) {
              finished = true;
              logInfo("proxy.provider.stream_done", { ...requestContext, provider, chunkCount, emittedCount, emittedChars });
              break;
            }
            if (normalized.text) {
              emittedCount += 1;
              emittedChars += normalized.text.length;
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: normalized.text })}\n\n`));
            }
          }
        }
        if (!finished) {
          throw new ProxyHTTPError(502, "AI provider stream ended before done");
        }
        sendDone = true;
      } catch (error) {
        logError("proxy.provider.stream_failed", {
          ...requestContext,
          provider,
          chunkCount,
          emittedCount,
          emittedChars,
          durationMs: Date.now() - startedAt,
          ...errorFields(error)
        });
        controller.error(error);
        return;
      } finally {
        reader.releaseLock();
      }

      if (sendDone) {
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
        logInfo("proxy.provider.stream_success", {
          ...requestContext,
          provider,
          chunkCount,
          emittedCount,
          emittedChars,
          durationMs: Date.now() - startedAt
        });
      }
    }
  });
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

function errorFields(error) {
  const fields = {
    errorName: error?.name || "Error",
    errorMessage: error?.message || String(error),
    errorStack: error?.stack || ""
  };
  if (error?.cause) {
    fields.causeName = error.cause?.name || "Error";
    fields.causeMessage = error.cause?.message || String(error.cause);
    fields.causeStack = error.cause?.stack || "";
  }
  return fields;
}

function logInfo(event, fields = {}) {
  log("info", event, fields);
}

function logWarn(event, fields = {}) {
  log("warn", event, fields);
}

function logError(event, fields = {}) {
  log("error", event, fields);
}

function log(level, event, fields = {}) {
  const payload = {
    ts: new Date().toISOString(),
    level,
    event,
    ...fields
  };
  const line = JSON.stringify(payload);
  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

function normalizeSSEData(data, provider) {
  if (data === "[DONE]") {
    return { done: true };
  }

  let event;
  try {
    event = JSON.parse(data);
  } catch (error) {
    throw new ProxyHTTPError(502, "AI provider stream returned invalid JSON", { cause: error });
  }

  if (provider === "openai") {
    const choice = event.choices?.[0];
    return {
      done: Boolean(choice?.finish_reason),
      text: choice?.delta?.content || ""
    };
  }

  if (event.type === "message_stop") {
    return { done: true };
  }
  if (event.type === "content_block_delta") {
    return { text: event.delta?.text || "" };
  }
  return {};
}

function stripMarkdownFence(text) {
  return String(text)
    .trim()
    .replace(/^```(?:json|JSON)?\s*\n/, "")
    .replace(/\n\s*```\s*$/, "")
    .trim();
}

function systemPrompt(locale, vocabularyHints = []) {
  const basePrompt = locale === "zh" ? CHINESE_SYSTEM_PROMPT : ENGLISH_SYSTEM_PROMPT;
  if (!vocabularyHints.length) {
    return basePrompt;
  }
  return `${basePrompt}\n\n${vocabularyHintPrompt(locale, vocabularyHints)}`;
}

function vocabularyHintPrompt(locale, vocabularyHints) {
  if (locale === "zh") {
    return `用户近期常用词（仅作为识别和保留原词的上下文，不要因为这些词本身创建待办）：${vocabularyHints.join("、")}`;
  }
  return `Recent user vocabulary hints (context only for recognition and preserving exact terms; do not create todos just because these terms appear here): ${vocabularyHints.join(", ")}`;
}

class ProxyHTTPError extends Error {
  constructor(status, message, options = {}) {
    super(message, options);
    this.status = status;
  }
}

const CHINESE_SYSTEM_PROMPT = `你是一个待办事项提取助手。从用户的口语化输入中精准提取行动项。

核心规则：
1. 只提取行动项：感受、抱怨、背景信息不是 TODO。只有明确「要去做某事」才算
2. 过滤口语噪音：忽略「嗯」「那个」「就是」「我想想」等填充词
3. 保留用户原意：不要擅自扩展或拆解。用户说「准备面试」就是「准备面试」，不要拆成子步骤
4. 提取时间线索：如果提到时间（明天、下周三、月底前），提取为 due_hint 字段。没提到就留 null
5. 提取重复规则：只有明确出现「每天/每日/每周X/每月X号」时才设置 recurrence_rule；否则为 null。若出现「未来7天/接下来7天/连续7天」这类有限周期，end_date 用 YYYY-MM-DD 表示最后一次发生日期；无法确定具体日期时设为 null
6. 识别优先级线索：语气中有紧急感（赶紧、必须、来不及了）标记为 high，否则 normal
7. 一句话多条 TODO：用逗号、「然后」「还有」「顺便」等连接词分割的，拆成多条
8. 模糊意图处理：纯状态描述（如「最近好累」）不提取；隐含行动意图（「好累，得去看医生」）则提取「去看医生」

只返回 JSON，不要返回解释。格式如下：
{
  "todos": [
    {
      "title": "10字以内行动描述",
      "detail": "原话语境",
      "due_hint": "时间线索原文或null",
      "recurrence_rule": {
        "frequency": "daily/weekly/monthly",
        "weekdays": [2],
        "day_of_month": null,
        "end_date": null
      } 或 null,
      "priority": "high或normal",
      "category_hint": "work/study/life/health/finance/social/other"
    }
  ],
  "ignored": "被过滤内容摘要"
}`;

const ENGLISH_SYSTEM_PROMPT = `You are a todo extraction assistant. Extract actionable items from the user's casual spoken input.

Core rules:
1. Only extract action items: feelings, complaints, and background info are NOT todos. Only explicit "going to do something" counts
2. Filter filler words: ignore "um", "like", "you know", "let me think" etc.
3. Preserve user intent: don't expand or split. If the user says "prepare for interview", keep it as is
4. Extract time cues: if a time is mentioned (tomorrow, next Wednesday, by end of month), capture it in due_hint. Otherwise null
5. Extract recurrence only for explicit phrases like "every day", "daily", "every Monday", "weekly", or "monthly on the 1st"; otherwise recurrence_rule must be null. For bounded phrases like "for the next 7 days", set end_date to the final occurrence date in YYYY-MM-DD when the date can be determined; otherwise use null
6. Detect urgency: if tone has urgency (ASAP, must, running out of time) mark as high, otherwise normal
7. Multiple todos in one sentence: split by commas, "and then", "also", "plus" etc.
8. Ambiguous intent: pure state descriptions ("I'm so tired") are ignored; implied action ("so tired, need to see a doctor") extracts "see a doctor"

Return JSON only, with this shape:
{
  "todos": [
    {
      "title": "Brief action description (under 10 words)",
      "detail": "Original context",
      "due_hint": "Time cue text or null",
      "recurrence_rule": {
        "frequency": "daily/weekly/monthly",
        "weekdays": [6],
        "day_of_month": null,
        "end_date": null
      } or null,
      "priority": "high or normal",
      "category_hint": "work/study/life/health/finance/social/other"
    }
  ],
  "ignored": "Summary of filtered content"
}`;
