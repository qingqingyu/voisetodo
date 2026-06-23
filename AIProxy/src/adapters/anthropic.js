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

import { buildSystemPrompt, stripMarkdownFence, ProxyHTTPError, classifyHttpRetryable } from "./base.js";

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

  buildRequest({ transcript, locale, vocabularyHints, stream, provider }) {
    if (!provider.apiKey) {
      throw new ProxyHTTPError(500, "Anthropic key not configured");
    }
    return {
      url: provider.url,
      init: {
        method: "POST",
        signal: AbortSignal.timeout(provider.timeoutMs),
        headers: {
          "Content-Type": "application/json",
          "anthropic-version": "2023-06-01",
          "x-api-key": provider.apiKey
        },
        body: JSON.stringify({
          model: provider.model,
          max_tokens: 500,
          temperature: 0.1,
          stream,
          system: buildSystemPrompt(locale, vocabularyHints),
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
