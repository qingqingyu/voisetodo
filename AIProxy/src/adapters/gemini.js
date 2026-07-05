// Google Gemini generateContent / streamGenerateContent adapter.
//
// Upstream contract differences vs Anthropic/OpenAI:
//   - URL embeds both the model and the API key as a query param:
//       POST {provider.url}/{provider.model}:generateContent?key={apiKey}
//       POST {provider.url}/{provider.model}:streamGenerateContent?key={apiKey}&alt=sse
//   - Request body uses Google's `contents` / `parts` schema.
//   - Non-streaming response is `{ candidates: [{ content: { parts: [{ text }] } }] }`.
//   - Streaming chunks are the same shape; terminal signal is `finishReason` on a chunk.
//
// Logging safety: this adapter builds a URL containing the secret. We rely on the
// provider layer NOT to log URLs and on the request layer NOT to echo upstream URLs
// back to the client. Never add `attempt.url` to a log payload.

import { buildSystemPrompt, stripMarkdownFence, ProxyHTTPError, classifyHttpRetryable } from "./base.js";

const GEMINI_MODEL_CONFIG_KEYWORDS = [
  "model not found",
  "not supported",
  "context length",
  "token limit",
  "permissiondenied"
];

export const geminiAdapter = {
  type: "gemini",

  buildRequest({ transcript, locale, vocabularyHints, stream, provider, today }) {
    if (!provider.apiKey) {
      throw new ProxyHTTPError(500, "Gemini key not configured");
    }
    if (!provider.model) {
      throw new ProxyHTTPError(500, "Gemini model not configured");
    }
    const action = stream ? "streamGenerateContent" : "generateContent";
    const search = stream
      ? `?key=${encodeURIComponent(provider.apiKey)}&alt=sse`
      : `?key=${encodeURIComponent(provider.apiKey)}`;
    const url = `${trimTrailingSlash(provider.url)}/${provider.model}:${action}${search}`;
    return {
      url,
      init: {
        method: "POST",
        signal: AbortSignal.timeout(provider.timeoutMs),
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: buildSystemPrompt(locale, vocabularyHints, today) }] },
          contents: [{ role: "user", parts: [{ text: transcript }] }],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 500,
            responseMimeType: "application/json"
          }
        })
      }
    };
  },

  extractText(json) {
    const parts = json?.candidates?.[0]?.content?.parts;
    if (!Array.isArray(parts) || parts.length === 0) {
      return null;
    }
    const text = parts.map((part) => part?.text || "").join("");
    return text ? stripMarkdownFence(text) : null;
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
    const candidate = event?.candidates?.[0];
    const finishReason = candidate?.finishReason;
    const text = candidate?.content?.parts?.map((part) => part?.text || "").join("") || "";
    // Gemini emits a non-empty finishReason on the final chunk; treat it as terminal.
    const done = Boolean(finishReason) && finishReason !== "FINISH_REASON_UNSPECIFIED";
    return { done, text };
  },

  isRetryable({ status, bodyText, errorType }) {
    return classifyHttpRetryable({ status, bodyText, errorType }, GEMINI_MODEL_CONFIG_KEYWORDS);
  }
};

function trimTrailingSlash(url) {
  return String(url || "").replace(/\/+$/, "");
}
