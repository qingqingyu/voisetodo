import assert from "node:assert/strict";
import test from "node:test";
import { handleRequest } from "./worker.js";

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
