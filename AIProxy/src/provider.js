// Provider failover executor.
//
// Walks the selector's candidate list in order, calling the right adapter for each.
// Failure handling is split into two regimes:
//
//   - Build/fetch stage (before Response reaches the caller):
//     Any failure here is failover-eligible. Network errors / timeouts are always
//     retryable. Non-2xx responses are classified by adapter.isRetryable using
//     status + body keywords; non-retryable ones bubble up as 502 to the client
//     (the request body itself is bad — switching provider won't help).
//
//   - Body validation stage (after an HTTP 200):
//     The optional onResponse hook may validate a non-stream body or verify a stream
//     body exists before anything reaches the client. Hook failures are failover-
//     eligible while another candidate remains. Mid-stream failures after the caller
//     returns the Response still propagate through the ReadableStream.
//
// On success, returns { provider, adapter, response, bodyResult } so the caller
// can either use a pre-validated non-stream bodyResult or wrap the stream body.
// Exhausting retryable pre-body failures throws 503; a final pre-client body
// validation failure keeps its original 502.

import { getAdapter } from "./adapters/index.js";
import { ProxyHTTPError } from "./errors.js";
import { logInfo, logWarn, logError, errorFields, redactText } from "./log.js";

const MAX_PROVIDER_ERROR_BODY_BYTES = 64 * 1024;

export async function executeWithFailover(candidates, params, fetchImpl, requestContext, options = {}) {
  if (!candidates.length) {
    logWarn("proxy.selector.empty", { ...requestContext });
    throw new ProxyHTTPError(503, "All providers unavailable");
  }

  const healthStore = options.healthStore || null;
  const onResponse = typeof options.onResponse === "function" ? options.onResponse : null;
  const attempts = [];
  const stream = Boolean(params.stream);

  for (let index = 0; index < candidates.length; index++) {
    const provider = candidates[index];
    const adapter = getAdapter(provider.type);
    if (!adapter) {
      // config.js validates types against the registry, so this is a defensive guard.
      throw new ProxyHTTPError(500, `Unknown adapter for provider ${provider.id}`);
    }

    const attempt = {
      providerId: provider.id,
      providerType: provider.type,
      model: provider.model,
      attempt: index + 1,
      startedAt: Date.now()
    };

    logInfo("proxy.provider.call_start", {
      ...requestContext,
      providerId: provider.id,
      provider: provider.type,
      model: provider.model,
      attempt: attempt.attempt,
      stream
    });

    const hasNext = index < candidates.length - 1;
    let response = null;
    let responseError = null;

    try {
      const { url, init } = adapter.buildRequest({ ...params, provider });
      // Intentionally NOT storing url on the attempt record: Gemini embeds the API
      // key as a query param, and providerAttempts[] is echoed back through the
      // requestContext spread in proxy.request.finished. Keeping the URL out of
      // the persisted attempt keeps secrets out of logs unconditionally.
      response = await fetchImpl(url, init);
    } catch (error) {
      // 不变量违反（如 buildSystemPrompt 的 today 缺失）不属于 provider 故障，
      // 不应触发 failover 浪费其他 provider 配额。直接向上抛，由 handleRequest 的
      // catch 统一处理为 500。
      if (error instanceof ProxyHTTPError && error.body?.error === "invariant_violation") {
        throw error;
      }
      responseError = error;
    }

    attempt.durationMs = Date.now() - attempt.startedAt;

    if (responseError) {
      const errorType = classifyFetchError(responseError);
      const classification = adapter.isRetryable({ status: null, bodyText: "", errorType });
      attempt.errorType = classification.errorType;
      attempt.errorMessage = redactText(responseError?.message || String(responseError), providerRedactions(provider));
      attempts.push(attempt);
      recordAttempts(requestContext, attempts, provider.id);
      logProviderFailure(provider, attempt, classification, requestContext, responseError, undefined, hasNext);
      if (classification.retryable && healthStore) {
        await healthStore.recordFailure(provider.id, classification.errorType);
      }
      if (classification.errorType === "auth") {
        logWarn("proxy.provider.auth_failed_alert", {
          ...requestContext,
          providerId: provider.id,
          provider: provider.type
        });
      }
      if (!classification.retryable) {
        // Hard-fail on non-retryable error — aborting the failover chain is safer
        // than continuing when the caller's environment is broken.
        throw new ProxyHTTPError(502, `Provider ${provider.id} failed before response`);
      }
      continue;
    }

    attempt.providerStatus = response.status;

    if (!response.ok) {
      let bodyText = "";
      let errorBodyTruncated = false;
      let errorBodyBytes = 0;
      try {
        const errorBody = await readResponseTextWithLimit(response, MAX_PROVIDER_ERROR_BODY_BYTES);
        bodyText = errorBody.text;
        errorBodyTruncated = errorBody.truncated;
        errorBodyBytes = errorBody.bytesRead;
      } catch (readError) {
        logWarn("proxy.provider.error_body_unreadable", {
          ...requestContext,
          providerId: provider.id,
          ...errorFields(readError, { redactions: providerRedactions(provider) })
        });
      }
      const classification = adapter.isRetryable({ status: response.status, bodyText });
      attempt.errorType = classification.errorType;
      if (errorBodyTruncated) {
        attempt.errorBodyTruncated = true;
        attempt.errorBodyBytes = errorBodyBytes;
      }
      attempts.push(attempt);
      recordAttempts(requestContext, attempts, provider.id);
      logProviderFailure(provider, attempt, classification, requestContext, null, response.status, hasNext);
      if (classification.retryable && healthStore) {
        await healthStore.recordFailure(provider.id, classification.errorType);
      }
      if (classification.errorType === "auth") {
        logWarn("proxy.provider.auth_failed_alert", {
          ...requestContext,
          providerId: provider.id,
          provider: provider.type
        });
      }
      if (!classification.retryable) {
        // 4xx request-body problem: another provider would reject the same payload.
        throw new ProxyHTTPError(502, `Provider ${provider.id} rejected request (status ${response.status})`);
      }
      continue;
    }

    let bodyResult = null;
    if (onResponse) {
      try {
        bodyResult = await onResponse({ response, provider, adapter, attempt });
        attempt.durationMs = Date.now() - attempt.startedAt;
      } catch (validationError) {
        attempt.durationMs = Date.now() - attempt.startedAt;
        const classification = {
          retryable: true,
          errorType: validationError?.errorType || "invalid_response"
        };
        attempt.errorType = classification.errorType;
        attempt.errorMessage = redactText(validationError?.message || String(validationError), providerRedactions(provider));
        attempts.push(attempt);
        recordAttempts(requestContext, attempts, provider.id);
        logProviderFailure(provider, attempt, classification, requestContext, validationError, response.status, hasNext);
        if (healthStore) {
          await healthStore.recordFailure(provider.id, classification.errorType);
        }
        if (!hasNext) {
          throw validationError instanceof ProxyHTTPError
            ? validationError
            : new ProxyHTTPError(502, "AI provider response invalid", { cause: validationError, errorType: classification.errorType });
        }
        continue;
      }
    }

    attempts.push(attempt);
    recordAttempts(requestContext, attempts, provider.id);
    requestContext.providerUsed = provider.id;
    requestContext.failoverCount = index;

    logInfo("proxy.provider.call_success", {
      ...requestContext,
      providerId: provider.id,
      provider: provider.type,
      model: provider.model,
      attempt: attempt.attempt,
      providerStatus: response.status,
      durationMs: attempt.durationMs,
      stream
    });

    // Defer healthStore.recordSuccess to the caller: HTTP 200 only means the
    // connection succeeded, not that the body is valid. The caller invokes
    // confirmSuccess() after successfully extracting text from the response.
    const confirmSuccess = async () => {
      if (healthStore) {
        await healthStore.recordSuccess(provider.id, attempt.durationMs);
      }
    };
    const confirmFailure = async (errorType = "stream") => {
      if (healthStore) {
        await healthStore.recordFailure(provider.id, errorType);
      }
    };

    return { provider, adapter, response, attempts, bodyResult, confirmSuccess, confirmFailure };
  }

  logError("proxy.provider.all_failed", {
    ...requestContext,
    providersTried: attempts.map((a) => a.providerId),
    attempts
  });
  throw new ProxyHTTPError(503, "All providers unavailable");
}

function classifyFetchError(error) {
  if (error?.name === "AbortError") return "timeout";
  if (error?.name === "TimeoutError") return "timeout";
  if (error?.name === "TypeError") return "network";
  return "network";
}

async function readResponseTextWithLimit(response, maxBytes) {
  if (!response.body) {
    return { text: "", bytesRead: 0, truncated: false };
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let bytesRead = 0;
  let text = "";
  let truncated = false;

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }

      if (bytesRead + value.byteLength > maxBytes) {
        const allowed = Math.max(0, maxBytes - bytesRead);
        if (allowed > 0) {
          text += decoder.decode(value.slice(0, allowed), { stream: true });
          bytesRead += allowed;
        }
        truncated = true;
        await reader.cancel("Provider error body too large");
        break;
      }

      bytesRead += value.byteLength;
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return { text, bytesRead, truncated };
  } finally {
    reader.releaseLock();
  }
}

function recordAttempts(requestContext, attempts, lastProviderId) {
  requestContext.providerAttempts = attempts;
  requestContext.providersTried = attempts.map((a) => a.providerId);
  if (lastProviderId) {
    requestContext.lastProviderTried = lastProviderId;
  }
}

function logProviderFailure(provider, attempt, classification, requestContext, error, status, hasNext = true) {
  const fields = {
    ...requestContext,
    providerId: provider.id,
    provider: provider.type,
    model: provider.model,
    attempt: attempt.attempt,
    durationMs: attempt.durationMs,
    errorType: classification.errorType,
    retryable: classification.retryable
  };
  if (typeof status === "number") {
    fields.providerStatus = status;
  }
  if (attempt.errorBodyTruncated) {
    fields.errorBodyTruncated = true;
    fields.errorBodyBytes = attempt.errorBodyBytes;
  }
  if (error) {
    Object.assign(fields, errorFields(error, { redactions: providerRedactions(provider) }));
  }
  // Intentionally NOT logging provider error body: upstream 4xx/5xx responses can
  // echo back the user's transcript or other sensitive content. Status code +
  // errorType classification is sufficient for debugging without PII risk.
  logWarn("proxy.provider.call_failed", fields);
  if (classification.retryable && hasNext) {
    // Signal that the executor is moving on to the next candidate. The next
    // call_start log will name the actual next provider; this event lets
    // dashboards count failovers without parsing the attempt chain.
    logInfo("proxy.provider.failover", {
      ...requestContext,
      fromProviderId: provider.id,
      reason: classification.errorType
    });
  }
}

function providerRedactions(provider) {
  const apiKey = provider?.apiKey || "";
  return [apiKey, encodeURIComponent(apiKey)].filter(Boolean);
}
