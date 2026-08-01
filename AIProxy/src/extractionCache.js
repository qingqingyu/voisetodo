// Extraction result cache.
//
// 同一 transcript + locale + vocabularyHints + today 的请求,1 小时内重复时
// 直接返回 cache,省上游 AI 调用。主要用于:
//   - PendingRecoveryFlow 批处理重试(失败后重发相同 transcript)
//   - 用户口头禅重复("明天买牛奶" 等高频短语)
//   - 离线恢复后批量处理时的重复
//
// Cache 只覆盖**非流式**响应(stream=false)且**无 personalHints** 的请求。
// personalHints 是用户级个人术语表,不同用户不能共享 cache。
// 流式响应是 SSE 多事件序列,序列化复杂度高于纯 JSON,先不缓存。
//
// Cache key 包含 today 字段(YYYY-MM-DD),跨天后 cache 自动失效
// (相对日期词"明天"在不同 today 下解析结果不同)。TTL 1 小时也是兜底。
//
// KV 写失败静默降级 — 不阻塞业务请求,下次请求重新写。

import { logWarn, errorFields } from "./log.js";

const KV_KEY_PREFIX = "cache:";
const CACHE_TTL_SECONDS = 3600;  // 1 小时

export class ExtractionCacheStore {
  constructor() {
    this.kv = null;
  }

  /// 绑定 KV namespace。每次 request 开始时调(跟 HealthStore.updateKv 同模式)。
  updateKv(kv) {
    this.kv = kv || null;
  }

  /// 读 cache。KV 读失败时返 null(静默回退到真实调用)。
  async get(key) {
    if (!this.kv) return null;
    try {
      return await this.kv.get(key);
    } catch (error) {
      logWarn("extraction_cache.read_failed", { ...errorFields(error) });
      return null;
    }
  }

  /// 写 cache。KV 写失败时静默降级(只 log warn),不阻塞响应。
  /// 通常用 ctx.waitUntil 异步调用,避免阻塞 response 返回。
  async set(key, value) {
    if (!this.kv) return;
    try {
      await this.kv.put(key, value, { expirationTtl: CACHE_TTL_SECONDS });
    } catch (error) {
      logWarn("extraction_cache.write_failed", { ...errorFields(error) });
    }
  }

  /// 测试专用:重置 KV 引用。生产代码不调用。
  reset() {
    this.kv = null;
  }
}

/// 生成 cache key。相同输入必产生相同 key(跨 isolate / 跨 request 稳定)。
///
/// 输入要求:
/// - transcript:已 trim 的纯文本
/// - locale:已 normalize 的 BCP-47(如 "zh"、"en-US")
/// - vocabularyHints:已 normalize(去重 / 小写)的数组
/// - today:YYYY-MM-DD 字符串
///
/// **不包含** personalHints — 因为有 personalHints 的请求不 cache(调用方负责判断)。
export async function makeCacheKey({ transcript, locale, vocabularyHints, today }) {
  const hintsPart = Array.isArray(vocabularyHints) ? vocabularyHints.join(",") : "";
  const raw = `${transcript}|${locale}|${hintsPart}|${today}`;
  const hash = await shortHash(raw);
  return `${KV_KEY_PREFIX}${hash}`;
}

/// SHA-256 → base64 前 12 字符。Worker / Node 通用。
/// 12 字符 base64 = 72 bits,在 1 小时 TTL + 单 worker namespace 下碰撞概率忽略。
async function shortHash(value) {
  const encoder = new TextEncoder();
  const data = encoder.encode(value);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest);
  // base64 编码,取前 12 字符(避免 URL 不安全字符 +/= 出现在 key 里)
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/[+/=]/g, "").slice(0, 12);
}
