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

// 告警外呼超时:cron 是串行链路(GC → 探活 → 告警 → 心跳),Telegram 挂起会卡住
// 后面的心跳,healthchecks.io 会误报「Worker 死了」。与上游探针(probeTimeoutMs
// 10s)同量级;worker.js 的心跳 ping 复用同一常量,两条外呼一致。
export const ALERT_FETCH_TIMEOUT_MS = 10_000;

/// 发送一条 Telegram 告警文本。永远 resolve:
///   { ok: true }                     发送成功
///   { ok: false, skipped: true }     未配置 secrets,静默跳过
///   { ok: false }                    发送失败(网络 / 超时 / Telegram 拒绝),已 logWarn
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
      body: JSON.stringify({ chat_id: chatId, text }),
      signal: AbortSignal.timeout(ALERT_FETCH_TIMEOUT_MS)
    });
    if (!resp.ok) {
      const errText = await resp.text();
      logWarn("alert.telegram.failed", { status: resp.status, body: errText.slice(0, 200) });
      return { ok: false };
    }
    // Workers 惯例:不消费的 body 显式 cancel,释放底层流/连接资源。
    // 2xx 即已送达;cancel 失败(如流在响应头后 errored)只影响资源回收,
    // 单独留痕,不改写送达判定 —— 否则会把已送达的告警记成 { ok: false }。
    try {
      await resp.body?.cancel();
    } catch (error) {
      logWarn("alert.telegram.body_cancel_failed", { errorName: error?.name, errorMessage: error?.message });
    }
    return { ok: true };
  } catch (error) {
    logWarn("alert.telegram.failed", { errorName: error?.name, errorMessage: error?.message });
    return { ok: false };
  }
}
