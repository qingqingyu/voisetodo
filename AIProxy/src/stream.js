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

// 终态事件后的有界收割窗口(2026-11-10):OpenAI 兼容流(include_usage)把 usage
// 放在 finish_reason 之后、关流之前的独立末块,正常毫秒级就到。上限是给
// 「上游发完终态却 keep-alive 不关流」的平台兜底:宁可 usage 三列 NULL,
// 不能挂住客户端 [DONE]。
const POST_FINISH_DRAIN_TIMEOUT_MS = 1500;
const DRAIN_TIMEOUT = Symbol("drain-timeout");

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
      // 逐行收割。次序是关键:同一行既带 text 又带 done(gemini 的最终文本就
      // 挂在 finish 事件上)时必须**先产出再置终态**——终态只冻结它**之后**
      // 的行(防个别平台 finish 后再吐字,客户端在"完成"后又收到内容)。
      // usage 通常只在末块出现,后见覆盖先见,经 requestContext 落 extract_requests。
      const drainBufferedLines = () => {
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
          if (normalized.usage) {
            requestContext.usage = normalized.usage;
          }
          if (normalized.text && !finished) {
            emittedCount += 1;
            emittedChars += normalized.text.length;
            fullText += normalized.text;
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: normalized.text })}\n\n`));
          }
          if (normalized.done) {
            finished = true;
          }
        }
        if (buffer.length > MAX_STREAM_EVENT_LINE_CHARS) {
          throw new ProxyHTTPError(502, "AI provider stream event too large");
        }
      };
      // 外层 try/finally:终态钩子覆盖「正常读完 / 中途失败 / 读循环意外 throw /
      // sendDone 段意外 throw」全部路径(catch 内的 return 也会先过这里的 finally)。
      try {
      try {
        // 主读循环:到终态事件(finish_reason / message_stop / [DONE])即停。
        while (!finished) {
          const { value, done } = await reader.read();
          if (done) {
            break;
          }
          chunkCount += 1;
          buffer += decoder.decode(value, { stream: true });
          drainBufferedLines();
        }
        if (!finished) {
          throw new ProxyHTTPError(502, "AI provider stream ended before done");
        }

        // ── 终态后有界收割(2026-11-10)──────────────────────────────────
        // OpenAI 兼容流(include_usage)的 usage 在 finish_reason 之后的独立
        // 末块:终态后继续读,只收 usage 不再产出文本。错误不进 onFailure——
        // 内容在终态前已完整,收尾期的连接 reset 是常态,把成功流误判成
        // stream_failed 会打乱退款/熔断/配额记账(见 worker.js onFailure 注释)。
        try {
          const drainDeadline = Date.now() + POST_FINISH_DRAIN_TIMEOUT_MS;
          let drainTimedOut = false;
          while (!drainTimedOut) {
            const remaining = drainDeadline - Date.now();
            if (remaining <= 0) {
              drainTimedOut = true;
              break;
            }
            // clearTimeout 必须走 finally:read reject(终态后连接 reset)时
            // Promise.race 直接抛出,写在 await 之后会漏清,悬空定时器挂满窗口。
            let timer;
            let readOrTimeout;
            try {
              readOrTimeout = await Promise.race([
                reader.read(),
                new Promise((resolve) => {
                  timer = setTimeout(() => resolve(DRAIN_TIMEOUT), remaining);
                })
              ]);
            } finally {
              clearTimeout(timer);
            }
            if (readOrTimeout === DRAIN_TIMEOUT) {
              drainTimedOut = true;
              break;
            }
            if (readOrTimeout.done) {
              break;
            }
            chunkCount += 1;
            buffer += decoder.decode(readOrTimeout.value, { stream: true });
            drainBufferedLines();
          }
          if (drainTimedOut) {
            logWarn("proxy.provider.stream_drain_timeout", {
              ...requestContext,
              provider: provider.type,
              providerId: provider.id,
              waitedMs: POST_FINISH_DRAIN_TIMEOUT_MS
            });
          }
        } catch (drainError) {
          logWarn("proxy.provider.stream_drain_failed", {
            ...requestContext,
            provider: provider.type,
            providerId: provider.id,
            ...errorFields(drainError, { redactions: providerRedactions(provider) })
          });
        }
        // stream_done 在收割之后打:usage 末块(finish 之后的独立块)与收割期
        // chunkCount 都要进这条日志,与 stream_success 的 usage 口径一致——放收割
        // 前会系统性缺这三列,按日志做 usage 分析时对不上。
        logInfo("proxy.provider.stream_done", {
          ...requestContext,
          provider: provider.type,
          providerId: provider.id,
          chunkCount,
          emittedCount,
          emittedChars,
          ...(requestContext.usage ?? {})
        });
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
        // 超时路径下可能仍有挂起的 read:cancel 让它收敛,releaseLock 才干净
        // (pending read 不会悬挂)。对已 closed/errored 的流 cancel 可能抛错,
        // 双层兜底后忽略——releaseLock 才是目的。
        await reader.cancel().catch(() => {});
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
          durationMs: Date.now() - startedAt,
          ...(requestContext.usage ?? {})
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
