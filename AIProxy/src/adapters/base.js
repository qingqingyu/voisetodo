// Adapter contract + shared prompt/fence utilities.
//
// Each provider adapter is a plain object implementing:
//   - type                       : provider type tag (matches ProviderConfig.type)
//   - buildRequest({transcript, locale, vocabularyHints, stream, provider}) -> {url, init}
//   - extractText(json)          : pull text from a non-streaming provider response
//   - parseSSEEvent(rawData)     : convert one upstream SSE payload into {done, text}
//   - isRetryable({status, bodyText, error}) -> {retryable, errorType}
//
// buildRequest is the only place an adapter touches credentials/headers/body, so the
// upstream fetch contract (URL + standard RequestInit) stays in one place per provider.

import { ProxyHTTPError } from "../errors.js";

export { ProxyHTTPError };

// Shared retry classification for HTTP-level errors. Adapters may layer their own
// 400/422 body-keyword checks on top via `modelConfigKeywords`.
export function classifyHttpRetryable({ status, bodyText, errorType }, modelConfigKeywords = []) {
  if (errorType === "network" || errorType === "abort" || errorType === "timeout") {
    return { retryable: true, errorType };
  }
  if (status === 401 || status === 403) {
    return { retryable: true, errorType: "auth" };
  }
  if (status === 408 || status === 429) {
    return { retryable: true, errorType: `status_${status}` };
  }
  if (status >= 500 && status < 600) {
    return { retryable: true, errorType: `status_${status}` };
  }
  if (status === 400 || status === 422) {
    const lower = String(bodyText || "").toLowerCase();
    const hit = modelConfigKeywords.find((keyword) => lower.includes(keyword));
    if (hit) {
      return { retryable: true, errorType: "model_config" };
    }
    return { retryable: false, errorType: "request_body" };
  }
  return { retryable: false, errorType: `status_${status}` };
}

export function buildSystemPrompt(locale, vocabularyHints = []) {
  const basePrompt = locale === "zh" ? CHINESE_SYSTEM_PROMPT : ENGLISH_SYSTEM_PROMPT;
  if (!vocabularyHints.length) {
    return basePrompt;
  }
  return `${basePrompt}\n\n${vocabularyHintPrompt(locale, vocabularyHints)}`;
}

export function vocabularyHintPrompt(locale, vocabularyHints) {
  if (locale === "zh") {
    return `用户近期常用词（仅作为识别和保留原词的上下文，不要因为这些词本身创建待办）：${vocabularyHints.join("、")}`;
  }
  return `Recent user vocabulary hints (context only for recognition and preserving exact terms; do not create todos just because these terms appear here): ${vocabularyHints.join(", ")}`;
}

export function stripMarkdownFence(text) {
  return String(text)
    .trim()
    .replace(/^```(?:json|JSON)?\s*\n/, "")
    .replace(/\n\s*```\s*$/, "")
    .trim();
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
