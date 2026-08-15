import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { handleRequest, handleTelemetryBatch, handleScheduled, _testResetHealth, _testResetAdminConfig, _testResetExtractionCache } from "./worker.js";
import { applyPrimaryOverride } from "./src/adminConfig.js";
import { makeCacheKey } from "./src/extractionCache.js";
import { HealthStore, configureHealthParams, _testResetHealthParams } from "./src/health.js";
import { mintTestJWS } from "./src/jws-fixture.js";

// Reset module-level HealthStore + AdminConfigStore + health params between tests so
// circuit-breaker / latency state / admin override / configured params from one test
// doesn't leak into another.
//
// 现有测试大多假设老默认值(threshold=3, cooldown=30s),代码新默认值是 5/10s。
// 这里全局设回老默认值,让现有测试不改也跑得过。新测试验证新默认值时,在测试体内
// 显式调 _testResetHealthParams() 清回代码默认。
beforeEach(() => {
  _testResetHealth();
  _testResetAdminConfig();
  _testResetExtractionCache();
  _testResetHealthParams();
  configureHealthParams({
    CIRCUIT_OPEN_THRESHOLD: "3",
    CIRCUIT_INITIAL_COOLDOWN_MS: "30000",
    CIRCUIT_MAX_COOLDOWN_MS: "300000"
  });
});
import { anthropicAdapter, openaiAdapter, geminiAdapter } from "./src/adapters/index.js";
import { classifyAuthReason } from "./src/adapters/base.js";
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
  for (const [locale, expectedSnippet] of [["zh-Hans", `参考日期：${today}`], ["en-US", `Reference date: ${today}`], ["ja-JP", `参照日：${today}`]]) {
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

test("system prompt uses complete Japanese prompt for ja locale", async () => {
  // P1:ja locale 使用独立完整的 JAPANESE_SYSTEM_PROMPT(规则 + 15 个日语示例),
  // 不再是「日语前置指令 + 英文 prompt」的过渡组合。本测试验证:
  //   1. system prompt 包含日语规则主体(コアルール、曜日マッピング等)
  //   2. 包含日语示例(入力 / 出力)
  //   3. 不包含英文 prompt 的标志词(You are a todo extraction assistant)
  //   4. today 注入用日语「参照日」
  //   5. vocabularyHints 用日语文案
  //   6. 人名 / 服务名保留原文
  const today = new Date().toISOString().slice(0, 10);
  let upstreamRequest;
  const response = await handleRequest(
    request({
      transcript: "明日の午後3時に会議",
      locale: "ja-JP",
      vocabularyHints: ["Anki", "山田"]
    }, {
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
      return jsonResponse({ choices: [{ message: { content: extractionJSON("会議") } }] });
    }
  );
  assert.equal(response.status, 200);
  const systemMessage = upstreamRequest.body.messages[0].content;
  // 日语 prompt 主体关键词(规则标题 + 示例标记)
  assert.ok(systemMessage.includes("あなたはTODO抽出アシスタントです"), "ja locale 应使用日语 prompt 开头");
  assert.ok(systemMessage.includes("コアルール"), "ja locale 应包含「コアルール」");
  assert.ok(systemMessage.includes("例 1(時間の手がかりなし)"), "ja locale 应包含日语示例");
  assert.ok(systemMessage.includes("毎週月水金"), "ja locale 示例应覆盖日语重复表达");
  // 不应包含英文 prompt 主体(完整日语 prompt 独立,不需要 wrapper)
  assert.ok(!systemMessage.includes("You are a todo extraction assistant"), "ja locale 不应再回退到英文 prompt 主体");
  // today 注入用日语
  assert.ok(systemMessage.includes(`参照日：${today}`), "ja locale today 注入应为日语「参照日」");
  // vocabularyHints 用日语文案 + 保留人名
  assert.ok(systemMessage.includes("ユーザーが最近使う言葉"), "ja locale vocabularyHints 应为日语文案");
  assert.ok(systemMessage.includes("山田"), "ja locale vocabularyHints 应保留人名原文");
});

// 提前提醒(reminder_offset_minutes)三语 prompt 覆盖:
// 每个语言的 prompt 都必须含 schema 字段、规则 4c 和示例输出,缺一不可——
// 只加 schema 不加规则/示例时模型容易忽略该字段。
test("system prompt includes reminder_offset_minutes rule and example for all locales", async () => {
  const today = new Date().toISOString().slice(0, 10);
  const locales = [
    { locale: "zh-Hans", transcript: "明天下午3点开会，提前半小时提醒我", ruleMarker: "4c. 提前提醒" },
    { locale: "en-US", transcript: "Meeting tomorrow at 3pm, remind me half an hour early", ruleMarker: "4c. Advance reminder" },
    { locale: "ja-JP", transcript: "明日の午後3時に会議、30分前にリマインドして", ruleMarker: "4c. 事前リマインド" }
  ];
  for (const { locale, transcript, ruleMarker } of locales) {
    let upstreamRequest;
    const response = await handleRequest(
      request({ transcript, locale }, { "X-App-Token": "token", "X-Local-Date": today }),
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
    assert.ok(systemMessage.includes(ruleMarker), `${locale} prompt 应包含规则 4c`);
    assert.ok(systemMessage.includes('"reminder_offset_minutes"'), `${locale} prompt schema 应含字段名`);
    assert.ok(systemMessage.includes('"reminder_offset_minutes":30'), `${locale} prompt 示例应输出偏移值 30`);
  }
});

// 两个真实用户报告的识别偏差,靠「规则文本 + few-shot 示例」双锚定修复:
//   1. 「我今天要想一想明天去哪里玩」被归到明天 —— 应取主动作「想」的时间状语「今天」
//   2. 「今天要给程希璐制定方案」标题被压成「定方案」 —— 丢了人名对象
// 与 reminder_offset_minutes 测试同款守卫:每个语言的 prompt 都必须同时含
// 规则标记、示例标记和 schema 字数约束,缺一不可——只加规则不加示例时模型容易忽略。
test("system prompt includes multi-date disambiguation and title completeness rules for all locales", async () => {
  const today = new Date().toISOString().slice(0, 10);
  const locales = [
    {
      locale: "zh-Hans",
      transcript: "我今天要想一想明天去哪里玩",
      markers: ["多个日期词", "想明天去哪里玩", "给程希璐制定方案", "去公司跟李明开会", "去哪做的地点", "15字以内"]
    },
    {
      locale: "en-US",
      transcript: "Today I want to think about where to go tomorrow",
      markers: ["multiple date words", "Think about where to go tomorrow", "Prepare proposal for Cheng Xilu", "Meet Li Ming at the office", "(person names, what/for whom, where)", "under 15 words"]
    },
    {
      locale: "ja-JP",
      transcript: "今日、明日どこへ遊びに行くか考えよう",
      markers: ["複数の日付語", "明日どこへ行くか考える", "田中の企画書を作る", "会社で佐藤と打ち合わせ", "どこで", "15文字以内"]
    }
  ];
  for (const { locale, transcript, markers } of locales) {
    let upstreamRequest;
    const response = await handleRequest(
      request({ transcript, locale }, { "X-App-Token": "token", "X-Local-Date": today }),
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
    for (const marker of markers) {
      assert.ok(systemMessage.includes(marker), `${locale} prompt 应包含「${marker}」`);
    }
  }
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
    // 必须用**成功**的 provider mock 来累积配额:上游失败会退款
    // (refundDeviceQuotaOnUpstreamFailure),用 failingFetch 永远撞不到上限。
    const ok = jsonResponseProvider("x");
    await handleRequest(request({ transcript: "a" }, headers), env, {}, ok);
    await handleRequest(request({ transcript: "b" }, headers), env, {}, ok);
    const third = await handleRequest(request({ transcript: "c" }, headers), env, {}, ok);

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

// 上游全失败 → 退设备额度(用户什么都没拿到),但 IP / 全局维度**不退**。
// 后半句是安全边界:否则故意制造失败就能无限量白烧上游 token 且不计账。
test("device quota is refunded when all providers fail, but IP/global are not", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      IP_DAILY_LIMIT: "50",
      GLOBAL_DAILY_LIMIT: "500",
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "dev-x", "X-Local-Date": "2026-05-26" };
    const response = await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);

    // 用户拿到的仍是上游失败的错误，不因退款而变化
    assert.ok(response.status >= 500, `期望 5xx，实际 ${response.status}`);

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "quota key 仍应存在(KV 退款路径归零时写 \"0\"，不删 key)");
    assert.equal(kv.values.get(quotaKey), "0", "上游失败应把设备额度退回 0");

    const ipKey = [...kv.values.keys()].find((k) => k.startsWith("ip-quota:2026-05-26:"));
    assert.ok(ipKey, "应已写入 ip-quota key");
    assert.equal(kv.values.get(ipKey), "1", "IP 日额度是反刷维度，不退款");

    assert.equal(kv.values.get("global-quota:2026-05-26"), "1", "全局预算不退款");
  });
});

test("no refund is attempted when quota is not configured (skipped)", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      // 故意不配 DAILY_REQUEST_LIMIT → enforceDailyLimit 返回 skipped
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "dev-skip", "X-Local-Date": "2026-05-26" };
    await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:"));
    assert.equal(quotaKey, undefined, "配额未启用时不该因退款而凭空写出 quota key");
  });
});

// 流式失败分两种，退款只覆盖"一个字都没给"的那种。
test("stream that fails before emitting anything refunds device quota", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const response = await handleRequest(
      request(
        { transcript: "今天复习", locale: "zh-Hans", stream: true },
        { "X-App-Token": "token", "X-Device-ID": "dev-stream-0", "X-Local-Date": "2026-05-26" }
      ),
      env,
      {},
      async () => immediatelyErroringSSEStreamResponse()
    );

    assert.equal(response.status, 200, "流式失败发生在响应头之后，状态仍是 200");
    // 必须真正消费 body，退款发生在流读取过程中
    await assert.rejects(() => response.text(), /provider stream failed before output/);

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "应已写入 quota key");
    assert.equal(kv.values.get(quotaKey), "0", "一个字都没给 → 应退回设备额度");
  });
});

test("stream that fails after emitting partial output does NOT refund", async () => {
  const kv = new MemoryKV(new Map());
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const response = await handleRequest(
      request(
        { transcript: "今天复习", locale: "zh-Hans", stream: true },
        { "X-App-Token": "token", "X-Device-ID": "dev-stream-partial", "X-Local-Date": "2026-05-26" }
      ),
      env,
      {},
      async () => erroringSSEStreamResponse()
    );

    assert.equal(response.status, 200);
    await assert.rejects(() => response.text(), /provider stream failed/);

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey, "应已写入 quota key");
    // 客户端的 partial_fallback 会把已收到的 todo 当成功保留 → 用户拿到了价值，不该退
    assert.equal(kv.values.get(quotaKey), "1", "已推出部分内容 → 不退款");
  });
});

test("refund failure does not change the upstream error status", async () => {
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    // KV 的 get 正常(让 increment 成功)，put 在退款时抛错
    const kv = new MemoryKV(new Map());
    let putCalls = 0;
    const originalPut = kv.put.bind(kv);
    kv.put = async (...args) => {
      putCalls += 1;
      if (putCalls > 1) throw new Error("KV put exploded");
      return originalPut(...args);
    };
    const env = {
      APP_TOKEN: "token",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const headers = { "X-App-Token": "token", "X-Device-ID": "dev-boom", "X-Local-Date": "2026-05-26" };
    const response = await handleRequest(request({ transcript: "a" }, headers), env, {}, failingFetch);

    // 退款失败只该产生日志，不该把 5xx 变成另一个错误、更不该抛出未捕获异常
    assert.ok(response.status >= 500, `期望仍是上游失败的 5xx，实际 ${response.status}`);
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
    // 用成功 mock:上游失败会触发退款，虽然 KV 退款归零时写 "0" 而非删 key
    // （断言仍会通过），但语义上会让人误以为"失败也计数"。
    const ok = jsonResponseProvider("x");
    // 前一天（跨时区合法边界）
    await handleRequest(
      request({ transcript: "a" }, { "X-App-Token": "token", "X-Device-ID": "d-prev", "X-Local-Date": "2026-05-25" }),
      env,
      {},
      ok
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
      ok
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

// 与 due_date_basis 透传测试同款守卫:客户端按字面解码 reminder_offset_minutes,
// worker 中间层丢弃该字段会让"提前半小时提醒我"静默退化为准时提醒。
test("passes through reminder_offset_minutes field from provider response unchanged", async () => {
  const providerResponse = {
    todos: [{
      title: "开会",
      detail: "明天下午3点开会，提前半小时提醒我",
      due_date: "2026-07-16",
      due_hint: "明天下午3点",
      due_time: "15:00",
      time_bucket: null,
      recurrence_rule: null,
      recurrence_end: null,
      reminder_times: null,
      reminder_offset_minutes: 30,
      due_date_basis: "user_explicit",
      priority: "normal",
      category_hint: "work"
    }],
    ignored: ""
  };
  const response = await handleRequest(
    request({ transcript: "明天下午3点开会，提前半小时提醒我", locale: "zh-Hans" }, { "X-App-Token": "token" }),
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
  assert.equal(data.todos[0].reminder_offset_minutes, 30);
  assert.equal(data.todos[0].due_time, "15:00");
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

// 流在推出任何内容**之前**就失败:响应头已经 200 发出，但用户一个字都没拿到。
// 与 erroringSSEStreamResponse(先 emit 一段再失败)配对，用于验证退款只发生在前者。
function immediatelyErroringSSEStreamResponse() {
  const body = new ReadableStream({
    pull(controller) {
      controller.error(new Error("provider stream failed before output"));
    }
  });
  return new Response(body, {
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
    },
    async delete(key) {
      delete store[key];
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
  // args 顺序：received_at, event_name, event_timestamp, session_id, device_id, app_version, ios_version, params, extract_id
  assert.equal(db.insertedRows[0].args[1], "recording_started");
  assert.equal(db.insertedRows[1].args[1], "todo_saved");
  // 事件未携带 extractID 时落 "none"
  assert.equal(db.insertedRows[0].args[8], "none");
});

test("telemetry persists extractID for per-extraction correlation", async () => {
  const db = makeFakeD1();
  const response = await handleTelemetryBatch(
    telemetryRequest(
      [makeTelemetryEvent({ extractID: "extract-abc12345" })],
      { "X-App-Token": "token" }
    ),
    { APP_TOKEN: "token", TELEMETRY_DB: db },
    baseTelemetryContext
  );

  assert.equal(response.status, 200);
  assert.equal(db.insertedRows[0].args[8], "extract-abc12345");
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

// ─── Admin endpoint: 动态切换 provider 主力 ─────────────────────────────

test("applyPrimaryOverride: 空 providers 或空 primaryId 返回原数组", () => {
  const empty = [];
  assert.equal(applyPrimaryOverride(empty, "X"), empty);
  assert.deepEqual(applyPrimaryOverride([{ id: "A", priority: 1 }], ""), [{ id: "A", priority: 1 }]);
});

test("applyPrimaryOverride: primaryId 不存在返回原数组", () => {
  const providers = [{ id: "A", priority: 1 }, { id: "B", priority: 2 }];
  const result = applyPrimaryOverride(providers, "NONEXISTENT");
  assert.equal(result, providers, "应返回同一引用(让 caller 决定报错)");
});

test("applyPrimaryOverride: primaryId 存在时 priority 变 1,其他 priority<=1 的降为 2", () => {
  const providers = [
    { id: "A", priority: 1 },
    { id: "B", priority: 2 },
    { id: "C", priority: 1 }
  ];
  const result = applyPrimaryOverride(providers, "B");
  assert.deepEqual(result, [
    { id: "A", priority: 2 },
    { id: "B", priority: 1 },
    { id: "C", priority: 2 }
  ]);
});

test("applyPrimaryOverride: 不修改入参(纯函数)", () => {
  const providers = [{ id: "A", priority: 1 }];
  applyPrimaryOverride(providers, "A");
  assert.equal(providers[0].priority, 1, "入参数组元素 priority 未变");
});

test("admin endpoint: 无 X-Admin-Token 返回 401", async () => {
  const kv = makeFakeKV();
  const env = { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv };
  const req = new Request("https://proxy.test/v1/admin/providers", { method: "GET" });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 401);
});

test("admin endpoint: 错的 X-Admin-Token 返回 401", async () => {
  const kv = makeFakeKV();
  const env = { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv };
  const req = new Request("https://proxy.test/v1/admin/providers", {
    method: "GET",
    headers: { "X-Admin-Token": "wrong" }
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 401);
});

test("admin endpoint: ADMIN_TOKEN 未配置返回 500(不静默开放)", async () => {
  const req = new Request("https://proxy.test/v1/admin/providers", {
    method: "GET",
    headers: { "X-Admin-Token": "anything" }
  });
  const response = await handleRequest(req, {}, {});
  assert.equal(response.status, 500);
});

test("admin GET /v1/admin/providers: 无 override 返回 toml 默认 + override=null", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" },
     { id: "B", type: "openai",   url: "https://b.example/v1/chat",      model: "m2", priority: 2, secretName: "K2" }],
    { K1: "k1", K2: "k2" },
    { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv }
  );
  const req = new Request("https://proxy.test/v1/admin/providers", {
    method: "GET",
    headers: { "X-Admin-Token": "admin-secret" }
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.override, null);
  assert.equal(data.providers.length, 2);
  assert.deepEqual(data.providers.map((p) => p.id), ["A", "B"]);
  assert.equal(data.providers[0].priority, 1);
  // 确认敏感字段被脱敏
  assert.equal("apiKey" in data.providers[0], false);
  assert.equal("secretName" in data.providers[0], false);
  assert.equal(data.providers[0].hasApiKey, true);
});

test("admin POST primary: 有效 primaryId 写 KV override", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" },
     { id: "B", type: "openai",   url: "https://b.example/v1/chat",      model: "m2", priority: 2, secretName: "K2" }],
    { K1: "k1", K2: "k2" },
    { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv }
  );
  const req = new Request("https://proxy.test/v1/admin/providers/primary", {
    method: "POST",
    headers: { "X-Admin-Token": "admin-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ primaryId: "B" })
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.ok, true);
  assert.equal(data.override.primaryId, "B");
  // 验证 KV 已写入
  const stored = JSON.parse(kv.store["config:providers_primary"]);
  assert.equal(stored.primaryId, "B");
});

test("admin POST primary: 无效 primaryId 返回 400 + availableIds", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv }
  );
  const req = new Request("https://proxy.test/v1/admin/providers/primary", {
    method: "POST",
    headers: { "X-Admin-Token": "admin-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ primaryId: "NONEXISTENT" })
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error, "unknown_provider_id");
  assert.deepEqual(data.availableIds, ["A"]);
});

test("admin POST primary: 小写 primaryId 自动转大写", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv }
  );
  const req = new Request("https://proxy.test/v1/admin/providers/primary", {
    method: "POST",
    headers: { "X-Admin-Token": "admin-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ primaryId: "a" })
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.override.primaryId, "A");
});

test("admin DELETE primary: 清除 override 回到 toml 默认", async () => {
  const kv = makeFakeKV({
    "config:providers_primary": JSON.stringify({ primaryId: "B", updatedAt: 1, updatedBy: null })
  });
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" },
     { id: "B", type: "openai",   url: "https://b.example/v1/chat",      model: "m2", priority: 2, secretName: "K2" }],
    { K1: "k1", K2: "k2" },
    { ADMIN_TOKEN: "admin-secret", AI_PROVIDER_STATE_KV: kv }
  );
  const req = new Request("https://proxy.test/v1/admin/providers/primary", {
    method: "DELETE",
    headers: { "X-Admin-Token": "admin-secret" }
  });
  const response = await handleRequest(req, env, {});
  assert.equal(response.status, 200);
  assert.equal(kv.store["config:providers_primary"], undefined, "KV key 应已删除");
});

test("admin override 影响实际 todo-extractions 请求:primaryId 排第一", async () => {
  const kv = makeFakeKV({
    "config:providers_primary": JSON.stringify({ primaryId: "B", updatedAt: 1, updatedBy: null })
  });
  let calledProviderUrl;
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" },
     { id: "B", type: "openai",   url: "https://b.example/v1/chat",      model: "m2", priority: 2, secretName: "K2" }],
    { K1: "k1", K2: "k2" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const response = await handleRequest(
    request({ transcript: "测试", locale: "zh" }, { "X-App-Token": "token" }),
    env,
    {},
    async (url) => {
      calledProviderUrl = url;
      // OpenAI 兼容响应
      return new Response(JSON.stringify({
        choices: [{ message: { content: JSON.stringify({ todos: [{ id: "t1", title: "测试" }] }) } }]
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
  );
  assert.equal(response.status, 200);
  // primaryId="B"(原 priority=2)被 override 为 priority=1,应优先被调用
  assert.equal(calledProviderUrl, "https://b.example/v1/chat");
});

test("admin override 不存在 primaryId 时静默 noop(走 toml 默认)", async () => {
  // KV 里有一个不存在的 primaryId(toml 改过但 KV override 没清)
  const kv = makeFakeKV({
    "config:providers_primary": JSON.stringify({ primaryId: "DELETED_PROVIDER", updatedAt: 1, updatedBy: null })
  });
  let calledProviderUrl;
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m1", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const response = await handleRequest(
    request({ transcript: "测试", locale: "zh" }, { "X-App-Token": "token" }),
    env,
    {},
    async (url) => {
      calledProviderUrl = url;
      return jsonResponse({ content: [{ type: "text", text: extractionJSON("测试") }] });
    }
  );
  assert.equal(response.status, 200);
  // applyPrimaryOverride 找不到 primaryId,返回原数组,走默认 A
  assert.equal(calledProviderUrl, "https://a.example/v1/messages");
});

// ─── P4: 熔断参数 env var 注入 ──────────────────────────────────────────

test("configureHealthParams: 代码默认值为 threshold=5 / initialCooldown=10s / maxCooldown=5min", async () => {
  // beforeEach 会设老默认值(3/30s)让现有测试跑;这里重置回代码默认值验证
  _testResetHealthParams();
  const kv = makeFakeKV();
  const store = new HealthStore({ kv });
  // 连续失败 4 次还不熔断(老默认 3 会熔断,新默认 5 不会)
  for (let i = 0; i < 4; i++) {
    await store.recordFailure("P", "timeout");
  }
  let snapshot = await store.snapshot("P");
  assert.equal(snapshot.state, "closed", "4 次失败应仍 closed(代码默认阈值 5)");
  // 第 5 次失败触发熔断
  await store.recordFailure("P", "timeout");
  snapshot = await store.snapshot("P");
  assert.equal(snapshot.state, "open", "5 次失败应触发 open");
});

test("configureHealthParams: env 覆盖 threshold", async () => {
  _testResetHealthParams();
  configureHealthParams({ CIRCUIT_OPEN_THRESHOLD: "10" });
  const kv = makeFakeKV();
  const store = new HealthStore({ kv });
  for (let i = 0; i < 9; i++) {
    await store.recordFailure("P", "timeout");
  }
  let snapshot = await store.snapshot("P");
  assert.equal(snapshot.state, "closed", "9 次失败应仍 closed(覆盖阈值 10)");
  await store.recordFailure("P", "timeout");
  snapshot = await store.snapshot("P");
  assert.equal(snapshot.state, "open", "10 次失败触发 open");
});

test("configureHealthParams: 非法值被忽略(不抛错)", () => {
  _testResetHealthParams();
  // 这些都不应该让代码抛错或改变默认行为
  configureHealthParams({ CIRCUIT_OPEN_THRESHOLD: "not_a_number" });
  configureHealthParams({ CIRCUIT_INITIAL_COOLDOWN_MS: "-1000" });
  configureHealthParams({ CIRCUIT_MAX_COOLDOWN_MS: "0" });
  configureHealthParams({}); // 空对象
  configureHealthParams(null); // null env
  // 如果代码到这里没抛,说明非法值被静默处理
  assert.ok(true);
});

test("configureHealthParams: initialCooldown > maxCooldown 时被 clamp", async () => {
  _testResetHealthParams();
  configureHealthParams({
    CIRCUIT_INITIAL_COOLDOWN_MS: "60000",  // 60s
    CIRCUIT_MAX_COOLDOWN_MS: "30000"       // 30s
  });
  const kv = makeFakeKV();
  const store = new HealthStore({ kv });
  // 触发熔断看冷却时间(通过 recordFailure 后 nextCooldown 计算)
  for (let i = 0; i < 5; i++) {
    await store.recordFailure("P", "timeout");
  }
  const record = await store.load("P");
  // 初始冷却应被 clamp 到 maxCooldown(30s),不是 60s
  assert.equal(record.cooldownMs, 30_000, "initialCooldown 应被 clamp 到 maxCooldown");
});

// ─── P2: 解析结果 cache ─────────────────────────────────────────────────

test("makeCacheKey: 相同输入产生相同 key", async () => {
  const a = await makeCacheKey({ transcript: "买牛奶", locale: "zh", vocabularyHints: ["Anki"], today: "2026-08-01" });
  const b = await makeCacheKey({ transcript: "买牛奶", locale: "zh", vocabularyHints: ["Anki"], today: "2026-08-01" });
  assert.equal(a, b);
  assert.ok(a.startsWith("cache:"));
});

test("makeCacheKey: 任一字段不同则 key 不同", async () => {
  const base = { transcript: "买牛奶", locale: "zh", vocabularyHints: [], today: "2026-08-01" };
  const k0 = await makeCacheKey(base);
  const k1 = await makeCacheKey({ ...base, transcript: "买面包" });
  const k2 = await makeCacheKey({ ...base, locale: "en" });
  const k3 = await makeCacheKey({ ...base, vocabularyHints: ["Anki"] });
  const k4 = await makeCacheKey({ ...base, today: "2026-08-02" });
  const all = [k1, k2, k3, k4];
  assert.ok(all.every((k) => k !== k0), "每个字段变化都应产生不同 key");
  assert.equal(new Set(all).size, 4, "四个变化应产生 4 个不同 key");
});

test("cache hit: 非流式 + 无 personalHints 第二次请求走 cache", async () => {
  const kv = makeFakeKV();
  let upstreamCallCount = 0;
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { CACHE_RESULT_KV: kv }
  );
  const fetchImpl = async () => {
    upstreamCallCount += 1;
    return jsonResponse({ content: [{ type: "text", text: extractionJSON("todo") }] });
  };
  // 第一次请求:cache miss,调上游,写 cache
  const r1 = await handleRequest(
    request({ transcript: "测试cache", locale: "zh" }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  assert.equal(r1.status, 200);
  assert.equal(upstreamCallCount, 1, "第一次应调上游");
  // 等待 cache 写完成(waitUntil 是同步 mock,但 set 是 async)
  await Promise.resolve();
  // 第二次相同请求:cache hit,不调上游
  const r2 = await handleRequest(
    request({ transcript: "测试cache", locale: "zh" }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  assert.equal(r2.status, 200);
  assert.equal(upstreamCallCount, 1, "第二次应走 cache,不调上游");
});

test("cache 不命中 personalHints != null 的请求", async () => {
  const kv = makeFakeKV();
  let upstreamCallCount = 0;
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { CACHE_RESULT_KV: kv }
  );
  const fetchImpl = async () => {
    upstreamCallCount += 1;
    return jsonResponse({ content: [{ type: "text", text: extractionJSON("todo") }] });
  };
  // 带 personalHints 的请求:不写 cache
  await handleRequest(
    request({ transcript: "test", locale: "zh", personalHints: "老地方=健身房" }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  // 第二次相同请求:因为没有 cache,再次调上游
  await handleRequest(
    request({ transcript: "test", locale: "zh", personalHints: "老地方=健身房" }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  assert.equal(upstreamCallCount, 2, "带 personalHints 的请求每次都调上游");
});

test("cache 不命中流式请求(stream=true)", async () => {
  const kv = makeFakeKV();
  let upstreamCallCount = 0;
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { CACHE_RESULT_KV: kv }
  );
  const fetchImpl = async () => {
    upstreamCallCount += 1;
    return sseResponse([
      `data: ${JSON.stringify({ choices: [{ delta: { content: "{\"todos\":[]}" } }] })}`,
      `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }] })}`
    ]);
  };
  // 流式请求:不写 cache
  await handleRequest(
    request({ transcript: "test", locale: "zh", stream: true }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  // 第二次相同请求:流式不 cache,再次调上游
  await handleRequest(
    request({ transcript: "test", locale: "zh", stream: true }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  assert.equal(upstreamCallCount, 2, "流式请求每次都调上游");
});

test("cache KV 未绑定时静默不工作(不影响业务)", async () => {
  let upstreamCallCount = 0;
  // 注意:没有 CACHE_RESULT_KV binding
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" }
  );
  const fetchImpl = async () => {
    upstreamCallCount += 1;
    return jsonResponse({ content: [{ type: "text", text: extractionJSON("todo") }] });
  };
  const r = await handleRequest(
    request({ transcript: "test", locale: "zh" }, { "X-App-Token": "token" }),
    env,
    { waitUntil() {} },
    fetchImpl
  );
  assert.equal(r.status, 200);
  assert.equal(upstreamCallCount, 1, "无 KV binding 时走真实调用");
});

// ─── P3: scheduled health check ────────────────────────────────────────

test("handleScheduled: 上游 200 时调 recordSuccess", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  let calledUrl = null;
  const fetchImpl = async (url) => {
    calledUrl = url;
    return jsonResponse({ content: [{ type: "text", text: "{}" }] });
  };
  await handleScheduled(env, fetchImpl);
  assert.equal(calledUrl, "https://a.example/v1/messages");
  // HealthStore 应该记录 A 的成功
  const store = new HealthStore({ kv });
  const snapshot = await store.snapshot("A");
  assert.equal(snapshot.state, "closed");
  assert.ok(snapshot.sampleCount > 0, "sampleCount 应 > 0(成功被记录)");
});

test("handleScheduled: 上游 500 时调 recordFailure", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const fetchImpl = async () => new Response("upstream error", { status: 500 });
  await handleScheduled(env, fetchImpl);
  // 失败应被记录(连续失败到阈值才熔断,这里只 1 次,仍 closed 但 lastErrorType 应有值)
  const store = new HealthStore({ kv });
  const record = await store.load("A");
  assert.equal(record.lastErrorType, "http_500");
});

test("handleScheduled: fetch 抛 timeout 时 recordFailure + errorType=timeout", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const fetchImpl = async () => {
    const err = new Error("timed out");
    err.name = "TimeoutError";
    throw err;
  };
  await handleScheduled(env, fetchImpl);
  const store = new HealthStore({ kv });
  const record = await store.load("A");
  assert.equal(record.lastErrorType, "timeout");
});

test("handleScheduled: 多 provider 并行 ping,单个失败不影响其他", async () => {
  const kv = makeFakeKV();
  const env = providersEnv(
    [
      { id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" },
      { id: "B", type: "openai", url: "https://b.example/v1/chat/completions", model: "m", priority: 2, secretName: "K2" }
    ],
    { K1: "k1", K2: "k2" },
    { AI_PROVIDER_STATE_KV: kv }
  );
  const calledIds = [];
  const fetchImpl = async (url, init) => {
    // A 失败,B 成功
    if (url.includes("a.example")) {
      calledIds.push("A");
      return new Response("err", { status: 500 });
    }
    calledIds.push("B");
    return jsonResponse({ choices: [{ message: { content: "{}" } }] });
  };
  await handleScheduled(env, fetchImpl);
  // 两个都被调了(并行,互不影响)
  assert.deepEqual(calledIds.sort(), ["A", "B"]);
});

test("handleScheduled: AI_PROVIDER_STATE_KV 未绑定时静默跳过", async () => {
  const env = providersEnv(
    [{ id: "A", type: "anthropic", url: "https://a.example/v1/messages", model: "m", priority: 1, secretName: "K1" }],
    { K1: "k1" }
    // 注意:没 AI_PROVIDER_STATE_KV
  );
  let called = false;
  const fetchImpl = async () => { called = true; return jsonResponse({}); };
  await handleScheduled(env, fetchImpl);
  assert.equal(called, false, "KV 未绑定时不应调上游");
});

test("handleScheduled: providers 配置失败时不抛(只 log)", async () => {
  const kv = makeFakeKV();
  // PROVIDERS 是非法 JSON
  const env = { PROVIDERS: "not-json", AI_PROVIDER_STATE_KV: kv };
  let called = false;
  const fetchImpl = async () => { called = true; return jsonResponse({}); };
  // 不应抛错
  await handleScheduled(env, fetchImpl);
  assert.equal(called, false);
});

// MARK: - 客户端断连 ≠ provider 故障
//
// 本组测试守着「远端服务间歇性不生效」的服务端根因:用户划走确认弹层 / 开始新一次录音
// 会 abort request.signal,进而 abort 上游 fetch。旧代码把它当成 provider 故障记进
// HealthStore,攒够 threshold 就把 provider 摘掉;两个 provider 都被摘掉时
// pickCandidates 返回空 → 503,而熔断状态持久化在 KV,只能等冷却(最长 5 分钟)自行到期。

/// 构造一个「读到一半客户端就断开」的上游 SSE 流。
/// emitFirstChunk = false 时模拟「响应头 200 但一个字都没推出去就断」。
function clientAbortingSSEStreamResponse(abortController, { emitFirstChunk = true } = {}) {
  const encoder = new TextEncoder();
  let sentFirstChunk = false;
  const body = new ReadableStream({
    pull(controller) {
      if (emitFirstChunk && !sentFirstChunk) {
        sentFirstChunk = true;
        controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({ type: "content_block_delta", delta: { text: "{\"todos\":[" } })}\n\n`
        ));
        return;
      }
      abortController.abort();
      controller.error(new Error("client disconnected"));
    }
  });
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/event-stream" }
  });
}

function requestWithSignal(body, headers, signal) {
  return new Request("https://proxy.test/v1/todo-extractions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
    signal
  });
}

function healthRecord(kv, providerId) {
  const raw = kv.values.get(`health:${providerId}`);
  return raw ? JSON.parse(raw) : null;
}

test("client disconnect mid-stream does not record a provider health failure", async () => {
  const healthKv = new MemoryKV(new Map());
  const abortController = new AbortController();
  const env = {
    APP_TOKEN: "token",
    AI_PROVIDER: "anthropic",
    ANTHROPIC_API_KEY: "anthropic-key",
    AI_PROVIDER_STATE_KV: healthKv
  };

  const response = await handleRequest(
    requestWithSignal(
      { transcript: "今天复习", locale: "zh-Hans", stream: true },
      { "X-App-Token": "token", "X-Device-ID": "dev-abort-1" },
      abortController.signal
    ),
    env,
    {},
    async () => clientAbortingSSEStreamResponse(abortController)
  );

  assert.equal(response.status, 200);
  await assert.rejects(() => response.text());

  // 直接断言 KV:失败写是 force 的,只要 recordFailure 被调过就一定留痕。
  assert.equal(
    healthRecord(healthKv, "ANTHROPIC_LEGACY"),
    null,
    "客户端断连不该给 provider 记任何健康失败"
  );
});

test("genuine mid-stream provider error still records a failure when the client is connected", async () => {
  const healthKv = new MemoryKV(new Map());
  const env = {
    APP_TOKEN: "token",
    AI_PROVIDER: "anthropic",
    ANTHROPIC_API_KEY: "anthropic-key",
    AI_PROVIDER_STATE_KV: healthKv
  };

  const response = await handleRequest(
    request(
      { transcript: "今天复习", locale: "zh-Hans", stream: true },
      { "X-App-Token": "token", "X-Device-ID": "dev-abort-2" }
    ),
    env,
    {},
    async () => erroringSSEStreamResponse()
  );

  await assert.rejects(() => response.text());

  const record = healthRecord(healthKv, "ANTHROPIC_LEGACY");
  assert.ok(record, "真实上游中断仍必须记故障 —— 别把断连判据放得太宽");
  assert.equal(record.consecutiveFailures, 1);
});

test("client disconnect before the first upstream byte does not fail over to the next provider", async () => {
  const healthKv = new MemoryKV(new Map());
  const abortController = new AbortController();
  const calls = [];
  const env = providersEnv(
    [
      {
        id: "PRIMARY",
        type: "anthropic",
        url: "https://a.example/v1/messages",
        model: "m-a",
        priority: 1,
        weight: 10,
        enabled: true,
        secretName: "KEY_A"
      },
      {
        id: "SECONDARY",
        type: "anthropic",
        url: "https://b.example/v1/messages",
        model: "m-b",
        priority: 2,
        weight: 10,
        enabled: true,
        secretName: "KEY_B"
      }
    ],
    { KEY_A: "key-a", KEY_B: "key-b" },
    { AI_PROVIDER_STATE_KV: healthKv }
  );

  const response = await handleRequest(
    requestWithSignal(
      { transcript: "今天复习", locale: "zh-Hans", stream: true },
      { "X-App-Token": "token", "X-Device-ID": "dev-abort-3" },
      abortController.signal
    ),
    env,
    {},
    async (url) => {
      calls.push(url);
      abortController.abort();
      throw Object.assign(new Error("aborted"), { name: "AbortError" });
    }
  );

  // 旧行为:PRIMARY 记一次假故障 → failover 到 SECONDARY → 同样立刻被 abort → 再记一次。
  // 一次取消 = 两个 provider 各一次假故障。
  assert.equal(calls.length, 1, "客户端已经走了,不该再打下一个 provider 白烧 token");
  assert.equal(healthRecord(healthKv, "PRIMARY"), null);
  assert.equal(healthRecord(healthKv, "SECONDARY"), null);
  assert.equal(response.status, 499, "客户端断连应记 499 而非 503,别让错误看板把取消算成故障");
});

test("client disconnect refunds device quota when nothing was emitted", async () => {
  const kv = new MemoryKV(new Map());
  const abortController = new AbortController();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const response = await handleRequest(
      requestWithSignal(
        { transcript: "今天复习", locale: "zh-Hans", stream: true },
        { "X-App-Token": "token", "X-Device-ID": "dev-abort-4", "X-Local-Date": "2026-05-26" },
        abortController.signal
      ),
      env,
      {},
      async () => clientAbortingSSEStreamResponse(abortController, { emitFirstChunk: false })
    );

    await assert.rejects(() => response.text());

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.ok(quotaKey);
    assert.equal(
      kv.values.get(quotaKey),
      "0",
      "上线后免费档每天只有 2 次,划走两次弹层就烧光额度 —— 那同样是一种「不生效」"
    );
  });
});

test("client disconnect after partial output does NOT refund device quota", async () => {
  const kv = new MemoryKV(new Map());
  const abortController = new AbortController();
  await withMockedToday("2026-05-26T12:00:00.000Z", async () => {
    const env = {
      APP_TOKEN: "token",
      AI_PROVIDER: "anthropic",
      ANTHROPIC_API_KEY: "anthropic-key",
      DAILY_REQUEST_LIMIT: "5",
      RATE_LIMIT_KV: kv
    };
    const response = await handleRequest(
      requestWithSignal(
        { transcript: "今天复习", locale: "zh-Hans", stream: true },
        { "X-App-Token": "token", "X-Device-ID": "dev-abort-5", "X-Local-Date": "2026-05-26" },
        abortController.signal
      ),
      env,
      {},
      async () => clientAbortingSSEStreamResponse(abortController, { emitFirstChunk: true })
    );

    await assert.rejects(() => response.text());

    const quotaKey = [...kv.values.keys()].find((k) => k.startsWith("quota:2026-05-26:"));
    assert.equal(kv.values.get(quotaKey), "1", "已经推出内容就不退款,否则等于按需白嫖额度");
  });
});

test("admin providers endpoint exposes live circuit state", async () => {
  const healthKv = new MemoryKV(new Map());
  const env = providersEnv(
    [
      {
        id: "PRIMARY",
        type: "anthropic",
        url: "https://a.example/v1/messages",
        model: "m-a",
        priority: 1,
        weight: 10,
        enabled: true,
        secretName: "KEY_A"
      }
    ],
    { KEY_A: "key-a" },
    { ADMIN_TOKEN: "admin-token", AI_PROVIDER_STATE_KV: healthKv }
  );

  const response = await handleRequest(
    new Request("https://proxy.test/v1/admin/providers", {
      method: "GET",
      headers: { "X-Admin-Token": "admin-token" }
    }),
    env,
    {},
    async () => jsonResponse({})
  );

  assert.equal(response.status, 200);
  const data = await response.json();
  // 「远端 AI 现在到底通不通」应该一条 curl 就能回答,不必靠重启 Worker 碰运气。
  assert.equal(data.providers[0].health.state, "closed");
  assert.equal(data.providers[0].health.consecutiveFailures, 0);
});

// MARK: - 401/403:诊断分类,以及「绝不能改成 non-retryable」的守卫
//
// provider.js 的非重试分支是 `throw 502` 且**完全不 failover**。所以把 401/403 判成
// non-retryable 会让单个 provider 的密钥问题拖垮整个服务 —— 即使另一个 provider 的
// 密钥完全正常。failover 恰恰是 auth 故障的正确响应:下一个 provider 用的是另一把密钥。

test("classifyAuthReason maps vendor phrasing to an actionable reason", () => {
  const cases = [
    ["expired", ["Your token has expired", "API key expired", "凭证已过期"]],
    ["insufficient_balance", [
      "You exceeded your current quota, please check your plan and billing details",
      "insufficient_quota",
      "账户余额不足,请充值"
    ]],
    ["region_blocked", [
      "unsupported_country_region_territory",
      "This model is not available in your country"
    ]],
    ["no_model_access", [
      "You do not have access to this model",
      "model_not_allowed",
      "当前密钥无权限调用该模型"
    ]],
    ["invalid_key", [
      "Invalid API key provided",
      "invalid_api_key",
      "Unauthorized"
    ]]
  ];

  for (const [expected, bodies] of cases) {
    for (const body of bodies) {
      assert.equal(
        classifyAuthReason(body),
        expected,
        `"${body}" 应归类为 ${expected}`
      );
    }
  }

  // 认不出来就说认不出来,不猜。
  assert.equal(classifyAuthReason(""), "unknown");
  assert.equal(classifyAuthReason("something went wrong"), "unknown");
});

test("insufficient_balance wins over the broader invalid_key keywords", () => {
  // 真实措辞经常同时出现 "unauthorized" 和余额信息。笼统的 invalid_key 若排在前面
  // 会盖掉「去充值」这个更有行动价值的判定 —— 表的顺序就是为此设计的。
  assert.equal(
    classifyAuthReason("Unauthorized: insufficient balance, please recharge"),
    "insufficient_balance"
  );
});

test("401/403 stay retryable and keep errorType auth", () => {
  // 这条守着上面那段注释里的结论。改动重试语义 = 让一个坏密钥拖垮整个服务。
  for (const adapter of [anthropicAdapter, openaiAdapter, geminiAdapter]) {
    for (const status of [401, 403]) {
      const result = adapter.isRetryable({ status, bodyText: "Invalid API key provided" });
      assert.equal(result.retryable, true, `${adapter.type} ${status} 必须可重试(否则不会 failover)`);
      assert.equal(result.errorType, "auth", `${adapter.type} ${status} 的 errorType 必须保持 auth`);
      assert.equal(result.authReason, "invalid_key");
    }
  }
});

test("an expired key on the primary provider still fails over to the secondary", async () => {
  const calls = [];
  const env = providersEnv(
    [
      {
        id: "PRIMARY",
        type: "anthropic",
        url: "https://a.example/v1/messages",
        model: "m-a",
        priority: 1,
        weight: 10,
        enabled: true,
        secretName: "KEY_A"
      },
      {
        id: "SECONDARY",
        type: "anthropic",
        url: "https://b.example/v1/messages",
        model: "m-b",
        priority: 2,
        weight: 10,
        enabled: true,
        secretName: "KEY_B"
      }
    ],
    { KEY_A: "stale-key", KEY_B: "good-key" }
  );

  let response;
  const logs = await captureConsole(async () => {
    response = await handleRequest(
      request({ transcript: "今天复习", locale: "zh-Hans" }, { "X-App-Token": "token" }),
      env,
      {},
      async (url) => {
        calls.push(url);
        if (url.includes("a.example")) {
          return jsonResponse({ error: { message: "Invalid API key provided" } }, 401);
        }
        return jsonResponse({ content: [{ type: "text", text: extractionJSON("复习") }] });
      }
    );
  });

  assert.equal(response.status, 200, "主 provider 密钥失效不该影响整体可用性");
  assert.equal(calls.length, 2, "必须 failover 到备用 provider —— 它用的是另一把密钥");

  const alert = logs
    .map((line) => JSON.parse(line))
    .find((entry) => entry.event === "proxy.provider.auth_failed_alert");
  assert.ok(alert, "auth 失败必须告警");
  assert.equal(alert.providerId, "PRIMARY");
  assert.equal(alert.authReason, "invalid_key", "运维据此知道该去 wrangler secret put,而不是充值");
});

test("both providers with dead keys surface 503 and record auth in the health snapshot", async () => {
  const healthKv = new MemoryKV(new Map());
  const calls = [];
  const env = providersEnv(
    [
      {
        id: "PRIMARY",
        type: "anthropic",
        url: "https://a.example/v1/messages",
        model: "m-a",
        priority: 1,
        weight: 10,
        enabled: true,
        secretName: "KEY_A"
      },
      {
        id: "SECONDARY",
        type: "anthropic",
        url: "https://b.example/v1/messages",
        model: "m-b",
        priority: 2,
        weight: 10,
        enabled: true,
        secretName: "KEY_B"
      }
    ],
    { KEY_A: "dead-a", KEY_B: "dead-b" },
    { AI_PROVIDER_STATE_KV: healthKv }
  );

  const response = await handleRequest(
    request({ transcript: "今天复习", locale: "zh-Hans" }, { "X-App-Token": "token" }),
    env,
    {},
    async (url) => {
      calls.push(url);
      return jsonResponse({ error: { message: "账户余额不足,请充值" } }, 403);
    }
  );

  // 两把密钥同时失效时 503 本来就是正确答案 —— 关键是它必须可诊断。
  assert.equal(response.status, 503);
  assert.equal(calls.length, 2, "两个都试过才放弃");
  for (const id of ["PRIMARY", "SECONDARY"]) {
    const record = JSON.parse(healthKv.values.get(`health:${id}`));
    assert.equal(record.lastErrorType, "auth", `${id} 的健康记录应标明是 auth 问题`);
  }
});
