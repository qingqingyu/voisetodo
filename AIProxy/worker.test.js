import assert from "node:assert/strict";
import test from "node:test";
import { handleRequest, handleTelemetryBatch, handleScheduled } from "./worker.js";

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

test("enforces optional daily quota by device id", async () => {
  const kv = new MemoryKV(new Map([["quota:2026-05-26:device-1", "1"]]));
  const originalDate = globalThis.Date;
  globalThis.Date = class extends originalDate {
    constructor(...args) {
      return args.length === 0 ? new originalDate("2026-05-26T12:00:00Z") : new originalDate(...args);
    }
    static now() {
      return new originalDate("2026-05-26T12:00:00Z").getTime();
    }
  };

  try {
    const response = await handleRequest(
      request({ transcript: "买菜" }, { "X-App-Token": "token", "X-Device-ID": "device-1" }),
      {
        APP_TOKEN: "token",
        ANTHROPIC_API_KEY: "anthropic-key",
        DAILY_REQUEST_LIMIT: "1",
        RATE_LIMIT_KV: kv
      },
      {},
      failingFetch
    );

    assert.equal(response.status, 429);
  } finally {
    globalThis.Date = originalDate;
  }
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
      due_hint: null,
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

  async get(key) {
    return this.values.get(key) || null;
  }

  async put(key, value) {
    this.values.set(key, value);
  }
}
