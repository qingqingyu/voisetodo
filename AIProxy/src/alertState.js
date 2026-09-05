// 告警状态机(层 B,ALERTING.md):cron 探活结果的「状态跃迁」判定与持久化。
//
// 只在状态跃迁时告警,不是每次失败都告警(告警疲劳 = bot 被静音 = 白做):
//   - level 变化 → 推
//   - 仍是 down 且距上次推送 ≥ 6h → 推 reminder
//   - 其余 → 不推
//
// 存储复用 AI_PROVIDER_STATE_KV,key `alert:provider_health`,值
//   { level: "ok"|"degraded"|"down", since: <ms>, lastNotifiedAt: <ms> }
// `alert:` 前缀与 health: / config: 共存,跟 src/health.js / adminConfig.js 的做法一致。
//
// 降级原则:KV 读失败 → previous 视为 null → shouldNotify 判定为「无历史」→
// 有故障就推。宁可多推一条,不可漏报。

import { logWarn, errorFields } from "./log.js";

const KV_KEY = "alert:provider_health";
const REMINDER_INTERVAL_MS = 6 * 3600 * 1000;

/// 探活结果 → 告警 level。纯函数。
///   succeeded === total → "ok";部分成功 → "degraded";全挂 → "down"
/// total === 0 → null:没有 provider 可计入时走 caller 的 skipped 分支不告警 ——
/// 配置问题不该被误报成服务故障。cron 路径的「secrets 全缺」(total > 0 但全部
/// no_key)由 worker.js 的 probeable 守卫拦下,不会走到这里的 total === 0。
export function classifyLevel(succeeded, total) {
  if (!Number.isFinite(succeeded) || !Number.isFinite(total) || total <= 0) {
    return null;
  }
  if (succeeded <= 0) return "down";
  return succeeded < total ? "degraded" : "ok";
}

/// 跃迁判定。纯函数,now 由 caller 注入(测试可控时,别用真实时钟)。
///   previous: 上次记录 { level, since, lastNotifiedAt } | null(无历史 / KV 读失败)
///   current:  classifyLevel 的返回值;null(skipped)一律不推
/// 返回 { notify, kind }:kind ∈ "recovered" | "degraded" | "down" | "reminder" | null
export function shouldNotify(previous, current, now) {
  if (!current) return { notify: false, kind: null };
  const prevLevel = previous?.level || null;

  if (prevLevel !== current) {
    if (current === "ok") {
      // ok 从不主动推;只有「从故障恢复到 ok」才推 recovered
      return prevLevel ? { notify: true, kind: "recovered" } : { notify: false, kind: null };
    }
    // 首次见到 down/degraded(prevLevel null,含 KV 读失败的降级路径)也视为跃迁 → 推
    return { notify: true, kind: current };
  }

  if (current === "down" && now - (previous.lastNotifiedAt || previous.since || 0) >= REMINDER_INTERVAL_MS) {
    return { notify: true, kind: "reminder" };
  }
  return { notify: false, kind: null };
}

/// 由判定结果算出下一份要落盘的记录。纯函数。
///   - level 变化 → since 重置为 now(新状态的起点)
///   - 推送过 → lastNotifiedAt = now;否则沿用旧值(reminder 的 6h 窗口靠它)
export function nextRecord(previous, current, decision, now) {
  const levelChanged = !previous || previous.level !== current;
  return {
    level: current,
    since: levelChanged ? now : (previous.since || now),
    lastNotifiedAt: decision.notify ? now : (previous?.lastNotifiedAt || 0)
  };
}

/// KV 存取包装,形态对齐 HealthStore(updateKv 每请求刷新 binding 引用)。
/// load/save 内部吞掉 KV 异常并 logWarn —— 告警状态读写失败绝不打断 cron;
/// 读失败返回 null(语义见文件头「降级原则」)。
export class AlertStateStore {
  constructor() {
    this.kv = null;
  }

  updateKv(kv) {
    this.kv = kv || null;
  }

  async load() {
    if (!this.kv) return null;
    try {
      const raw = await this.kv.get(KV_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (error) {
      logWarn("alert_state.kv.read_failed", errorFields(error));
      return null;
    }
  }

  async save(record) {
    if (!this.kv) return;
    try {
      await this.kv.put(KV_KEY, JSON.stringify(record));
    } catch (error) {
      logWarn("alert_state.kv.write_failed", errorFields(error));
    }
  }

  /// 测试专用:重置模块级单例状态。生产代码不调用。
  reset() {
    this.kv = null;
  }
}
