// Anthropic Messages API adapter.
//
// Upstream contract:
//   POST {provider.url}
//   Headers: x-api-key, anthropic-version, content-type
//   Body:    { model, max_tokens, temperature, stream, system, messages }
//
// SSE events we care about:
//   - content_block_delta  -> { delta: { text } }
//   - message_stop         -> terminal

import { buildSystemPrompt, buildSplitPrompt, buildReflectPrompt, stripMarkdownFence, ProxyHTTPError, classifyHttpRetryable, mergeSignals } from "./base.js";

// Anthropic error bodies that indicate a model-side fix (just retry against the next
// provider, whose model may not have this problem). Anything else in 400/422 is treated
// as a request-body problem and bubbles back to the client as 502.
const ANTHROPIC_MODEL_CONFIG_KEYWORDS = [
  "model_not_found",
  "model not found",
  "context_length",
  "context window",
  "maximum context length"
];

export const anthropicAdapter = {
  type: "anthropic",

  buildRequest({ transcript, locale, vocabularyHints, stream, provider, today, personalHints, mode, abortSignal }) {
    if (!provider.apiKey) {
      throw new ProxyHTTPError(500, "Anthropic key not configured");
    }
    return {
      url: provider.url,
      init: {
        method: "POST",
        // 合并客户端断连信号 + 单次调用超时。客户端划走时上游 fetch 立刻 abort,
        // 不再继续烧 token 到 timeoutMs。
        signal: mergeSignals(abortSignal, AbortSignal.timeout(provider.timeoutMs)),
        headers: {
          "Content-Type": "application/json",
          "anthropic-version": "2023-06-01",
          "x-api-key": provider.apiKey
        },
        body: JSON.stringify({
          model: provider.model,
          // Sonnet 4.5 输出上限 8192,取满:4096 时 ~20+ 条待办的 JSON 就会被强制掐断
          // (iOS 端 transcriptTooLong,确定性错误、重试必败)。提到 8192 把触发门槛推到
          // ~40+ 条。max_tokens 是上限不是目标值——正常短输入的输出 token 与成本不变。
          // 旧值 500 在中文 JSON 下只够 ~10 个待办就被强制截断,
          // 导致下游 JSON 解析失败(见 iOS 端 jsonParsingFailed 报错)。
          max_tokens: 8192,
          temperature: 0,
          stream,
          // split(拆小)/reflect(语义对照)换专用 prompt;
          // today/vocabularyHints/personalHints 仅提取模式有意义
          system: mode === "split"
            ? buildSplitPrompt(locale)
            : mode === "reflect"
              ? buildReflectPrompt(locale)
              : buildSystemPrompt(locale, vocabularyHints, today, personalHints),
          messages: [{ role: "user", content: transcript }]
        })
      }
    };
  },

  extractText(json) {
    const text = json?.content?.find((part) => part.type === "text")?.text
      || json?.content?.[0]?.text;
    return text ? stripMarkdownFence(text) : null;
  },

  isRetryable({ status, bodyText, errorType }) {
    return classifyHttpRetryable({ status, bodyText, errorType }, ANTHROPIC_MODEL_CONFIG_KEYWORDS);
  },

  parseSSEEvent(rawData) {
    if (rawData === "[DONE]") {
      return { done: true };
    }
    let event;
    try {
      event = JSON.parse(rawData);
    } catch (error) {
      throw new ProxyHTTPError(502, "AI provider stream returned invalid JSON", { cause: error });
    }
    if (event.type === "message_stop") {
      return { done: true };
    }
    if (event.type === "content_block_delta") {
      return { text: event.delta?.text || "" };
    }
    return {};
  }
};
