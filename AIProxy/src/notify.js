// Telegram 告警发送(层 B,ALERTING.md)。
//
// 刻意从 feedback-relay/worker.js 的 deliverToTelegram 复制同款 sendMessage 实现,
// 而非跨 worker 调用 —— 告警链路的依赖越少越好:如果 AIProxy 要靠调 feedback-relay
// 才能告警,就多了一个能一起挂的环节。这是告警系统该有的偏执。
//
// 三条硬约束:
//   1. 必须接受 fetchImpl 参数。handleScheduled(env, fetchImpl) 是可注入签名,
//      测试靠它拦截 Telegram 调用;不透传会在跑测试时打真实网络。
//   2. 未配 TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID → logWarn 后返回 skipped,不抛错。
//   3. 发送异常自己 catch 掉,同样只 log —— 绝不打断 cron(cron 还要做 telemetry GC)。

import { logWarn } from "./log.js";

/// 发送一条 Telegram 告警文本。永远 resolve:
///   { ok: true }                     发送成功
///   { ok: false, skipped: true }     未配置 secrets,静默跳过
///   { ok: false }                    发送失败(网络 / Telegram 拒绝),已 logWarn
export async function sendTelegramAlert(env, text, fetchImpl = fetch) {
  const token = env?.TELEGRAM_BOT_TOKEN;
  const chatId = env?.TELEGRAM_CHAT_ID;
  if (!token || !chatId) {
    logWarn("alert.telegram.skipped", { reason: "telegram_not_configured" });
    return { ok: false, skipped: true };
  }
  try {
    const resp = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text })
    });
    if (!resp.ok) {
      const errText = await resp.text();
      logWarn("alert.telegram.failed", { status: resp.status, body: errText.slice(0, 200) });
      return { ok: false };
    }
    return { ok: true };
  } catch (error) {
    logWarn("alert.telegram.failed", { errorName: error?.name, errorMessage: error?.message });
    return { ok: false };
  }
}
