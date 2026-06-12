const MAX_BODY_BYTES = 16 * 1024;
const MAX_TRANSCRIPT_CHARS = 4000;
const DEFAULT_PROVIDER_TIMEOUT_MS = 20_000;

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, ctx, fetch);
  }
};

export async function handleRequest(request, env = {}, ctx = {}, fetchImpl = fetch) {
  try {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/todo-extractions") {
      return new Response("Not Found", { status: 404 });
    }
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const authError = validateAppToken(request, env);
    if (authError) {
      return authError;
    }

    const declaredLength = Number(request.headers.get("content-length") || "0");
    if (declaredLength > MAX_BODY_BYTES) {
      return new Response("Request too large", { status: 413 });
    }

    const payload = await readPayload(request);
    const transcript = String(payload.transcript || "").trim();
    if (!transcript) {
      return new Response("Missing transcript", { status: 400 });
    }
    if (transcript.length > MAX_TRANSCRIPT_CHARS) {
      return new Response("Transcript too large", { status: 413 });
    }

    const locale = normalizeLocale(payload.locale);
    await enforceDailyLimit(request, env);

    const provider = normalizeProvider(env.AI_PROVIDER);
    if (payload.stream === true) {
      return await streamProviderResponse(provider, transcript, locale, env, fetchImpl);
    }

    const text = await callProviderText(provider, transcript, locale, env, fetchImpl);
    return new Response(text, {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store"
      }
    });
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      return new Response(error.message, { status: error.status });
    }
    return new Response("AI proxy failed", { status: 502 });
  }
}

async function readPayload(request) {
  try {
    const text = await request.text();
    const byteLength = new TextEncoder().encode(text).length;
    if (byteLength > MAX_BODY_BYTES) {
      throw new ProxyHTTPError(413, "Request too large");
    }
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof ProxyHTTPError) {
      throw error;
    }
    throw new ProxyHTTPError(400, "Invalid JSON");
  }
}

function validateAppToken(request, env) {
  if (!env.APP_TOKEN) {
    if (env.ALLOW_UNAUTHENTICATED_PROXY === "true") {
      return null;
    }
    return new Response("APP_TOKEN not configured", { status: 500 });
  }
  const provided = request.headers.get("X-App-Token") || "";
  const expected = String(env.APP_TOKEN);
  if (provided === expected || provided === `Bearer ${expected}`) {
    return null;
  }
  return new Response("Unauthorized", { status: 401 });
}

async function enforceDailyLimit(request, env) {
  if (!env.RATE_LIMIT_KV || !env.DAILY_REQUEST_LIMIT) {
    return;
  }
  const limit = Number(env.DAILY_REQUEST_LIMIT);
  if (!Number.isFinite(limit) || limit <= 0) {
    return;
  }

  const deviceId = request.headers.get("X-Device-ID")
    || request.headers.get("CF-Connecting-IP")
    || "anonymous";
  const today = new Date().toISOString().slice(0, 10);
  const key = `quota:${today}:${deviceId}`;
  const current = Number(await env.RATE_LIMIT_KV.get(key) || "0");
  if (current >= limit) {
    throw new ProxyHTTPError(429, "Daily quota exceeded");
  }
  await env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: 36 * 60 * 60 });
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

async function callProviderText(provider, transcript, locale, env, fetchImpl) {
  const response = await callProvider(provider, transcript, locale, env, fetchImpl, false);
  const data = await readProviderJSON(response);

  if (provider === "openai") {
    const text = data?.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProxyHTTPError(502, "OpenAI response missing text");
    }
    return stripMarkdownFence(text);
  }

  const text = data?.content?.find((part) => part.type === "text")?.text
    || data?.content?.[0]?.text;
  if (!text) {
    throw new ProxyHTTPError(502, "Anthropic response missing text");
  }
  return stripMarkdownFence(text);
}

async function streamProviderResponse(provider, transcript, locale, env, fetchImpl) {
  const response = await callProvider(provider, transcript, locale, env, fetchImpl, true);
  if (!response.body) {
    throw new ProxyHTTPError(502, "AI provider streaming response missing body");
  }

  return new Response(normalizeProviderStream(response.body, provider), {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-store",
      "Connection": "keep-alive"
    }
  });
}

async function callProvider(provider, transcript, locale, env, fetchImpl, stream) {
  const response = provider === "openai"
    ? await callOpenAI(transcript, locale, env, fetchImpl, stream)
    : await callAnthropic(transcript, locale, env, fetchImpl, stream);

  if (!response.ok) {
    const status = response.status === 429 ? 429 : 502;
    throw new ProxyHTTPError(status, "AI provider error");
  }
  return response;
}

async function callAnthropic(transcript, locale, env, fetchImpl, stream) {
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
      system: systemPrompt(locale),
      messages: [{ role: "user", content: transcript }]
    })
  });
}

async function callOpenAI(transcript, locale, env, fetchImpl, stream) {
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
        { role: "system", content: systemPrompt(locale) },
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

async function readProviderJSON(response) {
  try {
    return await response.json();
  } catch {
    throw new ProxyHTTPError(502, "AI provider returned invalid JSON");
  }
}

function normalizeProviderStream(body, provider) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let buffer = "";
  let finished = false;

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
              break;
            }
            if (normalized.text) {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: normalized.text })}\n\n`));
            }
          }
        }
        sendDone = true;
      } catch (error) {
        controller.error(error);
        return;
      } finally {
        reader.releaseLock();
      }

      if (sendDone) {
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      }
    }
  });
}

function normalizeSSEData(data, provider) {
  if (data === "[DONE]") {
    return { done: true };
  }

  let event;
  try {
    event = JSON.parse(data);
  } catch {
    return {};
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

function systemPrompt(locale) {
  return locale === "zh" ? CHINESE_SYSTEM_PROMPT : ENGLISH_SYSTEM_PROMPT;
}

class ProxyHTTPError extends Error {
  constructor(status, message) {
    super(message);
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
