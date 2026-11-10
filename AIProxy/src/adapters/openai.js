// OpenAI Chat Completions adapter.
//
// Upstream contract:
//   POST {provider.url}
//   Headers: Authorization: Bearer, content-type
//   Body:    { model, temperature, stream, response_format, messages }
//
// SSE events we care about:
//   - choices[].delta.content      -> text chunk
//   - choices[].finish_reason      -> terminal

import { buildSystemPrompt, buildSplitPrompt, buildReflectPrompt, stripMarkdownFence, normalizeUsage, ProxyHTTPError, classifyHttpRetryable, mergeSignals } from "./base.js";

// OpenAI error bodies that indicate the model in this provider can't serve the request;
// failover to a different provider (which may have a different model) is worth trying.
const OPENAI_MODEL_CONFIG_KEYWORDS = [
  "model does not exist",
  "does not exist or you do not have access",
  "does not exist",
  "context_length_exceeded",
  "maximum context length",
  "model_not_found"
];

export const openaiAdapter = {
  type: "openai",

  buildRequest({ transcript, locale, vocabularyHints, stream, provider, today, personalHints, mode, abortSignal }) {
    if (!provider.apiKey) {
      throw new ProxyHTTPError(500, "OpenAI key not configured");
    }
    if (!provider.model) {
      throw new ProxyHTTPError(500, "OpenAI model not configured");
    }
    return {
      url: provider.url,
      init: {
        method: "POST",
        // 合并客户端断连信号 + 单次调用超时
        signal: mergeSignals(abortSignal, AbortSignal.timeout(provider.timeoutMs)),
        headers: {
          "Authorization": `Bearer ${provider.apiKey}`,
          "Content-Type": "application/json",
          // A3:条目级附加头(如 OpenRouter 建议 的 HTTP-Referer/X-Title)。
          // 保留字段(Authorization/Content-Type)在 config.js 拒绝覆盖,这里直接展开。
          ...(provider.extraHeaders || {})
        },
        body: JSON.stringify({
          model: provider.model,
          temperature: 0,
          stream,
          // 流式 usage 捕获(2026-11-10):条目声明 includeStreamUsage 时请求末块
          // usage(OpenAI 兼容语义:finish_reason 之后的独立块)。opt-in 而非默认:
          // 不认 stream_options 的平台回 400 → request_body 非重试类 → 不 failover,
          // 该条目流式全死;先在 OpenRouter 验证,z.ai 等验证过再开。
          ...(stream && provider.includeStreamUsage ? { stream_options: { include_usage: true } } : {}),
          // A3:disableResponseFormat 条目不发送 response_format——部分平台不支持
          // 该参数会 400(request_body 不重试直接 502),此时靠 prompt 约束 JSON。
          // 默认开启:目标平台(OpenRouter 及国内 OpenAI 兼容平台)普遍支持。
          ...(provider.disableResponseFormat ? {} : { response_format: { type: "json_object" } }),
          messages: [
            // split(拆小)/reflect(语义对照)换专用 prompt;
            // today/vocabularyHints/personalHints 仅提取模式有意义
            {
              role: "system",
              content: mode === "split"
                ? buildSplitPrompt(locale)
                : mode === "reflect"
                  ? buildReflectPrompt(locale)
                  : buildSystemPrompt(locale, vocabularyHints, today, personalHints)
            },
            { role: "user", content: transcript }
          ],
          // A3:条目级附加体字段(如关闭思考/推理、上游路由偏好)。
          // 保留字段(model/messages/stream)在 config.js 拒绝覆盖。
          ...(provider.extraBody || {})
        })
      }
    };
  },

  extractText(json) {
    const text = json?.choices?.[0]?.message?.content;
    return text ? stripMarkdownFence(text) : null;
  },

  isRetryable({ status, bodyText, errorType }) {
    return classifyHttpRetryable({ status, bodyText, errorType }, OPENAI_MODEL_CONFIG_KEYWORDS);
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
    const choice = event.choices?.[0];
    return {
      done: Boolean(choice?.finish_reason),
      text: choice?.delta?.content || "",
      // usage 通常随末块(finish_reason 同块)出现;OpenAI 官方流需 include_usage
      // 才有,OpenRouter 默认附带——有则记,无则 null(阶段 0 埋点,见 base.js)
      usage: normalizeUsage(event.usage)
    };
  }
};
