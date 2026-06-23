# VoiceTodo AI Proxy

Cloudflare Worker proxy for VoiceTodo todo extraction.

The iOS app calls this Worker instead of calling model providers directly. Provider keys live only in Cloudflare secrets, and the proxy transparently fails over across multiple providers based on health, latency, and priority.

## Single-provider (legacy, still supported)

Set flat env vars and the proxy will assemble a single-provider config internally:

- `APP_TOKEN`: weak app token checked against `X-App-Token`
- `AI_PROVIDER`: `anthropic` or `openai` (defaults to `anthropic`)
- `ANTHROPIC_API_KEY`: required when `AI_PROVIDER=anthropic`; `ANTHROPIC_MODEL` is optional and defaults to the built-in Anthropic model
- `OPENAI_API_KEY` / `OPENAI_MODEL`: required when `AI_PROVIDER=openai`
- `AI_PROVIDER_TIMEOUT_MS`: optional, clamped to 60s, default 20s
- `ALLOW_UNAUTHENTICATED_PROXY`: set to `true` only for local throwaway testing without `APP_TOKEN`

## Multi-provider (recommended)

Declare all providers via the `PROVIDERS` JSON var (non-sensitive fields only) and inject each key via `wrangler secret put`. See `wrangler.toml.example` for a fully-commented Anthropic + OpenAI + Gemini example.

```jsonc
[
  { "id": "ANTHROPIC_PRIMARY", "type": "anthropic", "url": "https://api.anthropic.com/v1/messages",           "model": "claude-sonnet-4-5-20250929", "priority": 1, "weight": 10, "secretName": "PROVIDER_KEY_ANTHROPIC_PRIMARY" },
  { "id": "OPENAI_FALLBACK",   "type": "openai",    "url": "https://api.openai.com/v1/chat/completions",      "model": "gpt-4o-mini",                "priority": 2, "weight": 5,  "secretName": "PROVIDER_KEY_OPENAI_FALLBACK" },
  { "id": "GEMINI_FALLBACK",   "type": "gemini",    "url": "https://generativelanguage.googleapis.com/v1beta/models", "model": "gemini-1.5-flash",   "priority": 3, "weight": 2,  "secretName": "PROVIDER_KEY_GEMINI_FALLBACK" }
]
```

Field reference:

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `^[A-Z0-9_]+$`. Used in logs, KV keys, and as default secret name. |
| `type` | yes | One of the registered adapters: `anthropic`, `openai`, `gemini`. |
| `url` | yes | `https://…`. For Gemini this is the base path without the model. |
| `model` | yes | Non-empty. |
| `priority` | no | Lower = preferred (default 100). |
| `weight` | no | Cold-start weighted random weight (default 1). When all weights are equal, selector falls back to priority order. |
| `enabled` | no | `false` filters the provider from candidates (default `true`). |
| `secretName` | no | Env var holding the key (default `PROVIDER_KEY_<id>`). Missing secret → warn + filter, not a startup failure. |
| `timeoutMs` | no | Per-call timeout, clamped to 60s (default 15s). |

Optional tuning:

- `AI_PROVIDER_MAX_ATTEMPTS`: cap on candidates tried per request. Defaults to the filtered candidate count.

## How selection works

For every incoming request the proxy builds an ordered candidate list:

1. **Filter**: drop providers that are disabled, missing a secret, or whose circuit is `open`.
2. **Sort**:
   - Providers with EWMA latency data → ascending by latency (fastest wins).
   - Providers without latency data (cold start) → weighted random when weights differ; priority order otherwise.
   - Half-open circuit providers → end of list (single-trial slot).
3. **Cap** at `AI_PROVIDER_MAX_ATTEMPTS`.

`executeWithFailover` walks the list, calling the provider's adapter. Network errors, timeouts, 5xx, 429, 408, and 401/403 trigger failover (circuit-breaker counts these). Generic 400/422 request-body errors do **not** failover — another provider would reject the same payload, so the proxy returns 502 immediately. 400/422 errors whose body mentions model/config issues (`model_not_found`, `context_length`, …) are treated as model-config problems and trigger failover.

Once a streaming response has returned its first byte to the client, failover can no longer happen — mid-stream errors propagate to the iOS client. This is documented behaviour; the SSE protocol guarantees the client can detect a truncated stream.

## Circuit breaker

Per-provider circuit state is persisted in `AI_PROVIDER_STATE_KV` (a dedicated KV namespace, kept separate from `RATE_LIMIT_KV`):

- 3 consecutive retryable failures → circuit opens for 30s.
- After 30s → half-open; one trial request is allowed.
- Trial success → close (failure count reset).
- Trial failure → re-open with doubled cooldown (60s → 120s → 240s → 300s, capped at 5 min).
- Non-retryable 4xx errors do **not** count toward the breaker.

If the KV namespace is absent or starts erroring, the proxy degrades to per-isolate in-memory state — failover still works within a single isolate, just not across them.

## Observability

All log lines are JSON. Key events:

- `proxy.provider.call_start` / `call_success` / `call_failed`
- `proxy.provider.failover` — emitted when moving to the next candidate
- `proxy.circuit.opened` / `reopened` / `closed`
- `proxy.provider.auth_failed_alert` — 401/403 from a provider (operator action needed)
- `proxy.request.finished` — includes `providersTried`, `providerUsed`, `failoverCount`, `candidateCount`, `providerAttempts[]`

Red lines enforced by the logger:

- **Never** logs the transcript, the API key, or the upstream URL (Gemini embeds the key as a query param — the URL is deliberately omitted from log payloads).
- **Always** logs provider ID, type, model, attempt index, duration, status, error type.

## Local test

```bash
npm test
```

Test coverage spans: legacy single-provider config, `PROVIDERS` parsing (structural + missing-secret cases), all three adapters' request/response/stream shapes, `isRetryable` classification (including 400/422 model_config vs request_body split), cold-start weighted sampling, latency-aware ordering, circuit-breaker transitions, KV-degraded mode, and end-to-end failover in both non-streaming and streaming modes.

## Deploy outline

```bash
wrangler secret put APP_TOKEN
wrangler secret put PROVIDER_KEY_ANTHROPIC_PRIMARY
wrangler secret put PROVIDER_KEY_OPENAI_FALLBACK
wrangler secret put PROVIDER_KEY_GEMINI_FALLBACK
wrangler deploy worker.js
```

Configure the iOS app with:

- `VOICETODO_AI_PROXY_ENDPOINT=https://your-worker.workers.dev/v1/todo-extractions`
- `VOICETODO_AI_PROXY_APP_TOKEN=<same value as APP_TOKEN>`

The iOS client is unchanged by the multi-provider refactor — request body, SSE protocol, and error codes are all preserved.
