# VoiceTodo AI Proxy

Cloudflare Worker proxy for VoiceTodo todo extraction.

The iOS app calls this Worker instead of calling OpenAI or Anthropic directly. AI provider keys live only in Cloudflare Secrets.

## Required secrets / vars

- `APP_TOKEN`: weak app token checked against `X-App-Token`
- `AI_PROVIDER`: `anthropic` or `openai` (defaults to `anthropic`)
- `ANTHROPIC_API_KEY`: required when `AI_PROVIDER=anthropic`
- `OPENAI_API_KEY`: required when `AI_PROVIDER=openai`
- `OPENAI_MODEL`: required when `AI_PROVIDER=openai`
- `DAILY_REQUEST_LIMIT`: optional per-device daily request cap
- `RATE_LIMIT_KV`: optional KV binding used by `DAILY_REQUEST_LIMIT`
- `ALLOW_UNAUTHENTICATED_PROXY`: set to `true` only for local throwaway testing without `APP_TOKEN`

## Local test

```bash
npm test
```

## Deploy outline

```bash
wrangler secret put APP_TOKEN
wrangler secret put ANTHROPIC_API_KEY
wrangler deploy worker.js
```

Configure the iOS app with:

- `VOICETODO_AI_PROXY_ENDPOINT=https://your-worker.workers.dev/v1/todo-extractions`
- `VOICETODO_AI_PROXY_APP_TOKEN=<same value as APP_TOKEN>`
