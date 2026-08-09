// VoiceTodo 用户反馈 → Telegram 推送 + D1 归档
//
// 设计原则:
// - 与 AIProxy 风格一致:module-style worker,JSON-line 日志,APP_TOKEN 校验
// - 失败容忍:D1 写失败不阻断 Telegram 推送;Telegram 推送失败也不返 500
//   (用户已经提交了,Worker 端再叠加 5xx 没意义,D1 已经留底)
// - 截图走 Telegram 本身存储(sendPhoto),不引入 R2

const MAX_BODY_BYTES = 5 * 1024 * 1024; // 5MB,允许带截图
const MAX_SCREENSHOT_BYTES = 3 * 1024 * 1024; // 单张截图 3MB 上限(Telegram sendPhoto 限制 10MB,留余量)
const MAX_DESCRIPTION_CHARS = 4000;
const MAX_TRANSCRIPT_CHARS = 1000; // 上下文 transcript 截断
const MAX_TITLE_CHARS = 200;

const VALID_TYPES = new Set([
  "translation",   // 翻译问题
  "ai_output",     // AI 输出不自然
  "bug",           // Bug
  "suggestion"     // 功能建议
]);

const TYPE_LABELS = {
  translation: "🌐 翻译问题",
  ai_output: "🤖 AI 输出不自然",
  bug: "🐛 Bug",
  suggestion: "💡 功能建议"
};

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, ctx);
  }
};

export async function handleRequest(request, env, ctx) {
  const url = new URL(request.url);

  if (url.pathname !== "/v1/feedback") {
    return jsonResponse({ error: "not_found" }, 404);
  }
  if (request.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const authError = validateAppToken(request, env);
  if (authError) {
    log("warn", "feedback.auth.failed", { reason: authError.reason });
    return authError.response;
  }

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (declaredLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "body_too_large" }, 413);
  }

  let payload;
  try {
    payload = await readPayload(request);
  } catch (error) {
    // 流式读取里 body 超限会抛 code="body_too_large",要返 413 而不是 400。
    // 其它(截断后的 JSON.parse 失败 / stream 异常)归 400。
    if (error?.code === "body_too_large") {
      log("warn", "feedback.body_too_large", { declaredLength });
      return jsonResponse({ error: "body_too_large" }, 413);
    }
    log("warn", "feedback.invalid_json", errorFields(error));
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const feedback = normalizeFeedback(payload);
  if (feedback.errors.length > 0) {
    return jsonResponse({ error: "invalid_payload", details: feedback.errors }, 400);
  }

  log("info", "feedback.received", {
    type: feedback.type,
    locale: feedback.locale,
    hasScreenshot: feedback.hasScreenshot,
    descriptionChars: feedback.description.length
  });

  // 1. D1 archive(失败不阻断推送,D1 暂未配则跳过)
  let archiveId = null;
  if (env.FEEDBACK_DB) {
    try {
      const result = await env.FEEDBACK_DB.prepare(
        `INSERT INTO feedback
         (received_at, type, description, locale, app_version, os_version, device_model, transcript, extracted_todo_title, has_screenshot)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        Date.now(),
        feedback.type,
        feedback.description,
        feedback.locale,
        feedback.appVersion,
        feedback.osVersion,
        feedback.deviceModel,
        feedback.transcript,
        feedback.extractedTodoTitle,
        feedback.hasScreenshot ? 1 : 0
      ).run();
      archiveId = result.meta?.last_row_id ?? null;
    } catch (error) {
      log("error", "feedback.archive_failed", errorFields(error));
    }
  }

  // 2. Telegram 推送(失败更新 archive 状态,但不返 500)
  const delivery = await deliverToTelegram(env, feedback);

  if (env.FEEDBACK_DB && archiveId) {
    await env.FEEDBACK_DB.prepare(
      "UPDATE feedback SET telegram_delivered = ?, telegram_error = ? WHERE id = ?"
    ).bind(delivery.ok ? 1 : 0, delivery.error || null, archiveId).run()
      .catch((error) => log("warn", "feedback.archive_status_update_failed", errorFields(error)));
  } else if (env.FEEDBACK_DB && !archiveId) {
    // D1 INSERT 成功但 last_row_id 缺字段,或 INSERT 失败但 Telegram 推送继续。
    // 这条反馈的 telegram_delivered 状态无法回写,补推查询会漏掉。
    log("warn", "feedback.archive_id_missing", {
      deliveryOk: delivery.ok,
      deliveryError: delivery.error || null
    });
  }

  if (!delivery.ok) {
    log("error", "feedback.telegram_failed", { error: delivery.error, archiveId });
    // 仍然返 200 给客户端:用户的反馈已经进了 D1,客户端不应让用户重试
    // (重试会再灌一条;Worker 端能补推就补推,补不推等手动查 D1)
    return jsonResponse({ ok: false, archived: archiveId !== null, warning: "delivery_delayed" });
  }

  log("info", "feedback.delivered", { archiveId });
  return jsonResponse({ ok: true, archiveId });
}

function validateAppToken(request, env) {
  const expected = env.APP_TOKEN;
  if (!expected) {
    return {
      reason: "missing_app_token_config",
      response: jsonResponse({ error: "server_misconfigured" }, 500)
    };
  }
  const provided = request.headers.get("X-App-Token");
  if (!provided || provided !== expected) {
    return {
      reason: provided ? "token_mismatch" : "token_missing",
      response: jsonResponse({ error: "unauthorized" }, 401)
    };
  }
  return null;
}

async function readPayload(request) {
  // 流式读取 + 累计计数,避免一次性 arrayBuffer() 把超大 body 灌满 isolate 内存。
  // Workers isolate 限 128MB,客户端 controlled 的 content-length 不可信(可省略/伪造),
  // 必须在字节流入时计数,超限立刻 abort。
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      // 主动 cancel reader,释放已读字节
      await reader.cancel();
      const err = new Error("body_too_large");
      err.code = "body_too_large";
      throw err;
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const text = new TextDecoder().decode(merged);
  return JSON.parse(text);
}

function normalizeFeedback(payload) {
  const errors = [];
  const type = String(payload?.type || "").trim();
  if (!VALID_TYPES.has(type)) {
    errors.push("invalid_type");
  }

  const description = String(payload?.description || "").trim();
  if (!description) {
    errors.push("missing_description");
  } else if (description.length > MAX_DESCRIPTION_CHARS) {
    errors.push("description_too_long");
  }

  let screenshotBase64 = null;
  let screenshotMime = null;
  const rawScreenshot = payload?.screenshotBase64;
  if (rawScreenshot) {
    const str = String(rawScreenshot);
    // base64 每 4 字符约 3 字节
    const approxBytes = Math.floor((str.length * 3) / 4);
    if (approxBytes > MAX_SCREENSHOT_BYTES) {
      errors.push("screenshot_too_large");
    } else {
      screenshotBase64 = str;
      screenshotMime = String(payload?.screenshotMime || "image/jpeg");
    }
  }

  return {
    type,
    description,
    locale: takeString(payload?.locale, 32) || null,
    appVersion: takeString(payload?.appVersion, 32) || null,
    osVersion: takeString(payload?.osVersion, 32) || null,
    deviceModel: takeString(payload?.deviceModel, 64) || null,
    transcript: payload?.transcript ? takeString(payload.transcript, MAX_TRANSCRIPT_CHARS) : null,
    extractedTodoTitle: payload?.extractedTodoTitle ? takeString(payload.extractedTodoTitle, MAX_TITLE_CHARS) : null,
    screenshotBase64,
    screenshotMime,
    hasScreenshot: screenshotBase64 !== null,
    errors
  };
}

function takeString(value, max) {
  const str = String(value ?? "").trim();
  return str.slice(0, max);
}

async function deliverToTelegram(env, feedback) {
  const token = env.TELEGRAM_BOT_TOKEN;
  const chatId = env.TELEGRAM_CHAT_ID;
  if (!token || !chatId) {
    return { ok: false, error: "telegram_not_configured" };
  }

  const text = buildTelegramMessage(feedback);

  try {
    if (feedback.hasScreenshot) {
      // 截图优先,文本作为 caption(单条消息,Telegram 限 caption 1024 字符)。
      // 截到 1020 + 省略号 = 1023,留 1 字符安全余量(避免多字节字符边界撑破 1024)。
      const caption = text.length > 1024 ? text.slice(0, 1020) + "..." : text;
      const photoBytes = base64ToUint8(feedback.screenshotBase64);

      const formData = new FormData();
      formData.append("chat_id", chatId);
      formData.append("photo", new Blob([photoBytes], { type: feedback.screenshotMime }), "screenshot.jpg");
      formData.append("caption", caption);

      const resp = await fetch(`https://api.telegram.org/bot${token}/sendPhoto`, {
        method: "POST",
        body: formData
      });
      if (!resp.ok) {
        const errText = await resp.text();
        return { ok: false, error: `telegram_${resp.status}: ${errText.slice(0, 200)}` };
      }
      return { ok: true };
    }

    const resp = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text })
    });
    if (!resp.ok) {
      const errText = await resp.text();
      return { ok: false, error: `telegram_${resp.status}: ${errText.slice(0, 200)}` };
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error.message || String(error) };
  }
}

function buildTelegramMessage(feedback) {
  const lines = [
    "🆕 VoiceTodo 反馈",
    "",
    TYPE_LABELS[feedback.type] || feedback.type,
    "",
    "💬 " + feedback.description,
    ""
  ];

  const meta = [];
  if (feedback.locale) meta.push("语言:" + feedback.locale);
  if (feedback.appVersion) meta.push("App:" + feedback.appVersion);
  if (feedback.osVersion) meta.push("iOS:" + feedback.osVersion);
  if (feedback.deviceModel) meta.push("设备:" + feedback.deviceModel);
  if (meta.length > 0) lines.push(meta.join(" · "));

  if (feedback.transcript || feedback.extractedTodoTitle) {
    lines.push("");
    lines.push("── 上下文 ──");
    if (feedback.extractedTodoTitle) lines.push("待办:" + feedback.extractedTodoTitle);
    if (feedback.transcript) lines.push("原话:" + feedback.transcript);
  }

  return lines.join("\n");
}

function base64ToUint8(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function log(level, event, fields = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    event,
    ...fields
  });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

function errorFields(error) {
  return {
    errorName: error?.name || "Error",
    errorMessage: error?.message || String(error)
  };
}
