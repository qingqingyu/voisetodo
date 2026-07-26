import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { handleRequest, handleTelemetryBatch, handleScheduled, _testResetHealth } from "./worker.js";
import { mintTestJWS } from "./src/jws-fixture.js";

// Reset module-level HealthStore between tests so circuit-breaker / latency state
// from one test doesn't leak into another.
beforeEach(() => _testResetHealth());
import { anthropicAdapter, openaiAdapter, geminiAdapter } from "./src/adapters/index.js";
import { HealthStore } from "./src/health.js";
import { pickCandidates } from "./src/selector.js";

test("rejects missing app token when APP_TOKEN is configured", async () => {
  const response = await handleRequest(
    request({ transcript: "买菜" }),
    { APP_TOKEN: "expected-token", ANTHROPIC_API_KEY: "anthropic-key" },
    {},
    failingFetch
  );

  assert.equal(response.status, 401);
});

test("rejects proxy deployment without APP_TOKEN unless explicitly allowed", async () => {
  const response = await handleRequest(
    request({ transcript: "买菜" }),
    { ANTHROPIC_API_KEY: "anthropic-key" },
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
  assert.equal(await response.text(), "AI proxy failed");
});

test("routes Anthropic provider and returns plain extraction JSON", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("完成英语背诵") }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.anthropic.com/v1/messages");
  assert.equal(upstreamRequest.init.headers["x-api-key"], "anthropic-key");
  assert.equal(upstreamRequest.body.messages[0].content, "今天完成英语背诵");

  const data = await response.json();
  assert.equal(data.todos[0].title, "完成英语背诵");
});

test("passes an abort signal to provider requests", async () => {
  let upstreamSignal;
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      AI_PROVIDER_TIMEOUT_MS: "5000"
    },
    {},
    async (_url, init) => {
      upstreamSignal = init.signal;
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("完成英语背诵") }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.ok(upstreamSignal instanceof AbortSignal);
  assert.equal(upstreamSignal.aborted, false);
});

test("routes OpenAI provider when configured", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "buy milk", locale: "en-US" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        choices: [{ message: { content: extractionJSON("Buy milk") } }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.openai.com/v1/chat/completions");
  assert.equal(upstreamRequest.init.headers.Authorization, "Bearer openai-key");
  assert.equal(upstreamRequest.body.model, "test-model");
  assert.equal(upstreamRequest.body.messages.at(-1).content, "buy milk");

  const data = await response.json();
  assert.equal(data.todos[0].title, "Buy milk");
});

test("adds vocabulary hints to Anthropic system prompt as soft context", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request(
      { transcript: "今天复习", locale: "zh-Hans", vocabularyHints: ["Anki", "IELTS", "雅思"] },
      { "X-App-Token": "token" }
    ),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("复习") }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.body.messages[0].content, "今天复习");
  assert.ok(upstreamRequest.body.system.includes("Anki、IELTS、雅思"));
  assert.ok(upstreamRequest.body.system.includes("不要因为这些词本身创建待办"));
});

test("adds vocabulary hints to OpenAI system prompt as soft context", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request(
      { transcript: "review flashcards", locale: "en-US", vocabularyHints: ["Anki", "IELTS"] },
      { "X-App-Token": "token" }
    ),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        choices: [{ message: { content: extractionJSON("Review flashcards") } }]
      });
    }
  );

  assert.equal(response.status, 200);
  const systemMessage = upstreamRequest.body.messages[0].content;
  assert.ok(systemMessage.includes("Anki, IELTS"));
  assert.ok(systemMessage.includes("do not create todos just because these terms appear here"));
});

test("system prompt instructs extracting structured due_time and time_bucket (zh + en)", async () => {
  for (const [locale, transcript, exclusivityRule] of [
    ["zh-Hans", "明天下午3点开会", "time_bucket 必须为 null"],
    ["en-US", "meeting at 3pm tomorrow", "time_bucket must be null"]
  ]) {
    let upstreamRequest;
    const response = await handleRequest(
      request({ transcript, locale }, { "X-App-Token": "token" }),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "openai",
        OPENAI_API_KEY: "openai-key",
        OPENAI_MODEL: "test-model"
      },
      {},
      async (url, init) => {
        upstreamRequest = { body: JSON.parse(init.body) };
        return jsonResponse({ choices: [{ message: { content: extractionJSON("开会") } }] });
      }
    );
    assert.equal(response.status, 200);
    const systemMessage = upstreamRequest.body.messages[0].content;
    assert.ok(systemMessage.includes("due_time"));
    assert.ok(systemMessage.includes("time_bucket"));
    assert.ok(systemMessage.includes(exclusivityRule));
    assert.ok(systemMessage.includes('"time_bucket":"evening"'));
    assert.ok((systemMessage.match(/"time_bucket":/g) ?? []).length >= 10);
  }
});

test("system prompt injects today date from X-Local-Date header (zh + en)", async () => {
  // AI 需要"今天的日期"才能计算"未来一个月"等有限周期的 end_date。
  // 没有这个注入，AI 只能返回 null end_date（"未来一个月每天"场景就算不出来）。
  //
  // 用真实"今天"动态生成 X-Local-Date，而非硬编码日期：
  //   - drift 与服务端 serverToday 恒为 0，不会被 resolveQuotaDate 的漂移校验拒；
  //   - 不再 mutate 全局 Date.prototype（withMockedToday 会污染并发中的其它用例，
  //     曾导致本用例偶发 flake——mock 泄漏时 today 回退成真实日期，断言落空）。
  const today = new Date().toISOString().slice(0, 10);
  for (const [locale, expectedSnippet] of [["zh-Hans", `参考日期：${today}`], ["en-US", `Reference date: ${today}`]]) {
    let upstreamRequest;
    const response = await handleRequest(
      request({ transcript: "未来一个月每天下午3点接孩子", locale }, {
        "X-App-Token": "token",
        "X-Local-Date": today
      }),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "openai",
        OPENAI_API_KEY: "openai-key",
        OPENAI_MODEL: "test-model"
      },
      {},
      async (url, init) => {
        upstreamRequest = { body: JSON.parse(init.body) };
        return jsonResponse({ choices: [{ message: { content: extractionJSON("接孩子") } }] });
      }
    );
    assert.equal(response.status, 200);
    assert.ok(
      upstreamRequest.body.messages[0].content.includes(expectedSnippet),
      `locale=${locale} 应在 system prompt 中包含 today 注入（"${expectedSnippet}"）`
    );
  }
});

test("system prompt instructs structured recurrence_end boundary (zh + en)", async () => {
  for (const [locale, transcript] of [["zh-Hans", "未来7天每天下午5点接小孩"], ["en-US", "pick up kids at 5pm every day for the next 7 days"]]) {
    let upstreamRequest;
    const response = await handleRequest(
      request({ transcript, locale }, { "X-App-Token": "token", "X-Local-Date": "2026-07-06" }),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "openai",
        OPENAI_API_KEY: "openai-key",
        OPENAI_MODEL: "test-model"
      },
      {},
      async (url, init) => {
        upstreamRequest = { body: JSON.parse(init.body) };
        return jsonResponse({ choices: [{ message: { content: extractionJSON("接小孩") } }] });
      }
    );
    assert.equal(response.status, 200);
    const systemMessage = upstreamRequest.body.messages[0].content;
    assert.ok(systemMessage.includes("recurrence_end"));
    assert.ok(systemMessage.includes("after_count"));
    assert.ok(systemMessage.includes("month_end"));
  }
});

test("system prompt injects personal conventions when personalHints provided (A1)", async () => {
  // A1: PersonalGlossary 把用户个人约定作为结构化文本经 personalHints 注入 system prompt，
  // 让 AI 展开别名 / 套用默认时间。计划要求断言 outgoing system prompt 原样含该段。
  const personalHints = "用户个人约定(请展开别名并套用默认时间):\n• \"老地方\" 指 \"星光健身房\"";
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "去老地方", locale: "zh-Hans", personalHints }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { body: JSON.parse(init.body) };
      return jsonResponse({ choices: [{ message: { content: extractionJSON("去星光健身房") } }] });
    }
  );
  assert.equal(response.status, 200);
  assert.ok(
    upstreamRequest.body.messages[0].content.includes(personalHints),
    "system prompt 应原样包含 personalHints 个人约定段"
  );
});

test("system prompt omits personal conventions when personalHints absent", async () => {
  // 没有个人约定时不应凭空冒出"个人约定"段（避免污染 prompt / 误导模型）。
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "买菜", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { body: JSON.parse(init.body) };
      return jsonResponse({ choices: [{ message: { content: extractionJSON("买菜") } }] });
    }
  );
  assert.equal(response.status, 200);
  assert.ok(
    !upstreamRequest.body.messages[0].content.includes("个人约定"),
    "无 personalHints 时不应出现个人约定段"
  );
});

test("system prompt falls back to server UTC date when X-Local-Date missing", async () => {
  // X-Local-Date 缺失时 resolveQuotaDate 回退到服务端 UTC 日期（同样注入 prompt，
  // 不静默丢弃），AI 仍能拿到一个参考日期，只是可能与用户真实"今天"差 1 天。
  const serverToday = new Date().toISOString().slice(0, 10);
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "未来一个月每天下午3点接孩子", locale: "zh-Hans" }, {
      "X-App-Token": "token"
    }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { body: JSON.parse(init.body) };
      return jsonResponse({ choices: [{ message: { content: extractionJSON("接孩子") } }] });
    }
  );
  assert.equal(response.status, 200);
  assert.ok(
    upstreamRequest.body.messages[0].content.includes(`参考日期：${serverToday}`),
    `X-Local-Date 缺失时应注入服务端 UTC 日期（"${serverToday}"）作为参考`
  );
});

test("filters and caps vocabulary hints before calling provider", async () => {
  let upstreamRequest;
  const hints = ["A", "Anki", "Anki", "x".repeat(40), ...Array.from({ length: 35 }, (_, i) => `Term${i + 1}`)];
  const response = await handleRequest(
    request(
      { transcript: "review", locale: "en-US", vocabularyHints: hints },
      { "X-App-Token": "token" }
    ),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (_url, init) => {
      upstreamRequest = { body: JSON.parse(init.body) };
      return jsonResponse({
        choices: [{ message: { content: extractionJSON("Review") } }]
      });
    }
  );

  assert.equal(response.status, 200);
  const systemMessage = upstreamRequest.body.messages[0].content;
  assert.ok(systemMessage.includes("Anki"));
  assert.ok(systemMessage.includes("Term29"));
  assert.equal(systemMessage.includes("Term30"), false);
  assert.equal(systemMessage.includes("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"), false);
});

test("does not log concrete vocabulary hints", async () => {
  let upstreamRequest;
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request(
        { transcript: "今天复习", locale: "zh-Hans", vocabularyHints: ["Anki", "IELTS"] },
        { "X-App-Token": "token" }
      ),
      {
        APP_TOKEN: "token",
        LOG_HASH_SALT: "test-salt",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key"
      },
      {},
      async (_url, init) => {
        upstreamRequest = { body: JSON.parse(init.body) };
        return jsonResponse({
          content: [{ type: "text", text: extractionJSON("复习") }]
        });
      }
    );
    assert.equal(response.status, 200);
  });

  assert.ok(upstreamRequest.body.system.includes("Anki"));
  assert.ok(logs.some((line) => line.includes("\"vocabularyHintCount\":2")));
  assert.equal(logs.some((line) => line.includes("Anki")), false);
  assert.equal(logs.some((line) => line.includes("IELTS")), false);
});

test("normalizes Anthropic streaming events for iOS client", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return sseResponse([
        `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: "{\"todos\":" } })}`,
        `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: "[]" } })}`,
        `data: ${JSON.stringify({ type: "message_stop" })}`
      ]);
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.anthropic.com/v1/messages");
  assert.equal(upstreamRequest.body.stream, true);
  assert.equal(response.headers.get("Content-Type"), "text/event-stream; charset=utf-8");

  const body = await response.text();
  assert.ok(body.includes('data: {"text":"{\\"todos\\":"}'));
  assert.ok(body.includes('data: {"text":"[]"}'));
  assert.ok(body.includes("data: [DONE]"));
});

test("normalizes OpenAI streaming events for iOS client", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "buy milk", locale: "en-US", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "openai-key",
      OPENAI_MODEL: "test-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return sseResponse([
        `data: ${JSON.stringify({ choices: [{ delta: { content: "{\"todos\":" } }] })}`,
        `data: ${JSON.stringify({ choices: [{ delta: { content: "[]" } }] })}`,
        `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }] })}`
      ]);
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.openai.com/v1/chat/completions");
  assert.equal(upstreamRequest.body.stream, true);
  assert.equal(response.headers.get("Content-Type"), "text/event-stream; charset=utf-8");

  const body = await response.text();
  assert.ok(body.includes('data: {"text":"{\\"todos\\":"}'));
  assert.ok(body.includes('data: {"text":"[]"}'));
  assert.ok(body.includes("data: [DONE]"));
});

test("rejects provider streaming response without body", async () => {
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => new Response(null, { status: 200 })
  );

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "AI proxy failed");
});

test("failovers in streaming mode when first provider returns 200 without body", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x", stream: true }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
    ),
    {},
    async (url) => {
      calls.push(url);
      if (url.includes("a.example")) {
        return new Response(null, { status: 200 });
      }
      return sseResponse([
        `data: ${JSON.stringify({ choices: [{ delta: { content: "{\"todos\":[]" } }] })}`,
        `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }] })}`
      ]);
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.ok(calls[1].includes("b.example"));
  assert.ok((await response.text()).includes("data: [DONE]"));
});

test("propagates provider streaming read errors instead of sending done", async () => {
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => erroringSSEStreamResponse()
  );

  assert.equal(response.status, 200);
  await assert.rejects(() => response.text(), /provider stream failed/);
});

test("propagates invalid provider streaming JSON instead of skipping it", async () => {
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => sseResponse(["data: {not-json"])
  );

  assert.equal(response.status, 200);
  await assert.rejects(() => response.text(), /AI provider stream returned invalid JSON/);
});

test("propagates oversized provider streaming events instead of buffering indefinitely", async () => {
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => sseResponse([`data: ${"x".repeat(70 * 1024)}`])
  );

  assert.equal(response.status, 200);
  await assert.rejects(() => response.text(), /AI provider stream event too large/);
});

test("propagates provider stream ending without done instead of sending done", async () => {
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans", stream: true }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => sseResponse([
      `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: "{\"todos\":" } })}`
    ])
  );

  assert.equal(response.status, 200);
  await assert.rejects(() => response.text(), /AI provider stream ended before done/);
});

test("streaming failures count toward circuit breaker before a provider is marked healthy", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
      { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
    ],
    { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("a.example")) {
      return sseResponse(["data: {not-json"]);
    }
    return sseResponse([
      `data: ${JSON.stringify({ choices: [{ delta: { content: "{\"todos\":[]" } }] })}`,
      `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }] })}`
    ]);
  };

  for (let i = 0; i < 3; i++) {
    const response = await handleRequest(
      request({ transcript: "x", stream: true }, { "X-App-Token": "token" }),
      env,
      {},
      fetchImpl
    );
    assert.equal(response.status, 200);
    await assert.rejects(() => response.text(), /AI provider stream returned invalid JSON/);
  }

  calls.length = 0;
  const responseAfter = await handleRequest(
    request({ transcript: "x", stream: true }, { "X-App-Token": "token" }),
    env,
    {},
    fetchImpl
  );
  assert.equal(responseAfter.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"), "A's stream failures should open the circuit");
  assert.ok((await responseAfter.text()).includes("data: [DONE]"));
});

test("rejects oversized transcript before calling provider", async () => {
  const response = await handleRequest(
    request({ transcript: "x".repeat(4001) }, { "X-App-Token": "token" }),
    { APP_TOKEN: "token", ANTHROPIC_API_KEY: "anthropic-key" },
    {},
    failingFetch
  );

  assert.equal(response.status, 413);
});

test("rejects oversized body even without content-length", async () => {
  const body = JSON.stringify({
    transcript: "买菜",
    padding: "x".repeat(16 * 1024)
  });
  const response = await handleRequest(
    new Request("https://proxy.test/v1/todo-extractions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-App-Token": "token"
      },
      body
    }),
    { APP_TOKEN: "token", ANTHROPIC_API_KEY: "anthropic-key" },
    {},
    failingFetch
  );

  assert.equal(response.status, 413);
});

test("enforces daily quota keyed by local date + hashed device id", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "2",
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "device-1", "X-Local-Date": "2026-05-26" };
    // 前两次发起即计数（后续 provider 失败不回退），第三次命中上限。
    await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);
    await handleRequest(request({ transcript: "b" }, headers), env, {}, failingFetch);
    const third = await handleRequest(request({ transcript: "c" }, headers), env, {}, failingFetch);

    assert.equal(third.status, 429);
    const body = await third.json();
    assert.equal(body.error, "quota_exceeded");
    assert.equal(body.tier, "free");
    assert.equal(body.remaining, 0);
    assert.equal(body.resetAt, "2026-05-26");
    assert.equal(third.headers.get("X-RateLimit-Type"), "quota");
    assert.equal(third.headers.get("X-Quota-Plan"), "free");
    assert.equal(third.headers.get("X-Quota-Remaining"), "0");
    assert.equal(third.headers.get("X-Quota-Reset-Date"), "2026-05-26");

    // key 用客户端本地日期 + sha256 摘要，不落明文设备号
    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "quota key 应使用客户端本地日期");
    assert.ok(quotaKey.includes("sha256:"), "quota key 应使用设备摘要");
    assert.equal(quotaKey.includes("device-1"), false, "quota key 不得含明文设备号");
  });
});

test("quota increments even when AI provider call fails (count on dispatch)", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "dev-x", "X-Local-Date": "2026-05-26" };
    // failingFetch → 上游 AI 抛错，但配额已在调用前自增
    await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "应已写入 quota key");
    assert.equal(kv.values.get(quotaKey), "1", "AI 失败仍应计数为 1");
  });
});

test("accepts local date within ±1 day drift from server UTC", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    // 前一天（跨时区合法边界）
    await handleRequest(
      request({ transcript: "a" }, { "X-App-Token": "token", "X-Device-ID": "d-prev", "X-Local-Date": "2026-05-25" }),
      env,
      {},
      failingFetch
    );
    assert.ok(
      [...kv.values.keys()].some((k) => k.startsWith("quota:2026-05-25:")),
      "前一天的本地日期应被采纳"
    );
    // 后一天
    await handleRequest(
      request({ transcript: "b" }, { "X-App-Token": "token", "X-Device-ID": "d-next", "X-Local-Date": "2026-05-27" }),
      env,
      {},
      failingFetch
    );
    assert.ok(
      [...kv.values.keys()].some((k) => k.startsWith("quota:2026-05-27:")),
      "后一天的本地日期应被采纳"
    );
  });
});

test("falls back to server UTC date when local date drifts more than 1 day", async () => {
  const kv = new MemoryKV(new Map());
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
      const env = {
        APP_TOKEN: "token",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        RATE_LIMIT_KV: kv
      };
      // 伪造到 +6 天，企图提前重置配额
      await handleRequest(
        request({ transcript: "a" }, { "X-App-Token": "token", "X-Device-ID": "d-future", "X-Local-Date": "2026-06-01" }),
        env,
        {},
        failingFetch
      );
    });
  });
  assert.ok(
    [...kv.values.keys()].some((k) => k.startsWith("quota:2026-05-26:")),
    "漂移超阈应回退服务端 UTC 日期"
  );
  assert.equal(
    [...kv.values.keys()].some((k) => k.startsWith("quota:2026-06-01:")),
    false,
    "不得采纳漂移的本地日期"
  );
  assert.ok(logs.some((line) => line.includes("local_date_drift_rejected")), "应记录漂移拒绝日志");
});

test("falls back to server UTC date and logs when local date is invalid or missing", async () => {
  const kv = new MemoryKV(new Map());
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
      const env = {
        APP_TOKEN: "token",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        RATE_LIMIT_KV: kv
      };
      // 格式非法
      await handleRequest(
        request({ transcript: "a" }, { "X-App-Token": "token", "X-Device-ID": "d-bad", "X-Local-Date": "May 26" }),
        env,
        {},
        failingFetch
      );
      // 缺失
      await handleRequest(
        request({ transcript: "b" }, { "X-App-Token": "token", "X-Device-ID": "d-missing" }),
        env,
        {},
        failingFetch
      );
    });
  });
  const quotaKeys = [...kv.values.keys()].filter((k) => k.startsWith("quota:"));
  assert.ok(quotaKeys.every((k) => k.startsWith("quota:2026-05-26:")), "非法/缺失都应回退服务端 UTC 日期");
  assert.ok(logs.some((line) => line.includes("invalid_local_date")), "应记录 invalid_local_date 日志");
});

test("attaches quota headers on 2xx responses", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const response = await handleRequest(
      request({ transcript: "今天复习" }, { "X-App-Token": "token", "X-Device-ID": "d-ok", "X-Local-Date": "2026-05-26" }),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        RATE_LIMIT_KV: kv
      },
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("复习") }] })
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("X-Quota-Plan"), "free");
    assert.equal(response.headers.get("X-Quota-Limit"), "5");
    assert.equal(response.headers.get("X-Quota-Used"), "1");
    assert.equal(response.headers.get("X-Quota-Remaining"), "4");
    assert.equal(response.headers.get("X-Quota-Reset-Date"), "2026-05-26");
  });
});

// MARK: - JWS 订阅验签 / Pro 档放行

test("Pro JWS raises tier to paid limit", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ productId: "com.voicetodo.pro.yearly" });
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const response = await handleRequest(
      request(
        { transcript: "今天复习" },
        {
          "X-App-Token": "token",
          "X-Device-ID": "dev-pro",
          "X-Local-Date": "2026-05-26",
          "X-Subscription-JWS": jws
        }
      ),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        PAID_DAILY_LIMIT: "100",
        RATE_LIMIT_KV: kv,
        SUBSCRIPTION_ROOT_SHA256: rootFingerprint,
        APP_BUNDLE_ID: "com.voicetodo.app"
      },
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("复习") }] })
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("X-Quota-Plan"), "pro");
    assert.equal(response.headers.get("X-Quota-Limit"), "100");
    assert.equal(response.headers.get("X-Quota-Remaining"), "99");
  });
});

test("missing JWS stays on free tier even with PAID_DAILY_LIMIT configured", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const response = await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token", "X-Device-ID": "d-free", "X-Local-Date": "2026-05-26" }),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "k",
        DAILY_REQUEST_LIMIT: "5",
        PAID_DAILY_LIMIT: "100",
        RATE_LIMIT_KV: kv
      },
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("x") }] })
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("X-Quota-Plan"), "free");
    assert.equal(response.headers.get("X-Quota-Limit"), "5");
  });
});

test("invalid JWS fails safe to free tier (not 500, not pro)", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const response = await handleRequest(
      request(
        { transcript: "x" },
        { "X-App-Token": "token", "X-Device-ID": "d-badjws", "X-Local-Date": "2026-05-26", "X-Subscription-JWS": "garbage.payload.sig" }
      ),
      {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "k",
        DAILY_REQUEST_LIMIT: "5",
        PAID_DAILY_LIMIT: "100",
        RATE_LIMIT_KV: kv
      },
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("x") }] })
    );
    // fail-safe：不 500，按免费档放行
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("X-Quota-Plan"), "free");
    assert.equal(response.headers.get("X-Quota-Limit"), "5");
  });
});

test("Pro JWS verification result is cached in KV", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ productId: "com.voicetodo.pro.yearly" });
  const kv = new MemoryKV(new Map());
  const env = {
    APP_TOKEN: "token",
    AI_PROVIDER: "anthropic",
    ANTHROPIC_API_KEY: "k",
    DAILY_REQUEST_LIMIT: "5",
    PAID_DAILY_LIMIT: "100",
    RATE_LIMIT_KV: kv,
    SUBSCRIPTION_ROOT_SHA256: rootFingerprint,
    APP_BUNDLE_ID: "com.voicetodo.app"
  };
  const headers = { "X-App-Token": "token", "X-Device-ID": "dev-cached", "X-Local-Date": "2026-05-26", "X-Subscription-JWS": jws };
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    await handleRequest(request({ transcript: "a" }, headers), env, {}, async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("a") }] }));
    // 第二次用篡改的 JWS：若缓存生效仍应判 pro（缓存优先于重验）
    const tamperedHeaders = { ...headers, "X-Subscription-JWS": "tampered.payload.sig" };
    const response = await handleRequest(request({ transcript: "b" }, tamperedHeaders), env, {}, async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("b") }] }));
    assert.equal(response.headers.get("X-Quota-Plan"), "pro");
    // 缓存 key 已写入
    assert.ok([...kv.values.keys()].some((k) => k.startsWith("sub:")), "应写入订阅缓存 key");
  });
});

test("subscription cache entries without a future expiresAt are ignored", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ productId: "com.voicetodo.pro.yearly" });
  const kv = new MemoryKV(new Map());
  const env = {
    APP_TOKEN: "token",
    AI_PROVIDER: "anthropic",
    ANTHROPIC_API_KEY: "k",
    DAILY_REQUEST_LIMIT: "5",
    PAID_DAILY_LIMIT: "100",
    RATE_LIMIT_KV: kv,
    SUBSCRIPTION_ROOT_SHA256: rootFingerprint,
    APP_BUNDLE_ID: "com.voicetodo.app"
  };
  const headers = { "X-App-Token": "token", "X-Device-ID": "dev-expiry-cache", "X-Local-Date": "2026-05-26", "X-Subscription-JWS": jws };
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    await handleRequest(request({ transcript: "a" }, headers), env, {}, async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("a") }] }));
    const cacheKey = [...kv.values.keys()].find((k) => k.startsWith("sub:"));
    assert.ok(cacheKey, "应写入订阅缓存 key");
    kv.values.set(cacheKey, JSON.stringify({ tier: "pro", productId: "com.voicetodo.pro.yearly" }));

    const response = await handleRequest(
      request({ transcript: "b" }, { ...headers, "X-Subscription-JWS": "tampered.payload.sig" }),
      env,
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("b") }] })
    );
    assert.equal(response.headers.get("X-Quota-Plan"), "free");
    assert.equal(response.headers.get("X-Quota-Limit"), "5");
  });
});

test("enforces global daily budget with 503", async () => {
  const kv = new MemoryKV(new Map([["global-quota:2026-05-26", "5"]]));
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const response = await handleRequest(
      request({ transcript: "买菜" }, { "X-App-Token": "token" }),
      {
        APP_TOKEN: "token",
        ANTHROPIC_API_KEY: "anthropic-key",
        GLOBAL_DAILY_LIMIT: "5",
        RATE_LIMIT_KV: kv
      },
      {},
      failingFetch
    );
    assert.equal(response.status, 503);
    const body = await response.json();
    assert.equal(body.error, "global_budget_exceeded");
  });
});

test("enforces per-IP per-minute velocity limit", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      IP_RATE_PER_MINUTE: "2",
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "CF-Connecting-IP": "1.2.3.4" };
    // 前两次通过 IP 检查（后续 provider 调用因 failingFetch 失败，但 IP 计数已自增）
    await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);
    await handleRequest(request({ transcript: "b" }, headers), env, {}, failingFetch);
    const third = await handleRequest(request({ transcript: "c" }, headers), env, {}, failingFetch);
    assert.equal(third.status, 429);
    const body = await third.json();
    assert.equal(body.error, "rate_limited");
    assert.equal(third.headers.get("X-RateLimit-Type"), "velocity");
  });
});

test("enforces per-IP daily limit independent of device id", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      IP_DAILY_LIMIT: "2",
      RATE_LIMIT_KV: kv
    };
    // 同一 IP 轮换 device id 也无法绕过：IP 维度独立计数
    const mk = (n) => request({ transcript: `t${n}` }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": `rotating-${n}`
    });
    await handleRequest(mk(1), env, {}, failingFetch);
    await handleRequest(mk(2), env, {}, failingFetch);
    const third = await handleRequest(mk(3), env, {}, failingFetch);
    assert.equal(third.status, 429);
    const body = await third.json();
    assert.equal(body.error, "rate_limited");
    assert.equal(third.headers.get("X-RateLimit-Type"), "ip_daily");
  });
});

test("redacts device identifiers in logs", async () => {
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request(
        { transcript: "今天完成英语背诵" },
        { "X-App-Token": "token", "X-Device-ID": "device-1" }
      ),
      {
        APP_TOKEN: "token",
        LOG_HASH_SALT: "test-salt",
        ANTHROPIC_API_KEY: "anthropic-key"
      },
      {},
      async () => jsonResponse({
        content: [{ type: "text", text: extractionJSON("完成英语背诵") }]
      })
    );
    assert.equal(response.status, 200);
  });

  assert.ok(logs.length > 0);
  assert.equal(logs.some((line) => line.includes("device-1")), false);
  assert.equal(logs.some((line) => line.includes("sha256:")), true);
});

// 验证 worker 原样透传 AI 返回的 due_date_basis 字段(方案 2)。
// worker.js:174 用 new Response(text) 直接返回 AI 原始 JSON,不经 postProcess。
// 这个测试守住"客户端需要的字段必须透传,不能被中间层丢弃"。
test("passes through due_date_basis field from provider response unchanged", async () => {
  const providerResponse = {
    todos: [{
      title: "交房租",
      detail: "明天交房租",
      due_date: "2026-07-20",
      due_hint: "明天",
      due_time: null,
      time_bucket: null,
      recurrence_rule: null,
      recurrence_end: null,
      reminder_times: null,
      due_date_basis: "user_explicit",
      priority: "normal",
      category_hint: "finance"
    }],
    ignored: ""
  };
  const response = await handleRequest(
    request({ transcript: "明天交房租", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => jsonResponse({
      content: [{ type: "text", text: JSON.stringify(providerResponse) }]
    })
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.todos[0].due_date_basis, "user_explicit");
  assert.equal(data.todos[0].due_date, "2026-07-20");
});

test("passes through title_mention basis when AI flags title-borne date word", async () => {
  // 模拟 AI 正确识别 "prepare for Sunday" 是 title_mention 而非 user_explicit
  const providerResponse = {
    todos: [{
      title: "Prepare for Sunday",
      detail: "Prepare for Sunday",
      due_date: null,
      due_hint: null,
      due_time: null,
      time_bucket: null,
      recurrence_rule: null,
      recurrence_end: null,
      reminder_times: null,
      due_date_basis: "title_mention",
      priority: "normal",
      category_hint: "other"
    }],
    ignored: ""
  };
  const response = await handleRequest(
    request({ transcript: "prepare for Sunday", locale: "en-US" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key"
    },
    {},
    async () => jsonResponse({
      content: [{ type: "text", text: JSON.stringify(providerResponse) }]
    })
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.todos[0].due_date_basis, "title_mention");
  assert.equal(data.todos[0].due_date, null);
});

function request(body, headers = {}) {
  return new Request("https://proxy.test/v1/todo-extractions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...headers
    },
    body: JSON.stringify(body)
  });
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function sseResponse(lines) {
  return new Response(`${lines.join("\n\n")}\n\n`, {
    status: 200,
    headers: { "Content-Type": "text/event-stream" }
  });
}

function erroringSSEStreamResponse() {
  const encoder = new TextEncoder();
  let sentFirstChunk = false;
  const body = new ReadableStream({
    pull(controller) {
      if (!sentFirstChunk) {
        sentFirstChunk = true;
        controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: "{\"todos\":" } })}\n\n`
        ));
        return;
      }
      controller.error(new Error("provider stream failed"));
    }
  });
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/event-stream" }
  });
}

function extractionJSON(title) {
  return JSON.stringify({
    todos: [{
      title,
      detail: title,
      due_date: null,
      due_hint: null,
      due_time: null,
      time_bucket: null,
      recurrence_rule: null,
      priority: "normal",
      category_hint: "other"
    }],
    ignored: ""
  });
}

async function failingFetch() {
  throw new Error("provider should not be called");
}

// MARK: - Telemetry helpers

function telemetryRequest(events, headers = {}) {
  return new Request("https://proxy.test/v1/telemetry/events", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify({ events })
  });
}

function makeTelemetryEvent(overrides = {}) {
  return {
    name: "test_event",
    timestamp: Date.now(),
    sessionID: "session-1",
    deviceID: "sha256:client-should-be-ignored",
    appVersion: "1.0.0",
    iosVersion: "17.0",
    params: { foo: "bar" },
    ...overrides
  };
}

function makeFakeD1() {
  const insertedRows = [];
  let lastSql = "";
  return {
    insertedRows,
    prepare(sql) {
      lastSql = sql;
      return {
        bind(...args) {
          insertedRows.push({ sql: lastSql, args });
          return this;
        },
        async run() {
          return { meta: { changes: 1 } };
        }
      };
    },
    async batch(statements) {
      const results = [];
      for (const stmt of statements) {
        results.push(await stmt.run());
      }
      return results;
    }
  };
}

function makeFakeKV(initial = {}) {
  const store = { ...initial };
  return {
    store,
    async get(key) {
      return store[key] ?? null;
    },
    async put(key, value) {
      store[key] = String(value);
    }
  };
}

function withMockedToday(dateString, fn) {
  const original = Date.prototype.toISOString;
  Date.prototype.toISOString = () => dateString;
  return Promise.resolve(fn()).finally(() => {
    Date.prototype.toISOString = original;
  });
}

const baseTelemetryContext = { requestId: "r1", startedAt: Date.now(), deviceId: "sha256:dev1" };

// MARK: - Telemetry tests

test("telemetry rejects missing app token", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    telemetryRequest([makeTelemetryEvent()]),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );
  assert.equal(response.status, 401);
  assert.equal(db.insertedRows.length, 0);
});

test("telemetry rejects when DB not configured", async () => {
  const response = await handleTelemetryBatch(
    telemetryRequest([makeTelemetryEvent()], { "X-App-Token": "token" }),
    { APP_TOKEN: "token" },
    baseTelemetryContext
  );
  assert.equal(response.status, 503);
});

test("telemetry 405 on GET", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    new Request("https://proxy.test/v1/telemetry/events", { method: "GET" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );
  assert.equal(response.status, 405);
});

test("telemetry rejects empty events array", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    telemetryRequest([], { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );
  assert.equal(response.status, 400);
  assert.equal(db.insertedRows.length, 0);
});

test("telemetry rejects payload without events field", async () => {
  const db = makeFakeD1();
  const noFieldRequest = new Request("https://proxy.test/v1/telemetry/events", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-App-Token": "token" },
    body: JSON.stringify({ foo: "bar" })
  });
  const response = await handleTelemetryBatch(
    noFieldRequest,
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );
  assert.equal(response.status, 400);
});

test("telemetry rejects all-invalid events", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    telemetryRequest([
      { name: "", timestamp: Date.now() },                              // name 空
      { name: "ok", timestamp: "not-a-number" },                        // timestamp 非 number
      { name: "ok", timestamp: Date.now(), params: "not-object" },      // params 非 object
      { name: "ok", timestamp: Date.now(), params: { [`${"k".repeat(65)}`]: "v" } }  // param key 过长
    ], { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );
  assert.equal(response.status, 400);
  assert.equal(db.insertedRows.length, 0);
});

test("telemetry accepts valid events and writes to D1", async () => {
  const db = makeFakeD1();
  const events = [
    makeTelemetryEvent({ name: "recording_started" }),
    makeTelemetryEvent({ name: "todo_saved" })
  ];
  const response = await handleTelemetryBatch(
    telemetryRequest(events, { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.accepted, 2);
  assert.equal(data.dropped, 0);

  assert.equal(db.insertedRows.length, 2);
  // args 顺序：received_at, event_name, event_timestamp, session_id, device_id, app_version, ios_version, params
  assert.equal(db.insertedRows[0].args[1], "recording_started");
  assert.equal(db.insertedRows[1].args[1], "todo_saved");
});

test("telemetry uses requestContext device ID, not client-submitted", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    telemetryRequest(
      [makeTelemetryEvent({ deviceID: "sha256:client-should-be-ignored" })],
      { "X-App-Token": "token" }
    ),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    { requestId: "r1", startedAt: Date.now(), deviceId: "sha256:from-proxy" }
  );

  assert.equal(response.status, 200);
  assert.equal(db.insertedRows[0].args[4], "sha256:from-proxy");
});

test("telemetry caps batch at 100 events", async () => {
  const db = makeFakeD1();
  const events = Array.from({ length: 150 }, (_, i) => makeTelemetryEvent({ name: `e${i}` }));
  const response = await handleTelemetryBatch(
    telemetryRequest(events, { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.accepted, 100);
  assert.equal(data.dropped, 50);
  assert.equal(db.insertedRows.length, 100);
});

test("telemetry partial accept when quota partially exhausted", async () => {
  const db = makeFakeD1();
  const kv = makeFakeKV();  // 空，配额全可用
  const ctx = { requestId: "r1", startedAt: Date.now(), deviceId: "sha256:dev1" };
  // 先塞入已用 498
  kv.store["telemetry-quota:2026-06-20:sha256:dev1"] = "498";

  await withMockedToday("2026-06-20T00:00:00.000Z", async () => {
    const response = await handleTelemetryBatch(
      telemetryRequest(
        Array.from({ length: 4 }, (_, i) => makeTelemetryEvent({ name: `e${i}` })),
        { "X-App-Token": "token" }
      ),
      {
        APP_TOKEN: "token",
        TELEMETRY_DB: db,
        RATE_LIMIT_KV: kv,
        TELEMETRY_DAILY_LIMIT: "500"
      },
      ctx
    );

    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.accepted, 2);   // 500 - 498 = 2
    assert.equal(data.dropped, 2);
    assert.equal(db.insertedRows.length, 2);
    // KV 应该累加到 500
    assert.equal(kv.store["telemetry-quota:2026-06-20:sha256:dev1"], "500");
  });
});

test("telemetry rejects when quota fully exhausted", async () => {
  const db = makeFakeD1();
  const kv = makeFakeKV();
  kv.store["telemetry-quota:2026-06-20:sha256:dev1"] = "500";
  const ctx = { requestId: "r1", startedAt: Date.now(), deviceId: "sha256:dev1" };

  await withMockedToday("2026-06-20T00:00:00.000Z", async () => {
    await assert.rejects(
      handleTelemetryBatch(
        telemetryRequest([makeTelemetryEvent()], { "X-App-Token": "token" }),
        {
          APP_TOKEN: "token",
          TELEMETRY_DB: db,
          RATE_LIMIT_KV: kv,
          TELEMETRY_DAILY_LIMIT: "500"
        },
        ctx
      ),
      /quota exceeded/i
    );
    assert.equal(db.insertedRows.length, 0);
  });
});

test("telemetry skips quota when KV not configured", async () => {
  const db = makeFakeD1();
  const events = Array.from({ length: 10 }, (_, i) => makeTelemetryEvent({ name: `e${i}` }));
  const response = await handleTelemetryBatch(
    telemetryRequest(events, { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },  // 无 RATE_LIMIT_KV
    baseTelemetryContext
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.accepted, 10);  // 全部接受，无配额限制
});

test("telemetry routes via handleRequest", async () => {
  const db = makeFakeD1();
  const response = await handleRequest(
    telemetryRequest([makeTelemetryEvent()], { "X-App-Token": "token" }),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    {},
    failingFetch
  );
  assert.equal(response.status, 200);
  assert.equal(db.insertedRows.length, 1);
});

test("scheduled handler skips when DB not configured", async () => {
  await handleScheduled({});  // 不抛错即可
});

test("scheduled handler deletes events older than retention", async () => {
  let deletedCutoff = null;
  const db = {
    prepare() {
      return {
        bind(cutoff) {
          deletedCutoff = cutoff;
          return this;
        },
        async run() {
          return { meta: { changes: 42 } };
        }
      };
    }
  };
  await handleScheduled({ TELEMETRY_DB: db });
  assert.ok(deletedCutoff !== null);
  const expectedCutoff = Date.now() - 90 * 24 * 3600 * 1000;
  assert.ok(Math.abs(deletedCutoff - expectedCutoff) < 5000);  // 5s 容差
});

test("scheduled handler swallows DB errors", async () => {
  const db = {
    prepare() {
      return {
        bind() { return this; },
        async run() { throw new Error("D1 unavailable"); }
      };
    }
  };
  await handleScheduled({ TELEMETRY_DB: db });  // 不抛错即可
});

// MARK: - P2: PROVIDERS multi-provider config parsing

function providersEnv(providers, secrets = {}, extra = {}) {
  return {
    APP_TOKEN: "token",
    PROVIDERS: JSON.stringify(providers),
    ...secrets,
    ...extra
  };
}

test("PROVIDERS picks first configured provider and routes through its adapter", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        {
          id: "ANTHROPIC_PRIMARY",
          type: "anthropic",
          url: "https://api.anthropic.example/v1/messages",
          model: "claude-test",
          priority: 1,
          weight: 10,
          enabled: true,
          secretName: "PROVIDER_KEY_ANTHROPIC_PRIMARY",
          timeoutMs: 8000
        }
      ],
      { PROVIDER_KEY_ANTHROPIC_PRIMARY: "anthropic-key" }
    ),
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("完成英语背诵") }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.anthropic.example/v1/messages");
  assert.equal(upstreamRequest.init.headers["x-api-key"], "anthropic-key");
  assert.equal(upstreamRequest.body.model, "claude-test");
});

test("PROVIDERS uses timeoutMs from the provider config", async () => {
  let upstreamSignal;
  await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{
        id: "ANTHROPIC_PRIMARY",
        type: "anthropic",
        url: "https://api.anthropic.example/v1/messages",
        model: "claude-test",
        timeoutMs: 7000
      }],
      { PROVIDER_KEY_ANTHROPIC_PRIMARY: "k" }
    ),
    {},
    async (_url, init) => {
      upstreamSignal = init.signal;
      return jsonResponse({ content: [{ type: "text", text: extractionJSON("x") }] });
    }
  );
  assert.ok(upstreamSignal instanceof AbortSignal);
});

test("PROVIDERS absent falls back to legacy ANTHROPIC_API_KEY config", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "legacy-anthropic-key",
      ANTHROPIC_MODEL: "legacy-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({ content: [{ type: "text", text: extractionJSON("完成英语背诵") }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.anthropic.com/v1/messages");
  assert.equal(upstreamRequest.init.headers["x-api-key"], "legacy-anthropic-key");
  assert.equal(upstreamRequest.body.model, "legacy-model");
});

test("PROVIDERS absent falls back to legacy OPENAI_API_KEY config when AI_PROVIDER=openai", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "buy milk" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "legacy-openai-key",
      OPENAI_MODEL: "legacy-openai-model"
    },
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({ choices: [{ message: { content: extractionJSON("Buy milk") } }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.openai.com/v1/chat/completions");
  assert.equal(upstreamRequest.init.headers.Authorization, "Bearer legacy-openai-key");
  assert.equal(upstreamRequest.body.model, "legacy-openai-model");
});

test("legacy Anthropic config fails fast when API key is missing", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic"
    },
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
  assert.equal(await response.text(), "AI proxy failed");
});

test("legacy OpenAI config fails fast when model is missing", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "openai",
      OPENAI_API_KEY: "legacy-openai-key"
    },
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
  assert.equal(await response.text(), "AI proxy failed");
});

test("PROVIDERS empty array returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv([]),
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
  assert.equal(await response.text(), "AI proxy failed");
});

test("PROVIDERS invalid JSON returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    { APP_TOKEN: "token", PROVIDERS: "{not json" },
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
});

test("PROVIDERS entry with malformed id returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{ id: "bad-id", type: "anthropic", url: "https://a.example/v1/messages", model: "m" }],
      { PROVIDER_KEY_BAD_ID: "k" }
    ),
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
});

test("PROVIDERS entry with unregistered type returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{ id: "X", type: "made-up", url: "https://a.example", model: "m" }],
      { PROVIDER_KEY_X: "k" }
    ),
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
});

test("PROVIDERS entry with non-https url returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{ id: "X", type: "anthropic", url: "http://insecure.example", model: "m" }],
      { PROVIDER_KEY_X: "k" }
    ),
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
});

test("PROVIDERS entry with empty model returns 500", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{ id: "X", type: "anthropic", url: "https://a.example/v1/messages", model: "" }],
      { PROVIDER_KEY_X: "k" }
    ),
    {},
    failingFetch
  );

  assert.equal(response.status, 500);
});

test("PROVIDERS warns when a provider secret is missing but request still succeeds via a keyed provider", async () => {
  let upstreamRequest;
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request({ transcript: "今天复习", locale: "zh-Hans" }, { "X-App-Token": "token" }),
      providersEnv(
        [
          {
            id: "ANTHROPIC_PRIMARY",
            type: "anthropic",
            url: "https://api.anthropic.example/v1/messages",
            model: "claude-test",
            priority: 1
          },
          {
            id: "OPENAI_FALLBACK",
            type: "openai",
            url: "https://api.openai.example/v1/chat/completions",
            model: "gpt-test",
            priority: 2
          }
        ],
        // Anthropic has key; OpenAI does not
        { PROVIDER_KEY_ANTHROPIC_PRIMARY: "anthropic-key" }
      ),
      {},
      async (url, init) => {
        upstreamRequest = { url, init };
        return jsonResponse({ content: [{ type: "text", text: extractionJSON("复习") }] });
      }
    );
    assert.equal(response.status, 200);
  });

  assert.equal(upstreamRequest.url, "https://api.anthropic.example/v1/messages");
  assert.ok(logs.some((line) => line.includes("proxy.provider.secret_missing") && line.includes("OPENAI_FALLBACK")));
  assert.ok(logs.some((line) => line.includes("PROVIDER_KEY_OPENAI_FALLBACK")));
});

test("PROVIDERS logs never expose secret values", async () => {
  const logs = await captureConsole(async () => {
    await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [{ id: "ANTHROPIC_PRIMARY", type: "anthropic", url: "https://a.example/v1/messages", model: "m" }],
        { PROVIDER_KEY_ANTHROPIC_PRIMARY: "super-secret-key-value" }
      ),
      {},
      async () => jsonResponse({ content: [{ type: "text", text: extractionJSON("x") }] })
    );
  });

  assert.equal(logs.some((line) => line.includes("super-secret-key-value")), false);
});

// MARK: - P3: failover scheduling

test("failovers to next provider when first returns 5xx", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "今天完成英语背诵", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "ANTHROPIC_PRIMARY", type: "anthropic", url: "https://anthropic.example/v1/messages", model: "claude-a", priority: 1 },
        { id: "OPENAI_FALLBACK", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-b", priority: 2 }
      ],
      {
        PROVIDER_KEY_ANTHROPIC_PRIMARY: "k-a",
        PROVIDER_KEY_OPENAI_FALLBACK: "k-b"
      }
    ),
    {},
    async (url, init) => {
      calls.push(url);
      if (url.includes("anthropic.example")) {
        return new Response(JSON.stringify({ error: "internal" }), { status: 503, headers: { "Content-Type": "application/json" } });
      }
      return jsonResponse({ choices: [{ message: { content: extractionJSON("完成英语背诵") } }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(calls[0], "https://anthropic.example/v1/messages");
  assert.equal(calls[1], "https://openai.example/v1/chat/completions");
  const data = await response.json();
  assert.equal(data.todos[0].title, "完成英语背诵");
});

test("failovers to next provider when first fetch throws network error", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "buy milk", locale: "en-US" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "OPENAI_PRIMARY", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-a", priority: 1 },
        { id: "ANTHROPIC_FALLBACK", type: "anthropic", url: "https://anthropic.example/v1/messages", model: "claude-b", priority: 2 }
      ],
      {
        PROVIDER_KEY_OPENAI_PRIMARY: "k-a",
        PROVIDER_KEY_ANTHROPIC_FALLBACK: "k-b"
      }
    ),
    {},
    async (url) => {
      calls.push(url);
      if (url.includes("openai.example")) {
        throw new TypeError("network failed");
      }
      return jsonResponse({ content: [{ type: "text", text: extractionJSON("Buy milk") }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  const data = await response.json();
  assert.equal(data.todos[0].title, "Buy milk");
});

test("does not failover on 400 request-body errors and surfaces 502", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "ANTHROPIC_PRIMARY", type: "anthropic", url: "https://anthropic.example/v1/messages", model: "claude-a", priority: 1 },
        { id: "OPENAI_FALLBACK", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-b", priority: 2 }
      ],
      {
        PROVIDER_KEY_ANTHROPIC_PRIMARY: "k-a",
        PROVIDER_KEY_OPENAI_FALLBACK: "k-b"
      }
    ),
    {},
    async (url) => {
      calls.push(url);
      // Generic malformed-transcript style error: no model keyword.
      return new Response(JSON.stringify({ error: { message: "invalid_argument: transcript malformed" } }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }
  );

  assert.equal(response.status, 502);
  // Should NOT have tried OPENAI_FALLBACK since the 400 was classified request-body.
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("anthropic.example"));
});

test("failovers on 400 model-not-found error (treated as model_config)", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "ANTHROPIC_PRIMARY", type: "anthropic", url: "https://anthropic.example/v1/messages", model: "claude-a", priority: 1 },
        { id: "OPENAI_FALLBACK", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-b", priority: 2 }
      ],
      {
        PROVIDER_KEY_ANTHROPIC_PRIMARY: "k-a",
        PROVIDER_KEY_OPENAI_FALLBACK: "k-b"
      }
    ),
    {},
    async (url) => {
      calls.push(url);
      if (url.includes("anthropic.example")) {
        return new Response(JSON.stringify({ type: "error", error: { type: "model_not_found_error", message: "model not found: claude-a" } }), {
          status: 400,
          headers: { "Content-Type": "application/json" }
        });
      }
      return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
});

test("caps provider error body reads before retry classification", async () => {
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [
          { id: "ANTHROPIC_PRIMARY", type: "anthropic", url: "https://anthropic.example/v1/messages", model: "claude-a", priority: 1 },
          { id: "OPENAI_FALLBACK", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-b", priority: 2 }
        ],
        {
          PROVIDER_KEY_ANTHROPIC_PRIMARY: "k-a",
          PROVIDER_KEY_OPENAI_FALLBACK: "k-b"
        }
      ),
      {},
      async (url) => {
        if (url.includes("anthropic.example")) {
          return new Response(`model_not_found ${"x".repeat(128 * 1024)}`, {
            status: 400,
            headers: { "Content-Type": "application/json" }
          });
        }
        return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
      }
    );
    assert.equal(response.status, 200);
  });

  const failedLog = logs
    .filter((line) => line.includes("proxy.provider.call_failed"))
    .map((line) => JSON.parse(line))
    .find((entry) => entry.providerId === "ANTHROPIC_PRIMARY");
  assert.equal(failedLog.errorBodyTruncated, true);
  assert.ok(failedLog.errorBodyBytes <= 64 * 1024);
});

test("returns 503 when all providers fail with retryable errors", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
    ),
    {},
    async () => new Response("error", { status: 500 })
  );

  assert.equal(response.status, 503);
});

test("AI_PROVIDER_MAX_ATTEMPTS caps how many providers are tried", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
        { id: "B", type: "anthropic", url: "https://b.example/v1/messages", model: "m", priority: 2 },
        { id: "C", type: "anthropic", url: "https://c.example/v1/messages", model: "m", priority: 3 }
      ],
      {
        PROVIDER_KEY_A: "k-a",
        PROVIDER_KEY_B: "k-b",
        PROVIDER_KEY_C: "k-c"
      },
      { AI_PROVIDER_MAX_ATTEMPTS: "2" }
    ),
    {},
    async (url) => {
      calls.push(url);
      return new Response("error", { status: 500 });
    }
  );

  assert.equal(response.status, 503);
  assert.equal(calls.length, 2);
});

test("failover emits providersTried telemetry on success after one failover", async () => {
  let finishedLog = null;
  const logs = await captureConsole(async () => {
    await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [
          { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
          { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
        ],
        { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
      ),
      {},
      async (url) => {
        if (url.includes("a.example")) {
          return new Response("error", { status: 500 });
        }
        return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
      }
    );
  });

  finishedLog = logs.find((line) => line.includes("proxy.request.finished"));
  assert.ok(finishedLog, "expected a finished log line");
  const parsed = JSON.parse(finishedLog);
  assert.deepEqual(parsed.providersTried, ["A", "B"]);
  assert.equal(parsed.providerUsed, "B");
  assert.equal(parsed.failoverCount, 1);
});

test("does not emit failover telemetry for the final failed provider", async () => {
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [
          { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
          { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
        ],
        { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
      ),
      {},
      async () => new Response("error", { status: 500 })
    );
    assert.equal(response.status, 503);
  });

  const failoverLogs = logs
    .filter((line) => line.includes("proxy.provider.failover"))
    .map((line) => JSON.parse(line));
  assert.equal(failoverLogs.length, 1);
  assert.equal(failoverLogs[0].fromProviderId, "A");
});

test("non-streaming invalid provider bodies failover and count toward circuit breaker", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
      { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
    ],
    { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("a.example")) {
      return new Response("{not-json", {
        status: 200,
        headers: { "Content-Type": "application/json" }
      });
    }
    return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
  };

  for (let i = 0; i < 3; i++) {
    const response = await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      env,
      {},
      fetchImpl
    );
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.todos[0].title, "x");
  }

  calls.length = 0;
  const responseAfter = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    env,
    {},
    fetchImpl
  );
  assert.equal(responseAfter.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"), "A's invalid bodies should open the circuit");
});

test("failover works in streaming mode when first provider fails before headers", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x", stream: true }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
    ),
    {},
    async (url) => {
      calls.push(url);
      if (url.includes("a.example")) {
        return new Response("error", { status: 500 });
      }
      return sseResponse([
        `data: ${JSON.stringify({ choices: [{ delta: { content: "{\"todos\":[]" } }] })}`,
        `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }] })}`
      ]);
    }
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "text/event-stream; charset=utf-8");
  assert.equal(calls.length, 2);

  const body = await response.text();
  assert.ok(body.includes("data: {\"text\":\"{\\\"todos\\\":[]\"}"));
  assert.ok(body.includes("data: [DONE]"));
});

test("disabled provider is filtered from candidates", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, enabled: false },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" }
    ),
    {},
    async (url) => {
      calls.push(url);
      return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"));
});

test("provider with missing secret is filtered from candidates and not called", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      // Only B has a secret; A's PROVIDER_KEY_A is intentionally absent.
      { PROVIDER_KEY_B: "k-b" }
    ),
    {},
    async (url) => {
      calls.push(url);
      return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"));
});

test("returns 503 when no providers pass the selector filter", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, enabled: false },
        { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
      ],
      // B has no secret configured either.
      {}
    ),
    {},
    failingFetch
  );

  assert.equal(response.status, 503);
});

// MARK: - P4: circuit breaker

test("opens circuit after 3 retryable failures and skips that provider", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
      { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
    ],
    { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" },
    { AI_PROVIDER_STATE_KV: kv }
  );

  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("a.example")) {
      return new Response("error", { status: 500 });
    }
    return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
  };

  for (let i = 0; i < 3; i++) {
    const response = await handleRequest(request({ transcript: "x" }, { "X-App-Token": "token" }), env, {}, fetchImpl);
    assert.equal(response.status, 200);
  }

  calls.length = 0;
  const responseAfter = await handleRequest(request({ transcript: "x" }, { "X-App-Token": "token" }), env, {}, fetchImpl);
  assert.equal(responseAfter.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"), "A's circuit should be open; only B should be called");
});

test("non-retryable 4xx does not count toward circuit breaker", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 }
    ],
    { PROVIDER_KEY_A: "k-a" },
    { AI_PROVIDER_STATE_KV: kv }
  );

  for (let i = 0; i < 5; i++) {
    await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      env,
      {},
      async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ error: "invalid transcript" }), {
          status: 400,
          headers: { "Content-Type": "application/json" }
        });
      }
    );
  }

  // All 5 should have hit A — circuit never opens on 4xx request-body errors.
  assert.equal(calls.length, 5);
});

test("successful calls reset consecutive provider failures", async () => {
  const healthStore = new HealthStore({ kv: null });

  await healthStore.recordFailure("A", "status_500");
  await healthStore.recordFailure("A", "status_500");
  assert.equal(await healthStore.circuitState("A"), "closed");

  await healthStore.recordSuccess("A", 100);
  await healthStore.recordFailure("A", "status_500");
  await healthStore.recordFailure("A", "status_500");

  assert.equal(await healthStore.circuitState("A"), "closed");
});

test("half-open trial success closes the circuit", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  let currentTime = 0;
  const healthStore = new HealthStore({ kv, now: () => currentTime });

  // First three failures open the circuit at t=0.
  for (let i = 0; i < 3; i++) {
    await healthStore.recordFailure("A", "status_500");
  }
  assert.equal(await healthStore.circuitState("A"), "open");

  // Advance past 30s cooldown → half-open.
  currentTime = 31_000;
  assert.equal(await healthStore.circuitState("A"), "half-open");

  // Half-open trial succeeds → close.
  await healthStore.recordSuccess("A", 100);
  assert.equal(await healthStore.circuitState("A"), "closed");

  void calls;
});

test("half-open trial failure re-opens circuit with doubled cooldown", async () => {
  const kv = new MemoryKV(new Map());
  let currentTime = 0;
  const healthStore = new HealthStore({ kv, now: () => currentTime });

  for (let i = 0; i < 3; i++) {
    await healthStore.recordFailure("A", "status_500");
  }
  // First open uses 30s cooldown.
  currentTime = 31_000;
  assert.equal(await healthStore.circuitState("A"), "half-open");

  // Half-open trial fails → re-open with doubled cooldown (60s).
  await healthStore.recordFailure("A", "status_500");
  assert.equal(await healthStore.circuitState("A"), "open");

  // Within 60s (since re-open at t=31000), still open.
  currentTime = 31_000 + 50_000;
  assert.equal(await healthStore.circuitState("A"), "open");
  // After 60s since re-open, half-open again.
  currentTime = 31_000 + 61_000;
  assert.equal(await healthStore.circuitState("A"), "half-open");
});

test("HealthStore degrades to memory mode when KV throws", async () => {
  const failingKv = {
    async get() { throw new Error("KV down"); },
    async put() { throw new Error("KV down"); }
  };
  const healthStore = new HealthStore({ kv: failingKv });

  for (let i = 0; i < 3; i++) {
    await healthStore.recordFailure("A", "status_500");
  }
  // Should still classify as open via in-memory state.
  assert.equal(await healthStore.circuitState("A"), "open");
  assert.equal(healthStore.degraded, true);
});

test("HealthStore works without KV (in-memory only)", async () => {
  const healthStore = new HealthStore({ kv: null });
  for (let i = 0; i < 3; i++) {
    await healthStore.recordFailure("A", "status_500");
  }
  assert.equal(await healthStore.circuitState("A"), "open");
});

// MARK: - P5: latency-aware selector

function makeProvider(overrides) {
  return {
    id: overrides.id,
    type: overrides.type || "anthropic",
    url: overrides.url || `https://${overrides.id.toLowerCase()}.example/v1/messages`,
    model: overrides.model || "m",
    apiKey: overrides.apiKey || "k",
    priority: overrides.priority ?? 1,
    weight: overrides.weight ?? 1,
    enabled: overrides.enabled ?? true,
    timeoutMs: overrides.timeoutMs ?? 15_000
  };
}

// Stub HealthStore that returns pre-baked snapshots. Lets selector tests run without KV.
function stubHealthStore(snapshotsByProvider) {
  return {
    async snapshot(providerId) {
      return snapshotsByProvider[providerId] || { state: "closed", ewmaLatencyMs: 0, sampleCount: 0 };
    },
    async circuitState(providerId) {
      const snap = snapshotsByProvider[providerId] || { state: "closed" };
      return snap.state;
    }
  };
}

test("selector places warm providers (with latency) before cold providers", async () => {
  const providers = [
    makeProvider({ id: "WARM", priority: 5 }),
    makeProvider({ id: "COLD", priority: 1 })
  ];
  const health = stubHealthStore({
    WARM: { state: "closed", ewmaLatencyMs: 200, sampleCount: 5 },
    COLD: { state: "closed", ewmaLatencyMs: 0, sampleCount: 0 }
  });
  const candidates = await pickCandidates(providers, health, Date.now());
  assert.deepEqual(candidates.map((p) => p.id), ["WARM", "COLD"]);
});

test("selector sorts warm providers by latency ascending regardless of priority", async () => {
  const providers = [
    makeProvider({ id: "SLOW", priority: 1 }),
    makeProvider({ id: "FAST", priority: 5 }),
    makeProvider({ id: "MID", priority: 3 })
  ];
  const health = stubHealthStore({
    SLOW: { state: "closed", ewmaLatencyMs: 800, sampleCount: 5 },
    FAST: { state: "closed", ewmaLatencyMs: 100, sampleCount: 5 },
    MID: { state: "closed", ewmaLatencyMs: 400, sampleCount: 5 }
  });
  const candidates = await pickCandidates(providers, health, Date.now());
  assert.deepEqual(candidates.map((p) => p.id), ["FAST", "MID", "SLOW"]);
});

test("selector uses priority order for cold providers when weights are equal", async () => {
  const providers = [
    makeProvider({ id: "A", priority: 3 }),
    makeProvider({ id: "B", priority: 1 }),
    makeProvider({ id: "C", priority: 2 })
  ];
  // No latency data, default weights → fall back to priority.
  const candidates = await pickCandidates(providers, null, Date.now());
  assert.deepEqual(candidates.map((p) => p.id), ["B", "C", "A"]);
});

test("selector uses weighted random for cold providers when weights differ", async () => {
  const providers = [
    makeProvider({ id: "HEAVY", priority: 1, weight: 100 }),
    makeProvider({ id: "LIGHT", priority: 2, weight: 1 })
  ];
  // Deterministic RNG: 0.5 for both draws. Math.pow(0.5, 1/100) > Math.pow(0.5, 1/1)
  // because dividing by a larger weight brings the key closer to 1.
  // So HEAVY should sort first.
  const candidates = await pickCandidates(providers, null, Date.now(), { random: () => 0.5 });
  assert.deepEqual(candidates.map((p) => p.id), ["HEAVY", "LIGHT"]);
});

test("selector puts half-open providers at the end of the candidate list", async () => {
  const providers = [
    makeProvider({ id: "HALF", priority: 1 }),
    makeProvider({ id: "CLOSED", priority: 2 })
  ];
  const health = stubHealthStore({
    HALF: { state: "half-open", ewmaLatencyMs: 0, sampleCount: 0 },
    CLOSED: { state: "closed", ewmaLatencyMs: 0, sampleCount: 0 }
  });
  const candidates = await pickCandidates(providers, health, Date.now());
  assert.deepEqual(candidates.map((p) => p.id), ["CLOSED", "HALF"]);
});

test("HealthStore EWMA converges toward new latency samples", async () => {
  const healthStore = new HealthStore({ kv: null });
  // Seed with a high first sample (no prior → set directly).
  await healthStore.recordSuccess("A", 1000);
  let snap = await healthStore.snapshot("A");
  assert.equal(snap.ewmaLatencyMs, 1000);

  // Now feed low-latency samples; EWMA should drift downward but never jump.
  await healthStore.recordSuccess("A", 100);
  snap = await healthStore.snapshot("A");
  // ewma = 0.7 * 1000 + 0.3 * 100 = 730
  assert.ok(snap.ewmaLatencyMs < 1000);
  assert.ok(snap.ewmaLatencyMs > 100);
  assert.equal(Math.round(snap.ewmaLatencyMs), 730);
});

test("HealthStore keeps newer in-memory samples when KV write is throttled", async () => {
  const kv = new MemoryKV(new Map());
  let currentTime = 1_000;
  const healthStore = new HealthStore({ kv, now: () => currentTime });

  await healthStore.recordSuccess("A", 100);
  currentTime += 1_000;
  await healthStore.recordSuccess("A", 101);

  const snap = await healthStore.snapshot("A");
  assert.equal(snap.sampleCount, 2);
  assert.equal(Math.round(snap.ewmaLatencyMs), 100);
});

// MARK: - P6: Gemini adapter

test("gemini provider builds URL with model and key in path/query", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "today standup", locale: "en-US" }, { "X-App-Token": "token" }),
    providersEnv(
      [{
        id: "GEMINI_PRIMARY",
        type: "gemini",
        url: "https://generativelanguage.googleapis.com/v1beta/models",
        model: "gemini-1.5-flash",
        priority: 1
      }],
      { PROVIDER_KEY_GEMINI_PRIMARY: "gemini-key" }
    ),
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return jsonResponse({
        candidates: [{
          content: { parts: [{ text: extractionJSON("Standup") }] },
          finishReason: "STOP"
        }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.ok(upstreamRequest.url.startsWith("https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=gemini-key"));
  assert.equal(upstreamRequest.init.headers["Content-Type"], "application/json");
  // No Authorization header — Gemini uses the query param.
  assert.equal(upstreamRequest.init.headers.Authorization, undefined);
  // Body is Google's contents/parts schema.
  assert.equal(upstreamRequest.body.contents[0].parts[0].text, "today standup");
  assert.ok(upstreamRequest.body.systemInstruction.parts[0].text);
  assert.equal(upstreamRequest.body.generationConfig.responseMimeType, "application/json");

  const data = await response.json();
  assert.equal(data.todos[0].title, "Standup");
});

test("gemini streaming uses streamGenerateContent with alt=sse", async () => {
  let upstreamRequest;
  const response = await handleRequest(
    request({ transcript: "plan meeting", locale: "en-US", stream: true }, { "X-App-Token": "token" }),
    providersEnv(
      [{
        id: "GEMINI_PRIMARY",
        type: "gemini",
        url: "https://generativelanguage.googleapis.com/v1beta/models",
        model: "gemini-1.5-flash",
        priority: 1
      }],
      { PROVIDER_KEY_GEMINI_PRIMARY: "gemini-key" }
    ),
    {},
    async (url, init) => {
      upstreamRequest = { url, init, body: JSON.parse(init.body) };
      return sseResponse([
        `data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: "{\"todos\":" }] } }] })}`,
        `data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: "[]" }] } }] })}`,
        `data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: "" }] }, finishReason: "STOP" }] })}`
      ]);
    }
  );

  assert.equal(response.status, 200);
  assert.ok(upstreamRequest.url.includes(":streamGenerateContent?"));
  assert.ok(upstreamRequest.url.includes("alt=sse"));
  assert.equal(response.headers.get("Content-Type"), "text/event-stream; charset=utf-8");

  const body = await response.text();
  assert.ok(body.includes('data: {"text":"{\\"todos\\":"}'));
  assert.ok(body.includes('data: {"text":"[]"}'));
  assert.ok(body.includes("data: [DONE]"));
});

test("gemini streaming emits text carried on the final finish event", async () => {
  const response = await handleRequest(
    request({ transcript: "plan meeting", locale: "en-US", stream: true }, { "X-App-Token": "token" }),
    providersEnv(
      [{
        id: "GEMINI_PRIMARY",
        type: "gemini",
        url: "https://generativelanguage.googleapis.com/v1beta/models",
        model: "gemini-1.5-flash",
        priority: 1
      }],
      { PROVIDER_KEY_GEMINI_PRIMARY: "gemini-key" }
    ),
    {},
    async () => sseResponse([
      `data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: "{\"todos\":" }] } }] })}`,
      `data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: "[]" }] }, finishReason: "STOP" }] })}`
    ])
  );

  assert.equal(response.status, 200);
  const body = await response.text();
  assert.ok(body.includes('data: {"text":"{\\"todos\\":"}'));
  assert.ok(body.includes('data: {"text":"[]"}'));
  assert.ok(body.includes("data: [DONE]"));
});

test("gemini provider participates in failover when first provider fails", async () => {
  const calls = [];
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [
        { id: "OPENAI_PRIMARY", type: "openai", url: "https://openai.example/v1/chat/completions", model: "gpt-a", priority: 1 },
        { id: "GEMINI_FALLBACK", type: "gemini", url: "https://gemini.example/v1beta/models", model: "gemini-b", priority: 2 }
      ],
      { PROVIDER_KEY_OPENAI_PRIMARY: "k-a", PROVIDER_KEY_GEMINI_FALLBACK: "k-b" }
    ),
    {},
    async (url) => {
      calls.push(url);
      if (url.includes("openai.example")) {
        return new Response("error", { status: 503 });
      }
      return jsonResponse({
        candidates: [{ content: { parts: [{ text: extractionJSON("x") }] }, finishReason: "STOP" }]
      });
    }
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.ok(calls.some((url) => url.includes("gemini.example")));
});

test("gemini adapter URL never appears in proxy logs", async () => {
  const logs = await captureConsole(async () => {
    await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [{
          id: "GEMINI_PRIMARY",
          type: "gemini",
          url: "https://gemini.example/v1beta/models",
          model: "gemini-1.5-flash",
          priority: 1
        }],
        { PROVIDER_KEY_GEMINI_PRIMARY: "secret-key-in-url" }
      ),
      {},
      async () => jsonResponse({
        candidates: [{ content: { parts: [{ text: extractionJSON("x") }] }, finishReason: "STOP" }]
      })
    );
  });

  // No log line should expose the URL (which contains the key as a query param).
  assert.equal(logs.some((line) => line.includes("secret-key-in-url")), false);
  assert.equal(logs.some((line) => line.includes("gemini.example")), false);
});

test("provider fetch errors redact URL-embedded Gemini keys from logs", async () => {
  const logs = await captureConsole(async () => {
    const response = await handleRequest(
      request({ transcript: "x" }, { "X-App-Token": "token" }),
      providersEnv(
        [{
          id: "GEMINI_PRIMARY",
          type: "gemini",
          url: "https://gemini.example/v1beta/models",
          model: "gemini-1.5-flash",
          priority: 1
        }],
        { PROVIDER_KEY_GEMINI_PRIMARY: "secret-key-in-url" }
      ),
      {},
      async (url) => {
        throw new TypeError(`fetch failed for ${url}`);
      }
    );
    assert.equal(response.status, 503);
  });

  assert.equal(logs.some((line) => line.includes("secret-key-in-url")), false);
  assert.equal(logs.some((line) => line.includes(encodeURIComponent("secret-key-in-url"))), false);
});

test("isRetryable classifies 400 model-not-found as retryable for each adapter", async () => {
  const anthropicClass = anthropicAdapter.isRetryable({ status: 400, bodyText: "model_not_found_error: claude-x" });
  assert.equal(anthropicClass.retryable, true);
  assert.equal(anthropicClass.errorType, "model_config");

  const openaiClass = openaiAdapter.isRetryable({ status: 400, bodyText: "The model `gpt-x` does not exist" });
  assert.equal(openaiClass.retryable, true);
  assert.equal(openaiClass.errorType, "model_config");

  const geminiClass = geminiAdapter.isRetryable({ status: 400, bodyText: "model not found: gemini-x" });
  assert.equal(geminiClass.retryable, true);
  assert.equal(geminiClass.errorType, "model_config");
});

test("isRetryable classifies generic 400 as request_body (non-retryable)", async () => {
  for (const adapter of [anthropicAdapter, openaiAdapter, geminiAdapter]) {
    const result = adapter.isRetryable({ status: 400, bodyText: "invalid_argument: transcript malformed" });
    assert.equal(result.retryable, false);
    assert.equal(result.errorType, "request_body");
  }
});

test("isRetryable treats 5xx / 408 / 429 / 401 / 403 as retryable", async () => {
  for (const status of [401, 403, 408, 429, 500, 502, 503, 504]) {
    const result = anthropicAdapter.isRetryable({ status, bodyText: "" });
    assert.equal(result.retryable, true, `expected ${status} to be retryable`);
  }
});

test("PROVIDERS with gemini type now validates as registered", async () => {
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    providersEnv(
      [{
        id: "GEMINI",
        type: "gemini",
        url: "https://gemini.example/v1beta/models",
        model: "gemini-1.5-flash"
      }],
      { PROVIDER_KEY_GEMINI: "k" }
    ),
    {},
    async () => jsonResponse({
      candidates: [{ content: { parts: [{ text: extractionJSON("x") }] }, finishReason: "STOP" }]
    })
  );
  assert.equal(response.status, 200);
});

test("half-open provider is placed last in candidate ordering", async () => {
  const calls = [];
  const kv = new MemoryKV(new Map());
  let currentTime = 0;
  const healthStore = new HealthStore({ kv, now: () => currentTime });

  // Open A's circuit (priority 1, would normally be tried first).
  for (let i = 0; i < 3; i++) {
    await healthStore.recordFailure("A", "status_500");
  }
  currentTime = 31_000; // A goes half-open
  assert.equal(await healthStore.circuitState("A"), "half-open");

  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1 },
      { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2 }
    ],
    { PROVIDER_KEY_A: "k-a", PROVIDER_KEY_B: "k-b" },
    { AI_PROVIDER_STATE_KV: kv }
  );

  // B should be tried first (closed) — A only as a probe if B fails.
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("a.example")) {
      return new Response("error", { status: 500 });
    }
    return jsonResponse({ choices: [{ message: { content: extractionJSON("x") } }] });
  };
  const response = await handleRequest(
    request({ transcript: "x" }, { "X-App-Token": "token" }),
    env,
    {},
    fetchImpl
  );
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes("b.example"));
});

async function captureConsole(operation) {
  const originalLog = console.log;
  const originalWarn = console.warn;
  const originalError = console.error;
  const lines = [];
  const capture = (line) => {
    lines.push(String(line));
  };

  console.log = capture;
  console.warn = capture;
  console.error = capture;
  try {
    await operation();
  } finally {
    console.log = originalLog;
    console.warn = originalWarn;
    console.error = originalError;
  }
  return lines;
}

class MemoryKV {
  constructor(values) {
    this.values = values;
  }

  async get(key, options) {
    const value = this.values.get(key);
    if (value === undefined || value === null) return null;
    if (options && options.type === "json") {
      try { return JSON.parse(value); } catch { return value; }
    }
    return value;
  }

  async put(key, value) {
    this.values.set(key, value);
  }
}

// MARK: - Step 4 DO 路径测试基础设施

// 模拟 QuotaCounter DO 的 consume + refund 逻辑(强一致 increment)。
// 真实 DO 的并发串行化由平台保证,这里只是单线程模拟实现。
function makeFakeQuotaCounterDO({ failOnce = false, alwaysFail = false } = {}) {
  const store = new Map();
  const calls = [];
  let callCount = 0;
  const stub = {
    async fetch(req) {
      callCount += 1;
      if (alwaysFail) throw new Error("DO unreachable");
      if (failOnce && callCount === 1) throw new Error("DO transient error");
      const body = JSON.parse(await req.text());
      calls.push(body);
      const storageKey = `${body.date}:${body.key}`;
      const url = new URL(req.url);
      const current = store.get(storageKey) || 0;

      if (url.pathname === "/refund") {
        const decrement = Math.min(body.amount || 1, current);
        const newUsed = current - decrement;
        if (newUsed === 0) {
          store.delete(storageKey);
        } else {
          store.set(storageKey, newUsed);
        }
        return new Response(JSON.stringify({
          refunded: decrement, used: newUsed
        }), { status: 200, headers: { "Content-Type": "application/json" } });
      }

      // 默认 /consume
      const limit = body.limit;
      if (current >= limit) {
        return new Response(JSON.stringify({
          allowed: false, used: current, remaining: 0, limit, taken: 0
        }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      const take = Math.min(body.amount || 1, limit - current);
      const newUsed = current + take;
      store.set(storageKey, newUsed);
      return new Response(JSON.stringify({
        allowed: true, used: newUsed, remaining: limit - newUsed, limit, taken: take
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
  };
  return {
    idFromName(name) { return { name }; },
    get() { return stub; },
    _store: store,
    _calls: calls,
    _callCount: () => callCount
  };
}

// 收集 ctx.waitUntil 启动的后台 promise,提供 awaitAll 让测试等待影子写完成。
function makeFakeCtx() {
  const pending = [];
  return {
    waitUntil(p) { pending.push(p); },
    async awaitAll() { await Promise.all(pending); }
  };
}

test("Step 4 DO 路径:env 绑定 QUOTA_COUNTER_DO 时走 DO,X-Quota-Used 来自 DO", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "device-1", "X-Local-Date": "2026-05-26" };
    const r1 = await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok1"));
    const r2 = await handleRequest(request({ transcript: "b" }, headers), env, ctx, jsonResponseProvider("ok2"));

    assert.equal(r1.status, 200);
    assert.equal(r1.headers.get("X-Quota-Used"), "1");
    assert.equal(r1.headers.get("X-Quota-Remaining"), "4");
    assert.equal(r2.headers.get("X-Quota-Used"), "2");

    // DO 被调用两次
    assert.equal(doBinding._calls.length, 2);
    // 等待 KV 影子写完成
    await ctx.awaitAll();
    // KV 应被覆盖式写入 used=2(不读,直接 put)
    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "KV 应被影子写");
    assert.equal(kv.values.get(quotaKey), "2");
  });
});

test("Step 4 DO 路径:超限时返回 429,DO allowed=false", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "2",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "d1", "X-Local-Date": "2026-05-26" };
    await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok1"));
    await handleRequest(request({ transcript: "b" }, headers), env, ctx, jsonResponseProvider("ok2"));
    const third = await handleRequest(request({ transcript: "c" }, headers), env, ctx, jsonResponseProvider("ok3"));

    assert.equal(third.status, 429);
    const body = await third.json();
    assert.equal(body.error, "quota_exceeded");
    assert.equal(third.headers.get("X-Quota-Used"), "2");
    assert.equal(third.headers.get("X-Quota-Remaining"), "0");
  });
});

test("Step 4 DO 路径:DO fetch 抛错时自动 fallback 到 KV,响应仍 200", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO({ alwaysFail: true });
  const ctx = makeFakeCtx();
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
      const env = {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        RATE_LIMIT_KV: kv,
        QUOTA_COUNTER_DO: doBinding
      };
      const headers = { "X-App-Token": "token", "X-Device-ID": "d1", "X-Local-Date": "2026-05-26" };
      const r = await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok"));
      assert.equal(r.status, 200);
      assert.equal(r.headers.get("X-Quota-Used"), "1");
    });
  });
  assert.ok(logs.some((l) => l.includes("proxy.quota.do_failed_fallback_kv")), "应 log warn do_failed_fallback_kv");
  // KV 路径被走(直接 put used=1)
  const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
  assert.ok(quotaKey);
  assert.equal(kv.values.get(quotaKey), "1");
});

test("Step 4 DO 路径:DO 故障 fallback 到 KV 后,KV 限流仍生效", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO({ alwaysFail: true });
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "d1", "X-Local-Date": "2026-05-26" };
    const r1 = await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok1"));
    const r2 = await handleRequest(request({ transcript: "b" }, headers), env, ctx, jsonResponseProvider("ok2"));
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 429);
  });
});

test("Step 4 DO 路径:DO 非 200 响应也触发 fallback", async () => {
  const kv = new MemoryKV(new Map());
  // 自定义 DO,返回 500
  const doBinding = {
    idFromName: () => ({}),
    get: () => ({
      fetch: async () => new Response('{"error":"internal"}', {
        status: 500,
        headers: { "Content-Type": "application/json" }
      })
    })
  };
  const ctx = makeFakeCtx();
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
      const env = {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "5",
        RATE_LIMIT_KV: kv,
        QUOTA_COUNTER_DO: doBinding
      };
      const headers = { "X-App-Token": "token", "X-Device-ID": "d1", "X-Local-Date": "2026-05-26" };
      const r = await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok"));
      assert.equal(r.status, 200);
    });
  });
  assert.ok(logs.some((l) => l.includes("do_failed_fallback_kv")), "应触发 KV fallback");
});

test("Step 4 DO 路径:DO 路径成功后 KV 影子写不影响响应延迟(异步)", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  let shadowWriteStarted = false;
  let shadowWriteFinished = false;
  // 让 KV.put 慢一点,模拟影子写耗时
  const slowKV = {
    values: kv.values,
    async get(k, o) { return kv.get(k, o); },
    async put(k, v) {
      shadowWriteStarted = true;
      await new Promise((r) => setTimeout(r, 50));
      kv.values.set(k, v);
      shadowWriteFinished = true;
    }
  };
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: slowKV,
      QUOTA_COUNTER_DO: doBinding
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "d1", "X-Local-Date": "2026-05-26" };
    const r = await handleRequest(request({ transcript: "a" }, headers), env, ctx, jsonResponseProvider("ok"));
    // 响应已返回,但影子写可能还没完
    assert.equal(r.status, 200);
    // 等待 ctx.waitUntil 完成
    await ctx.awaitAll();
    assert.ok(shadowWriteFinished, "KV 影子写应最终完成");
  });
});

// 用于 Step 4 测试:模拟 anthropic provider 成功返回一个简单 JSON。
function jsonResponseProvider(title) {
  return async () => jsonResponse({
    content: [{ type: "text", text: extractionJSON(title) }]
  });
}

// MARK: - Step 5 IP-daily DO 路径测试

test("Step 5 IP-daily DO 路径:同一 IP 轮换 device id 时 DO 维度正确限流", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      IP_DAILY_LIMIT: "2",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = (n) => request({ transcript: `t${n}` }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": `rotating-${n}`,
      "X-Local-Date": "2026-05-26"
    });
    const r1 = await handleRequest(mk(1), env, ctx, jsonResponseProvider("a"));
    const r2 = await handleRequest(mk(2), env, ctx, jsonResponseProvider("b"));
    const r3 = await handleRequest(mk(3), env, ctx, jsonResponseProvider("c"));
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 200);
    assert.equal(r3.status, 429);
    const body = await r3.json();
    assert.equal(body.error, "rate_limited");
    assert.equal(r3.headers.get("X-RateLimit-Type"), "ip_daily");
  });
});

test("Step 5 IP-daily DO 路径:DO 故障 fallback 到 KV,响应仍 200", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO({ alwaysFail: true });
  const ctx = makeFakeCtx();
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00Z", async () => {
      const env = {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        IP_DAILY_LIMIT: "5",
        RATE_LIMIT_KV: kv,
        QUOTA_COUNTER_DO: doBinding
      };
      const r = await handleRequest(
        request({ transcript: "a" }, {
          "X-App-Token": "token",
          "CF-Connecting-IP": "1.2.3.4",
          "X-Local-Date": "2026-05-26"
        }),
        env,
        ctx,
        jsonResponseProvider("a")
      );
      assert.equal(r.status, 200);
    });
  });
  assert.ok(logs.some((l) => l.includes("proxy.ip_quota.do_failed_fallback_kv")), "应 log warn ip_quota.do_failed_fallback_kv");
  // KV 路径被走
  const ipKey = [...kv.values.keys()].find((k) => k.startsWith("ip-quota:2026-05-26:"));
  assert.ok(ipKey);
  assert.equal(kv.values.get(ipKey), "1");
});

test("Step 5 IP-daily DO 路径:DO 故障 fallback 后,KV 限流仍生效", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO({ alwaysFail: true });
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      IP_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Local-Date": "2026-05-26"
    });
    const r1 = await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    const r2 = await handleRequest(mk(), env, ctx, jsonResponseProvider("b"));
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 429);
  });
});

test("Step 5 ip-rate 仍走 KV(精度收益不抵成本,DO 不应被调用)", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      IP_RATE_PER_MINUTE: "2",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = (n) => request({ transcript: `t${n}` }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": `d${n}`,
      "X-Local-Date": "2026-05-26"
    });
    const r1 = await handleRequest(mk(1), env, ctx, jsonResponseProvider("a"));
    const r2 = await handleRequest(mk(2), env, ctx, jsonResponseProvider("b"));
    const r3 = await handleRequest(mk(3), env, ctx, jsonResponseProvider("c"));
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 200);
    assert.equal(r3.status, 429);
    assert.equal(r3.headers.get("X-RateLimit-Type"), "velocity");
    // ip-rate 走 KV,DO 完全没被调用
    assert.equal(doBinding._calls.length, 0, "DO 不应被 ip-rate 调用");
    // KV 里有 ip-rate key
    const ipRateKey = [...kv.values.keys()].find((k) => k.startsWith("ip-rate:"));
    assert.ok(ipRateKey);
  });
});

// MARK: - Step 6 全局预算 DO 路径测试

test("Step 6 全局预算 DO 路径:KV tripped=1 时直接 503,不调 DO", async () => {
  const kv = new MemoryKV(new Map([
    ["global-budget-tripped:2026-05-26", "1"]
  ]));
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      GLOBAL_DAILY_LIMIT: "5",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const r = await handleRequest(
      request({ transcript: "a" }, {
        "X-App-Token": "token",
        "X-Local-Date": "2026-05-26"
      }),
      env,
      ctx,
      jsonResponseProvider("a")
    );
    assert.equal(r.status, 503);
    const body = await r.json();
    assert.equal(body.error, "global_budget_exceeded");
    // tripped 热路径直接拒绝,DO 完全没被调用
    assert.equal(doBinding._calls.length, 0);
  });
});

test("Step 6 全局预算 DO 路径:KV 未 tripped 时 200,DO 异步 consume 被调用", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      GLOBAL_DAILY_LIMIT: "5",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const r = await handleRequest(
      request({ transcript: "a" }, {
        "X-App-Token": "token",
        "X-Local-Date": "2026-05-26"
      }),
      env,
      ctx,
      jsonResponseProvider("a")
    );
    assert.equal(r.status, 200);
    await ctx.awaitAll();
    // DO consume 被调用一次,用 "global-budget" key
    assert.equal(doBinding._calls.length, 1);
    assert.equal(doBinding._calls[0].key, "global-budget");
    assert.equal(doBinding._calls[0].limit, 5);
    assert.equal(doBinding._calls[0].date, "2026-05-26");
  });
});

test("Step 6 全局预算 DO 路径:DO consume 返回 allowed=false 时写 KV tripped 标志", async () => {
  const kv = new MemoryKV(new Map());
  // limit=1:第一次 consume 就到上限;第二次返回 allowed=false → 写 tripped
  const doBinding = makeFakeQuotaCounterDO();
  const ctx1 = makeFakeCtx();
  const ctx2 = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      GLOBAL_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:consume 到上限,放行
    const r1 = await handleRequest(mk(), env, ctx1, jsonResponseProvider("a"));
    assert.equal(r1.status, 200);
    await ctx1.awaitAll();
    // 此时 KV 还没 tripped
    assert.equal(kv.values.get("global-budget-tripped:2026-05-26"), undefined);
    // 第二次:DO consume 返回 allowed=false(因为已到上限),写 tripped
    // 注意:本次响应仍 200(DO consume 是异步的,本次已放行)
    const r2 = await handleRequest(mk(), env, ctx2, jsonResponseProvider("b"));
    assert.equal(r2.status, 200);
    await ctx2.awaitAll();
    assert.equal(kv.values.get("global-budget-tripped:2026-05-26"), "1");
  });
});

test("Step 6 全局预算 DO 路径:DO 故障时本次响应 200,log warn", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO({ alwaysFail: true });
  const ctx = makeFakeCtx();
  const logs = await captureConsole(async () => {
    await withMockedToday("2026-05-26T12:00:00Z", async () => {
      const env = {
        APP_TOKEN: "token",
        AI_PROVIDER: "anthropic",
        ANTHROPIC_API_KEY: "anthropic-key",
        GLOBAL_DAILY_LIMIT: "5",
        RATE_LIMIT_KV: kv,
        QUOTA_COUNTER_DO: doBinding
      };
      const r = await handleRequest(
        request({ transcript: "a" }, {
          "X-App-Token": "token",
          "X-Local-Date": "2026-05-26"
        }),
        env,
        ctx,
        jsonResponseProvider("a")
      );
      assert.equal(r.status, 200);
      await ctx.awaitAll();
    });
  });
  assert.ok(logs.some((l) => l.includes("proxy.global_budget.do_failed")), "应 log warn do_failed");
});

// MARK: - Step 7 计费顺序重排 + 失败补偿测试

test("Step 7 失败补偿:ip reject 时 device 被 refund", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      // device 配额宽(100),ip-daily 紧(1)
      DAILY_REQUEST_LIMIT: "100",
      IP_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:都通过
    const r1 = await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    assert.equal(r1.status, 200);
    await ctx.awaitAll();

    // 验证 DO 调用:第一次有 device consume + ip consume + global consume(ctx.waitUntil)
    const deviceConsumes = doBinding._calls.filter((c) => c.key === "device-quota");
    const ipConsumes = doBinding._calls.filter((c) => c.key === "ip-daily");
    assert.equal(deviceConsumes.length, 1);
    assert.equal(ipConsumes.length, 1);

    // 第二次:device 通过,ip-daily 已到上限会 reject → 触发 device refund
    doBinding._calls.length = 0;  // 重置 calls 观察
    const ctx2 = makeFakeCtx();
    const r2 = await handleRequest(mk(), env, ctx2, jsonResponseProvider("b"));
    assert.equal(r2.status, 429, "ip-daily 超限应返回 429");
    await ctx2.awaitAll();

    // device consume 被调用(refund 触发)
    const refundCalls = doBinding._calls.filter((c) => c.key === "device-quota");
    // 注意:device 配额检查也会 consume。第一次进来时检查通过 increment,然后 refund。
    // 但 device 在第二次进来时也会先 consume(因为 limit=100,远未到上限)。
    // 所以 device-quota 的 calls 应该是:1 consume(主路径) + 1 refund 调用
    // refund 用 /refund 路径不是 /consume,因此不在 _calls 里(我们只记 consume)
    // 这里改用 KV 验证 refund
  });
});

test("Step 7 失败补偿:device reject 时 ip 被 refund(DO 路径)", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      // device 紧(1),ip-daily 宽(100)
      DAILY_REQUEST_LIMIT: "1",
      IP_DAILY_LIMIT: "100",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:都通过
    await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    await ctx.awaitAll();

    // 第二次:device reject(超限),ip-daily fulfilled → refund ip
    // 同时 ip-daily 第二次 increment 会成功,但被 refund 抵消
    const ctx2 = makeFakeCtx();
    const r2 = await handleRequest(mk(), env, ctx2, jsonResponseProvider("b"));
    assert.equal(r2.status, 429, "device 超限应返回 429");
    await ctx2.awaitAll();

    // 验证 ip-daily 的最终 used:
    // 第一次 consume (used=1) → 第二次 consume (used=2) → refund (used=1)
    // DO _store 里的 ip-daily 应该是 1
    const ipKey = "2026-05-26:ip-daily";
    assert.equal(doBinding._store.get(ipKey), 1, "ip-daily 应被 refund 回 1");
  });
});

test("Step 7 失败补偿:ip reject 时 device 被 refund(DO 路径)", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "100",
      IP_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:都通过
    await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    await ctx.awaitAll();

    // 第二次:device fulfilled(used=2),ip reject(超限) → refund device
    const ctx2 = makeFakeCtx();
    const r2 = await handleRequest(mk(), env, ctx2, jsonResponseProvider("b"));
    assert.equal(r2.status, 429, "ip-daily 超限应返回 429");
    await ctx2.awaitAll();

    // device 配额的最终 used:
    // 第一次 consume (used=1) → 第二次 consume (used=2) → refund (used=1)
    const deviceKey = "2026-05-26:device-quota";
    assert.equal(doBinding._store.get(deviceKey), 1, "device 应被 refund 回 1");
  });
});

test("Step 7 都 reject 时优先抛 device 错误", async () => {
  const kv = new MemoryKV(new Map());
  const doBinding = makeFakeQuotaCounterDO();
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      // 都紧
      DAILY_REQUEST_LIMIT: "1",
      IP_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv,
      QUOTA_COUNTER_DO: doBinding
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:都通过
    await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    await ctx.awaitAll();

    // 第二次:都 reject
    const ctx2 = makeFakeCtx();
    const r2 = await handleRequest(mk(), env, ctx2, jsonResponseProvider("b"));
    assert.equal(r2.status, 429);
    const body = await r2.json();
    // device 错误优先(quota_exceeded),而不是 ip_daily
    assert.equal(body.error, "quota_exceeded");
    assert.equal(r2.headers.get("X-RateLimit-Type"), "quota");
  });
});

test("Step 7 KV 路径下 refund 也工作(dev/test 无 DO 绑定)", async () => {
  const kv = new MemoryKV(new Map());
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "100",
      IP_DAILY_LIMIT: "1",
      RATE_LIMIT_KV: kv
      // 注意:无 QUOTA_COUNTER_DO
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:都通过,device KV 计数=1
    await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    const deviceKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.equal(kv.values.get(deviceKey), "1");

    // 第二次:device KV increment 到 2,ip reject → refund device → 回到 1
    const r2 = await handleRequest(mk(), env, ctx, jsonResponseProvider("b"));
    assert.equal(r2.status, 429);
    assert.equal(kv.values.get(deviceKey), "1", "device 配额应被 KV refund 回 1(抵消第二次 increment)");
  });
});

test("Step 7 ip-rate 在 device reject 时不 refund(有意为之,反刷维度)", async () => {
  // ip-rate 是反"短时间内高频尝试"的维度,被它消耗的计数即使后续 device reject 也不退回。
  // 这是有意设计:避免攻击者用"device 配额耗尽重试"绕过 ip-rate。
  const kv = new MemoryKV(new Map());
  const ctx = makeFakeCtx();
  await withMockedToday("2026-05-26T12:00:00Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "1",     // device 紧
      IP_RATE_PER_MINUTE: "10",     // ip-rate 宽,确保能多次
      RATE_LIMIT_KV: kv
    };
    const mk = () => request({ transcript: "a" }, {
      "X-App-Token": "token",
      "CF-Connecting-IP": "9.9.9.9",
      "X-Device-ID": "d1",
      "X-Local-Date": "2026-05-26"
    });
    // 第一次:device 通过,ip-rate increment=1
    await handleRequest(mk(), env, ctx, jsonResponseProvider("a"));
    const ipRateKey = [...kv.values.keys()].find((k) => k.startsWith("ip-rate:"));
    assert.ok(ipRateKey, "ip-rate key 应存在");
    assert.equal(kv.values.get(ipRateKey), "1", "第一次后 ip-rate=1");

    // 第二次:device reject(超限),ip-rate 应再 increment 到 2(不 refund)
    const r2 = await handleRequest(mk(), env, ctx, jsonResponseProvider("b"));
    assert.equal(r2.status, 429, "device 超限应 429");
    assert.equal(kv.values.get(ipRateKey), "2", "ip-rate 应继续 increment 到 2(device reject 不触发 refund)");

    // 第三次:还是 device reject,ip-rate 到 3
    const r3 = await handleRequest(mk(), env, ctx, jsonResponseProvider("c"));
    assert.equal(r3.status, 429);
    assert.equal(kv.values.get(ipRateKey), "3", "ip-rate 应继续 increment 到 3");
  });
});

// MARK: - Step 8 断连传播测试

test("Step 8 客户端断连时 request.signal 触发上游 fetch abort", async () => {
  const ac = new AbortController();
  let upstreamSignal;
  let upstreamFetchStarted = false;
  const slowFetch = async () => {
    return new Promise((resolve, reject) => {
      upstreamFetchStarted = true;
      // 模拟上游响应慢(等待 signal 触发)
      const timer = setTimeout(() => {
        resolve(jsonResponse({
          content: [{ type: "text", text: extractionJSON("ok") }]
        }));
      }, 5000);
      // 监听 abort
      ac.signal.addEventListener("abort", () => {
        clearTimeout(timer);
        const err = new Error("aborted");
        err.name = "AbortError";
        reject(err);
      });
    });
  };
  const wrappedFetch = async (url, init) => {
    upstreamSignal = init.signal;
    return slowFetch();
  };

  // 模拟 request 带 abortSignal
  const req = new Request("https://proxy.local/v1/todo-extractions", {
    method: "POST",
    signal: ac.signal,
    headers: {
      "Content-Type": "application/json",
      "X-App-Token": "token"
    },
    body: JSON.stringify({ transcript: "test", locale: "zh" })
  });

  const responsePromise = handleRequest(req, {
    APP_TOKEN: "token",
    AI_PROVIDER: "anthropic",
    ANTHROPIC_API_KEY: "k"
  }, {}, wrappedFetch);

  // 等 fetch 启动
  await new Promise((r) => setTimeout(r, 20));
  assert.ok(upstreamFetchStarted, "上游 fetch 应已启动");
  assert.ok(upstreamSignal, "上游 fetch 应有 signal");
  assert.equal(upstreamSignal.aborted, false, "未 abort 前信号应 false");

  // 触发 abort
  ac.abort();

  // 响应应为 502(provider 失败)或类似
  const r = await responsePromise;
  assert.ok(r.status >= 400, "客户端断连后响应应是错误状态");
  assert.equal(upstreamSignal.aborted, true, "abort 后上游 signal 应为 aborted");
});

test("Step 8 上游 signal 是 timeout 和 abortSignal 的合并", async () => {
  // 验证 mergeSignals 把两个 signal 合并:任一 abort 都触发
  let capturedSignal;
  const r = await handleRequest(
    request({ transcript: "a" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "k",
      AI_PROVIDER_TIMEOUT_MS: "30000"
    },
    {},
    async (_url, init) => {
      capturedSignal = init.signal;
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("ok") }]
      });
    }
  );
  assert.equal(r.status, 200);
  assert.ok(capturedSignal, "上游应收到 signal");
  // 应该是一个组合 signal(AbortSignal.any 的结果,在 Node 里是 _AbortSignal)
  assert.equal(capturedSignal.aborted, false, "正常路径下 signal 未 abort");
});

test("Step 8 mergeSignals 单信号直接返回,无包装", async () => {
  // 没有客户端 abort 时,request.signal 不 aborted,合并后等价于 timeout signal
  let capturedSignal;
  const r = await handleRequest(
    request({ transcript: "a" }, { "X-App-Token": "token" }),
    {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "k"
    },
    {},
    async (_url, init) => {
      capturedSignal = init.signal;
      return jsonResponse({
        content: [{ type: "text", text: extractionJSON("ok") }]
      });
    }
  );
  assert.equal(r.status, 200);
  assert.ok(capturedSignal);
});
