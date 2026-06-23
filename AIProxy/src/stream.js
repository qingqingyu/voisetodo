// Streaming response normalizer.
//
// Reads the upstream SSE stream from a provider Response.body and re-emits it
// as the iOS-client-facing SSE protocol:
//
//   data: {"text": "..."}\n\n
//   data: [DONE]\n\n
//
// Adapter-driven: parseSSEEvent knows how to interpret one upstream SSE payload
// for the provider that won the failover. Once a Response has been returned to
// the client, mid-stream errors can no longer trigger failover — they propagate
// through the ReadableStream so the client sees a failed read instead of a
// silently truncated response.

import { ProxyHTTPError } from "./errors.js";
import { logInfo, logWarn, logError, errorFields } from "./log.js";

const MAX_STREAM_EVENT_LINE_CHARS = 64 * 1024;

export function normalizeProviderStream(body, provider, adapter, requestContext, lifecycle = {}) {
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
            if (newlineIndex > MAX_STREAM_EVENT_LINE_CHARS) {
              throw new ProxyHTTPError(502, "AI provider stream event too large");
            }
            const line = buffer.slice(0, newlineIndex).trim();
            buffer = buffer.slice(newlineIndex + 1);
            if (!line.startsWith("data:")) {
              continue;
            }
            const normalized = adapter.parseSSEEvent(line.slice(5).trim());
            if (normalized.text) {
              emittedCount += 1;
              emittedChars += normalized.text.length;
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: normalized.text })}\n\n`));
            }
            if (normalized.done) {
              finished = true;
              logInfo("proxy.provider.stream_done", {
                ...requestContext,
                provider: provider.type,
                providerId: provider.id,
                chunkCount,
                emittedCount,
                emittedChars
              });
              break;
            }
          }
          if (buffer.length > MAX_STREAM_EVENT_LINE_CHARS) {
            throw new ProxyHTTPError(502, "AI provider stream event too large");
          }
        }
        if (!finished) {
          throw new ProxyHTTPError(502, "AI provider stream ended before done");
        }
        sendDone = true;
      } catch (error) {
        await runLifecycleCallback("failure", lifecycle.onFailure, provider, requestContext, error);
        logError("proxy.provider.stream_failed", {
          ...requestContext,
          provider: provider.type,
          providerId: provider.id,
          chunkCount,
          emittedCount,
          emittedChars,
          durationMs: Date.now() - startedAt,
          ...errorFields(error, { redactions: providerRedactions(provider) })
        });
        controller.error(error);
        return;
      } finally {
        reader.releaseLock();
      }

      if (sendDone) {
        await runLifecycleCallback("success", lifecycle.onSuccess, provider, requestContext);
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
        logInfo("proxy.provider.stream_success", {
          ...requestContext,
          provider: provider.type,
          providerId: provider.id,
          chunkCount,
          emittedCount,
          emittedChars,
          durationMs: Date.now() - startedAt
        });
      }
    }
  });
}

async function runLifecycleCallback(kind, callback, provider, requestContext, error) {
  if (!callback) return;
  try {
    await callback(error);
  } catch (callbackError) {
    logWarn("proxy.provider.stream_lifecycle_failed", {
      ...requestContext,
      provider: provider.type,
      providerId: provider.id,
      callback: kind,
      ...errorFields(callbackError, { redactions: providerRedactions(provider) })
    });
  }
}

function providerRedactions(provider) {
  const apiKey = provider?.apiKey || "";
  return [apiKey, encodeURIComponent(apiKey)].filter(Boolean);
}
