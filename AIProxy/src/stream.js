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
  // 全文累积(原始增量拼接,可能带 markdown fence):流式响应头早已发出,唯一能判断
  // 「这次流到底给没给出待办」的位置是流末尾——调用方(worker.js onSuccess)拿
  // fullText 做空结果判定(todos=[] → 退 device 额度)。上限受 provider max_tokens
  // 与单行 64KB 限制约束,内存可忽略。
  let fullText = "";
  const startedAt = Date.now();

  return new ReadableStream({
    async start(controller) {
      const reader = body.getReader();
      let sendDone = false;
      let settled = false;
      const settle = async () => {
        if (settled) return;
        settled = true;
        await runLifecycleCallback("settled", lifecycle.onSettled, provider, requestContext, null, {});
      };
      // 外层 try/finally:终态钩子覆盖「正常读完 / 中途失败 / 读循环意外 throw /
      // sendDone 段意外 throw」全部路径(catch 内的 return 也会先过这里的 finally)。
      try {
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
              fullText += normalized.text;
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
        await runLifecycleCallback("failure", lifecycle.onFailure, provider, requestContext, error, {
          emittedCount,
          emittedChars
        });
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
        await runLifecycleCallback("success", lifecycle.onSuccess, provider, requestContext, null, {
          emittedCount,
          emittedChars,
          fullText
        });
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
        logInfo("proxy.provider.stream_success", {
          ...requestContext,
          provider: provider.type,
          providerId: provider.id,
          chunkCount,
          emittedCount,
          emittedChars,
          fullTextChars: fullText.length,
          durationMs: Date.now() - startedAt
        });
      }
      } finally {
        // 流生命周期终态:无论正常结束、中途失败还是意外 throw,都释放闸门租约。
        // settle 幂等,重复调用(既有 catch 内已有 return 路径)不会二次触发。
        await settle();
      }
    }
  });
}

// stats = { emittedCount, emittedChars, fullText }:已经推给客户端的 todo 数 /
// 字符数 / 完整文本拼接。调用方(worker.js)据此判断:
//   - onFailure:"响应头已 200 但一个字都没给" vs "已给部分可用结果",前者退配额
//   - onSuccess:fullText 解析不出非空 todos(空结果)→ 退 device 配额(2026-10 修复)
//
// lifecycle.onSettled(A2 闸门):流结束(成功读完 / 中途失败 / 异常)后必调一次,
// 与 onSuccess/onFailure 的先后关系是「它们先跑,settled 最后」。调用方把闸门
// 租约的 release 挂在这里——这是「流式请求占用的 key 名额」唯一可靠的回收点,
// 任何 throw 路径都由外层 finally 兜住(任务书 §7:租约泄漏是最大风险)。
async function runLifecycleCallback(kind, callback, provider, requestContext, error, stats) {
  if (!callback) return;
  try {
    await callback(error, stats);
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
