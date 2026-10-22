// Provider configuration loader.
//
// Two modes:
//   1. Multi-provider: env.PROVIDERS is a JSON array of provider descriptors.
//      Each descriptor carries non-sensitive fields (url, model, priority, weight,
//      enabled, secretName/secretNames); the secret itself is resolved from
//      env[secretName].
//   2. Legacy single-provider: env.PROVIDERS absent, fall back to AI_PROVIDER +
//      ANTHROPIC_API_KEY / OPENAI_API_KEY. Produces a single-element list so the
//      rest of the pipeline stays shape-compatible.
//
// Key pools (A1, docs/capacity-scenario-a-task.md §1):
//   - `secretNames`(数组,多 key 池)与 `secretName`(单 key,旧格式)互斥,
//     同时出现 = 配置错误(throw)。
//   - 每个 secret 缺失只跳过该 key(onSecretMissing 逐 key 记录);
//     整组都缺失才视为条目不可用(keys 为空 → selector 过滤,与旧 apiKey="" 同路)。
//   - 熔断/健康记录的 key 标识 `healthId`:单 key 配置沿用条目 id(与改前字节一致,
//     不产生 KV 记录迁移);多 key 配置用 `条目id#序号`(序号 = secretNames 中的
//     原始位置,与该 key 是否有 secret 无关——位置稳定,中途补 secret 不漂移)。
//   - `maxConcurrencyPerKey`:可选正整数。配置后该条目走每 key 并发闸门(A2);
//     不配 = 不限(例如 OpenRouter 按量付费)。
//   - `extraHeaders` / `extraBody` / `disableResponseFormat`:仅 openai 类型条目
//     (A3,换服务商准备)。extraBody 不得覆盖 model/messages/stream,
//     extraHeaders 不得覆盖 Authorization/Content-Type——覆盖 = 配置错误。
//     不在代码里写死任何服务商参数名,字段由 wrangler.toml 按服务商文档配置。
//
// Validation policy:
//   - Structural errors (bad JSON, unknown type, non-https url, empty model,
//     empty array, malformed id, key-pool/extra 字段形状非法) → throw, surfaces
//     as HTTP 500 to every request.
//   - Multi-provider missing secret (entry is well-formed but env[secretName]
//     is empty) → NOT a startup failure; we keep the entry with keys=[] /
//     apiKey="" and let the selector layer filter it out, logging a warn so
//     operators notice.
//   - Legacy single-provider missing required key/model → throw, because there
//     is no fallback provider to absorb the deployment misconfiguration.

import { listAdapterTypes } from "./adapters/index.js";

const ID_PATTERN = /^[A-Z0-9_]+$/;
const LEGACY_ANTHROPIC_DEFAULT_MODEL = "claude-sonnet-4-20250514";
const LEGACY_ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const LEGACY_OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const LEGACY_DEFAULT_TIMEOUT_MS = 20_000;
const DEFAULT_PROVIDER_TIMEOUT_MS = 15_000;
const DEFAULT_PRIORITY = 100;
const DEFAULT_WEIGHT = 1;
const MAX_TIMEOUT_MS = 60_000;
// extraBody 里保留给 adapter 自己拼装的字段:覆盖 = 配置错误(静默覆盖会让
// 「换个模型」这类运维操作被一个 stale 的 extraBody 值悄悄抵消)。
const RESERVED_BODY_FIELDS = new Set(["model", "messages", "stream"]);
// extraHeaders 里保留给 adapter 的头:Authorization 是 key 的载体,Content-Type
// 是序列化协议——被 extraHeaders 覆盖等于把 key 发去错误的位置或破坏请求体协商。
const RESERVED_HEADER_FIELDS = new Set(["Authorization", "Content-Type"]);

export function loadProviders(env, { onSecretMissing = () => {} } = {}) {
  if (!env.PROVIDERS) {
    return legacyProvidersFromEnv(env);
  }

  let raw;
  try {
    raw = JSON.parse(env.PROVIDERS);
  } catch (error) {
    throw new Error(`PROVIDERS JSON parse failed: ${error.message}`);
  }

  if (!Array.isArray(raw)) {
    throw new Error("PROVIDERS must be a JSON array");
  }
  if (raw.length === 0) {
    throw new Error("PROVIDERS is empty");
  }

  const adapterTypes = new Set(listAdapterTypes());
  return raw.map((entry, index) => parseProviderEntry(entry, index, env, adapterTypes, onSecretMissing));
}

function parseProviderEntry(entry, index, env, adapterTypes, onSecretMissing) {
  if (!entry || typeof entry !== "object") {
    throw new Error(`PROVIDERS[${index}] is not an object`);
  }

  const id = String(entry.id || "").toUpperCase();
  if (!ID_PATTERN.test(id)) {
    throw new Error(`PROVIDERS[${index}].id "${entry.id}" must match ^[A-Z0-9_]+$ (use secretName to decouple from key naming)`);
  }

  const type = String(entry.type || "");
  if (!adapterTypes.has(type)) {
    throw new Error(`PROVIDERS[${index}] (id=${id}) has unknown type "${type}"`);
  }

  const url = String(entry.url || "");
  if (!url.startsWith("https://")) {
    throw new Error(`PROVIDERS[${index}] (id=${id}) url must start with https://`);
  }

  const model = String(entry.model || "");
  if (!model) {
    throw new Error(`PROVIDERS[${index}] (id=${id}) model must be non-empty`);
  }

  // ── key 池解析(secretName 单数 | secretNames 复数,互斥)──────────────────
  const hasSingular = entry.secretName !== undefined && entry.secretName !== null;
  const hasPlural = entry.secretNames !== undefined && entry.secretNames !== null;
  if (hasSingular && hasPlural) {
    throw new Error(`PROVIDERS[${index}] (id=${id}) must not set both secretName and secretNames — pick one form`);
  }
  let secretNames;
  if (hasPlural) {
    if (!Array.isArray(entry.secretNames) || entry.secretNames.length === 0) {
      throw new Error(`PROVIDERS[${index}] (id=${id}) secretNames must be a non-empty array`);
    }
    secretNames = entry.secretNames.map((name, keyIndex) => {
      const value = String(name || "");
      if (!value) {
        throw new Error(`PROVIDERS[${index}] (id=${id}) secretNames[${keyIndex}] must be non-empty`);
      }
      return value;
    });
  } else {
    secretNames = [String(entry.secretName || `PROVIDER_KEY_${id}`)];
  }

  // 多 key 配置才给 healthId 加 #序号;单 key(含缺省)沿用条目 id,
  // 旧配置的 KV 熔断记录路径与改前完全一致(R5)。
  const multiKey = secretNames.length > 1;
  const keys = [];
  secretNames.forEach((secretName, keyIndex) => {
    const apiKey = String(env[secretName] || "");
    if (!apiKey) {
      onSecretMissing({ id, secretName });
      return;
    }
    keys.push({
      index: keyIndex,
      secretName,
      apiKey,
      healthId: multiKey ? `${id}#${keyIndex}` : id
    });
  });

  // ── 每 key 并发上限(可选,A2 闸门开关)──────────────────────────────────
  let maxConcurrencyPerKey;
  if (entry.maxConcurrencyPerKey !== undefined) {
    const value = entry.maxConcurrencyPerKey;
    if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
      throw new Error(`PROVIDERS[${index}] (id=${id}) maxConcurrencyPerKey must be a positive integer`);
    }
    maxConcurrencyPerKey = value;
  }

  // ── A3:openai 条目的附加头/体(换服务商准备)────────────────────────────
  let extraHeaders;
  let extraBody;
  let disableResponseFormat;
  if (entry.extraHeaders !== undefined && entry.extraHeaders !== null) {
    if (type !== "openai") {
      throw new Error(`PROVIDERS[${index}] (id=${id}) extraHeaders is only supported on openai-type entries`);
    }
    if (!isPlainObject(entry.extraHeaders)) {
      throw new Error(`PROVIDERS[${index}] (id=${id}) extraHeaders must be an object`);
    }
    for (const headerName of Object.keys(entry.extraHeaders)) {
      if (RESERVED_HEADER_FIELDS.has(headerName)) {
        throw new Error(`PROVIDERS[${index}] (id=${id}) extraHeaders must not override ${headerName}`);
      }
    }
    extraHeaders = entry.extraHeaders;
  }
  if (entry.extraBody !== undefined && entry.extraBody !== null) {
    if (type !== "openai") {
      throw new Error(`PROVIDERS[${index}] (id=${id}) extraBody is only supported on openai-type entries`);
    }
    if (!isPlainObject(entry.extraBody)) {
      throw new Error(`PROVIDERS[${index}] (id=${id}) extraBody must be an object`);
    }
    for (const fieldName of Object.keys(entry.extraBody)) {
      if (RESERVED_BODY_FIELDS.has(fieldName)) {
        throw new Error(`PROVIDERS[${index}] (id=${id}) extraBody must not override ${fieldName}`);
      }
    }
    extraBody = entry.extraBody;
  }
  if (entry.disableResponseFormat !== undefined && entry.disableResponseFormat !== null) {
    if (type !== "openai") {
      throw new Error(`PROVIDERS[${index}] (id=${id}) disableResponseFormat is only supported on openai-type entries`);
    }
    if (typeof entry.disableResponseFormat !== "boolean") {
      throw new Error(`PROVIDERS[${index}] (id=${id}) disableResponseFormat must be a boolean`);
    }
    disableResponseFormat = entry.disableResponseFormat;
  }

  return {
    id,
    type,
    url,
    model,
    secretName: secretNames[0],
    keys,
    // 兼容旧消费方(selector 的「有无可用 key」谓词、探活的前置检查)。
    // 多 key 条目的实际 key 选择不走这个字段(见 provider.js / keyGate.js)。
    apiKey: keys[0]?.apiKey || "",
    maxConcurrencyPerKey,
    extraHeaders,
    extraBody,
    disableResponseFormat,
    priority: Number.isFinite(entry.priority) ? Number(entry.priority) : DEFAULT_PRIORITY,
    weight: Number.isFinite(entry.weight) && entry.weight > 0 ? Number(entry.weight) : DEFAULT_WEIGHT,
    enabled: entry.enabled !== false,
    timeoutMs: Number.isFinite(entry.timeoutMs) && entry.timeoutMs > 0
      ? Math.min(Number(entry.timeoutMs), MAX_TIMEOUT_MS)
      : DEFAULT_PROVIDER_TIMEOUT_MS
  };
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function legacyProvidersFromEnv(env) {
  const type = normalizeLegacyProvider(env.AI_PROVIDER);
  const timeoutMs = readLegacyTimeoutMs(env);

  if (type === "openai") {
    const apiKey = String(env.OPENAI_API_KEY || "");
    const model = String(env.OPENAI_MODEL || "");
    if (!apiKey) {
      throw new Error("OPENAI_API_KEY is required when AI_PROVIDER=openai");
    }
    if (!model) {
      throw new Error("OPENAI_MODEL is required when AI_PROVIDER=openai");
    }
    return [legacyEntry({
      id: "OPENAI_LEGACY",
      type: "openai",
      url: LEGACY_OPENAI_URL,
      model,
      secretName: "OPENAI_API_KEY",
      apiKey,
      timeoutMs
    })];
  }

  const apiKey = String(env.ANTHROPIC_API_KEY || "");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is required when AI_PROVIDER=anthropic");
  }

  return [legacyEntry({
    id: "ANTHROPIC_LEGACY",
    type: "anthropic",
    url: LEGACY_ANTHROPIC_URL,
    model: env.ANTHROPIC_MODEL || LEGACY_ANTHROPIC_DEFAULT_MODEL,
    secretName: "ANTHROPIC_API_KEY",
    apiKey,
    timeoutMs
  })];
}

// 旧单 provider 路径 → 统一的 keys 数组形状(单 key,healthId = 条目 id)。
function legacyEntry({ id, type, url, model, secretName, apiKey, timeoutMs }) {
  return {
    id,
    type,
    url,
    model,
    secretName,
    keys: [{ index: 0, secretName, apiKey, healthId: id }],
    apiKey,
    maxConcurrencyPerKey: undefined,
    extraHeaders: undefined,
    extraBody: undefined,
    disableResponseFormat: undefined,
    priority: 1,
    weight: 1,
    enabled: true,
    timeoutMs
  };
}

function normalizeLegacyProvider(provider) {
  const value = String(provider || "anthropic").toLowerCase();
  return value === "openai" ? "openai" : "anthropic";
}

function readLegacyTimeoutMs(env) {
  const configured = Number(env.AI_PROVIDER_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0
    ? Math.min(configured, MAX_TIMEOUT_MS)
    : LEGACY_DEFAULT_TIMEOUT_MS;
}
