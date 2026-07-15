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

import { buildSystemPrompt, stripMarkdownFence, ProxyHTTPError, classifyHttpRetryable } from "./base.js";

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

  buildRequest({ transcript, locale, vocabularyHints, stream, provider, today, personalHints }) {
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
        signal: AbortSignal.timeout(provider.timeoutMs),
        headers: {
          "Authorization": `Bearer ${provider.apiKey}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: provider.model,
          temperature: 0.1,
          stream,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: buildSystemPrompt(locale, vocabularyHints, today, personalHints) },
            { role: "user", content: transcript }
          ]
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
      text: choice?.delta?.content || ""
    };
  }
};
