// Provider configuration loader.
//
// Two modes:
//   1. Multi-provider: env.PROVIDERS is a JSON array of provider descriptors.
//      Each descriptor carries non-sensitive fields (url, model, priority, weight,
//      enabled, secretName); the secret itself is resolved from env[secretName].
//   2. Legacy single-provider: env.PROVIDERS absent, fall back to AI_PROVIDER +
//      ANTHROPIC_API_KEY / OPENAI_API_KEY. Produces a single-element list so the
//      rest of the pipeline stays shape-compatible.
//
// Validation policy:
//   - Structural errors (bad JSON, unknown type, non-https url, empty model,
//     empty array, malformed id) → throw, surfaces as HTTP 500 to every request.
//   - Multi-provider missing secret (entry is well-formed but env[secretName]
//     is empty) → NOT a startup failure; we keep the entry with apiKey="" and
//     let the selector layer filter it out, logging a warn so operators notice.
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

  const secretName = String(entry.secretName || `PROVIDER_KEY_${id}`);
  if (!secretName) {
    throw new Error(`PROVIDERS[${index}] (id=${id}) secretName must be non-empty`);
  }

  const apiKey = String(env[secretName] || "");
  if (!apiKey) {
    onSecretMissing({ id, secretName });
  }

  return {
    id,
    type,
    url,
    model,
    secretName,
    apiKey,
    priority: Number.isFinite(entry.priority) ? Number(entry.priority) : DEFAULT_PRIORITY,
    weight: Number.isFinite(entry.weight) && entry.weight > 0 ? Number(entry.weight) : DEFAULT_WEIGHT,
    enabled: entry.enabled !== false,
    timeoutMs: Number.isFinite(entry.timeoutMs) && entry.timeoutMs > 0
      ? Math.min(Number(entry.timeoutMs), MAX_TIMEOUT_MS)
      : DEFAULT_PROVIDER_TIMEOUT_MS
  };
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
    return [{
      id: "OPENAI_LEGACY",
      type: "openai",
      url: LEGACY_OPENAI_URL,
      model,
      secretName: "OPENAI_API_KEY",
      apiKey,
      priority: 1,
      weight: 1,
      enabled: true,
      timeoutMs
    }];
  }

  const apiKey = String(env.ANTHROPIC_API_KEY || "");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is required when AI_PROVIDER=anthropic");
  }

  return [{
    id: "ANTHROPIC_LEGACY",
    type: "anthropic",
    url: LEGACY_ANTHROPIC_URL,
    model: env.ANTHROPIC_MODEL || LEGACY_ANTHROPIC_DEFAULT_MODEL,
    secretName: "ANTHROPIC_API_KEY",
    apiKey,
    priority: 1,
    weight: 1,
    enabled: true,
    timeoutMs
  }];
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
