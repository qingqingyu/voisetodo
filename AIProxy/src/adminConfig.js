// Admin-managed runtime provider override.
//
// Allows switching the primary provider at runtime via
// /v1/admin/providers/primary without redeploying. The override is stored in
// AI_PROVIDER_STATE_KV under "config:providers_primary" and read with a 30s
// in-memory cache (per-isolate) to bound KV cost.
//
// Shape:
//   { primaryId: "CLAWTO_OPENAI", updatedAt: <ms>, updatedBy: "sha256:..." }
//
// Override is a thin layer on top of env.PROVIDERS (toml vars): it only
// rewrites the `priority` field via applyPrimaryOverride so the selector
// naturally picks the override primary first. Sensitive fields (secret/url/
// model) are NEVER touched — those still require redeploy, by design.

import { logWarn, errorFields } from "./log.js";

const KV_KEY = "config:providers_primary";
const CACHE_TTL_MS = 30_000;

export class AdminConfigStore {
  constructor() {
    this.kv = null;
    // cache: { value, fetchedAt } | null。value = override 对象或 null。
    // 30s 内复用缓存值,过期才读 KV。
    this.cache = null;
  }

  /// 绑定 KV namespace。每个请求开始时调用(跟 HealthStore.updateKv 同模式),
  /// 让 isolate 在 KV binding 变化时(理论上不会,但防御)拿到最新引用。
  updateKv(kv) {
    this.kv = kv || null;
  }

  /// 读取当前 primary override。
  /// 返回 override 对象(含 primaryId/updatedAt/updatedBy)或 null(无 override / KV 未绑定)。
  /// KV 读失败时用旧缓存值兜底;从未读过则返 null(走 toml 默认)。
  async getPrimaryOverride() {
    const now = Date.now();
    if (this.cache && now - this.cache.fetchedAt < CACHE_TTL_MS) {
      return this.cache.value;
    }
    if (!this.kv) {
      return null;
    }
    try {
      const raw = await this.kv.get(KV_KEY);
      const value = raw ? JSON.parse(raw) : null;
      this.cache = { value, fetchedAt: now };
      return value;
    } catch (error) {
      logWarn("admin_config.kv.read_failed", { ...errorFields(error) });
      // KV 读失败:不抛错,用旧缓存或 null(toml 默认)兜底,避免 admin 配置故障影响业务请求。
      return this.cache?.value ?? null;
    }
  }

  /// 写入 primary override。立即刷新缓存,让本 isolate 后续请求立即看到新值。
  /// 其他 isolate 最迟 30s 后缓存过期读到新值,加上 KV 跨 region 传播最多 60s。
  async setPrimaryOverride(primaryId, updatedBy) {
    if (!this.kv) {
      throw new Error("AI_PROVIDER_STATE_KV not bound");
    }
    const value = {
      primaryId,
      updatedAt: Date.now(),
      updatedBy: updatedBy || null
    };
    await this.kv.put(KV_KEY, JSON.stringify(value));
    this.cache = { value, fetchedAt: Date.now() };
    return value;
  }

  /// 清除 primary override,回到 toml 默认。立即刷新缓存。
  async clearPrimaryOverride() {
    if (!this.kv) {
      return;
    }
    try {
      await this.kv.delete(KV_KEY);
    } catch (error) {
      logWarn("admin_config.kv.delete_failed", { ...errorFields(error) });
      // 不抛:即使 KV delete 失败,本地缓存已被清空,本 isolate 后续请求走 toml 默认;
      // 其他 isolate 最迟 30s 后也会因为缓存过期重新读 KV(读到旧值或 null,取决于 KV 传播)。
    }
    this.cache = { value: null, fetchedAt: Date.now() };
  }

  /// 测试专用:重置模块级单例状态。生产代码不调用。
  reset() {
    this.kv = null;
    this.cache = null;
  }
}

/// 把 primaryId 对应的 provider 的 priority 设为 1,
/// 其他原 priority <= 1 的降为 2(避免和新的 primary 抢同一优先级),
/// 其余保持原 priority。
///
/// 若 primaryId 不在 providers 里,返回原数组(由 caller 决定报 400 还是忽略)。
///
/// 纯函数,不修改入参。selector 的 sortByPriority 是升序(priority 小的优先),
/// 所以 primaryId 设为 1 后会排到最前。
export function applyPrimaryOverride(providers, primaryId) {
  if (!Array.isArray(providers) || providers.length === 0 || !primaryId) {
    return providers;
  }
  const exists = providers.some((p) => p.id === primaryId);
  if (!exists) {
    return providers;
  }
  return providers.map((p) => {
    if (p.id === primaryId) {
      return { ...p, priority: 1 };
    }
    // 其他 priority <= 1 的 provider 降级到 2,避免和 primary 抢优先级。
    // priority > 1 的保持原值(它们本来就在 primary 后面)。
    if (Number.isFinite(p.priority) && p.priority <= 1) {
      return { ...p, priority: 2 };
    }
    return p;
  });
}
