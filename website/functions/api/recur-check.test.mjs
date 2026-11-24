// recur-check.js 单测:工具页②改走代理 web 档(2026-11-24)后的表单处理。
// 覆盖:成功渲染重复规则 + 未来五次、无重复的诚实页、两档 429、全局预算 503、
// 上游错误、坏响应、缺配置、tz auto 解析、访客断连日志口径。
// 跑法:cd website && npm run test:functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { onRequestPost } from './recur-check.js';
import { todayInZone } from '../lib/timezones.mjs';

const TOOL_URL = 'https://site.test/tools/recurring-reminder-checker';
const UPSTREAM_URL = 'https://proxy.test/v1/web/todo-extractions';

// 与 split.test.mjs 同构的截获骨架:替换全局 fetch + 静音并截获 console。
async function withMockedUpstream({ body, cf, visitorSignal, upstreamImpl }, fn) {
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const originalWarn = console.warn;
  const originalError = console.error;
  const calls = [];
  const logs = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return upstreamImpl(url, init);
  };
  console.log = (...args) => logs.push(['log', ...args]);
  console.warn = (...args) => logs.push(['warn', ...args]);
  console.error = (...args) => logs.push(['error', ...args]);
  try {
    const request = new Request(TOOL_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'CF-Connecting-IP': '203.0.113.7',
      },
      body: new URLSearchParams(body),
      signal: visitorSignal,
    });
    if (cf) request.cf = cf;
    const context = { request, env: { AI_PROXY_ORIGIN: 'https://proxy.test', WEB_EXTRACT_TOKEN: 'web-token' } };
    return await fn(context, calls, logs);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    console.warn = originalWarn;
    console.error = originalError;
  }
}

const jsonUpstream = (payload, status = 200, headers = {}) =>
  new Response(JSON.stringify(payload), { status, headers: { 'Content-Type': 'application/json', ...headers } });

const weeklyRuleBody = {
  todos: [{
    title: '去健身房',
    due_date: null,
    due_time: '20:00',
    time_bucket: null,
    recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [2, 4, 6], day_of_month: null, end_date: null },
    due_date_basis: null,
  }],
  ignored: '',
};

test('recur-check: 有重复规则时渲染规则描述与未来五次', async () => {
  await withMockedUpstream(
    { body: { phrase: '每周一三五晚上8点去健身房', tz: 'UTC' }, upstreamImpl: () => jsonUpstream(weeklyRuleBody) },
    async (context, calls) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      assert.equal(calls.length, 1);
      assert.equal(calls[0].url, UPSTREAM_URL);
      assert.equal(calls[0].init.headers.get('X-Web-Token'), 'web-token');
      assert.equal(calls[0].init.headers.get('X-Web-Client-IP'), '203.0.113.7');
      assert.equal(calls[0].init.headers.get('X-Local-Date'), todayInZone('UTC'));
      assert.deepEqual(JSON.parse(calls[0].init.body), { transcript: '每周一三五晚上8点去健身房', locale: 'zh' });
      const html = await response.text();
      assert.match(html, /Every Monday, Wednesday and Friday/);
      assert.match(html, /VoiceTodo understands this as:/);
      // 周一周三周五:未来五次的 <li> 恰好 5 个
      assert.equal((html.match(/<li>/g) || []).length, 5);
      // 本地解析器不该再被用于展示:结果页不出现它的「deterministic set」字样
      assert.doesNotMatch(html, /deterministic set/);
    }
  );
});

test('recur-check: tz=auto 用 request.cf.timezone 算 X-Local-Date', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'gym every monday', tz: 'auto' },
      cf: { timezone: 'America/New_York' },
      upstreamImpl: () => jsonUpstream(weeklyRuleBody),
    },
    async (context, calls) => {
      await onRequestPost(context);
      assert.equal(calls[0].init.headers.get('X-Local-Date'), todayInZone('America/New_York'));
    }
  );
});

test('recur-check: tz=auto 但 cf 缺失回落 UTC', async () => {
  await withMockedUpstream(
    { body: { phrase: 'gym every monday', tz: 'auto' }, upstreamImpl: () => jsonUpstream(weeklyRuleBody) },
    async (context, calls) => {
      await onRequestPost(context);
      assert.equal(calls[0].init.headers.get('X-Local-Date'), todayInZone('UTC'));
    }
  );
});

test('recur-check: 显式时区不在白名单 400', async () => {
  await withMockedUpstream(
    { body: { phrase: 'gym every monday', tz: 'Mars/Olympus' }, upstreamImpl: () => { throw new Error('不应触达上游'); } },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 400);
    }
  );
});

test('recur-check: 模型没给重复规则时诚实展示(不编规则)', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'buy milk tomorrow', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{ title: 'Buy milk', due_date: null, recurrence_rule: null, due_date_basis: 'inferred' }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /No repeat in this phrase/);
      assert.match(html, /“Buy milk”/);
      assert.doesNotMatch(html, /<ul class="date-list">/, '无重复页不得渲染日期列表');
      assert.doesNotMatch(html, /understands this as/);
    }
  );
});

test('recur-check: 每日档 429 用共用配额文案', async () => {
  await withMockedUpstream(
    { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => new Response('rate limited', { status: 429, headers: { 'X-RateLimit-Type': 'web_ip_daily' } }) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Daily tries used up/);
      assert.match(html, /across these tools/);
    }
  );
});

test('recur-check: velocity 档 429 用一分钟文案', async () => {
  await withMockedUpstream(
    { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => new Response('rate limited', { status: 429, headers: { 'X-RateLimit-Type': 'web_velocity' } }) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      assert.match(await response.text(), /That was quick/);
    }
  );
});

test('recur-check: 全局预算 503 用 web 档文案', async () => {
  await withMockedUpstream(
    { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => jsonUpstream({ error: 'global_budget_exceeded_web' }, 503) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      assert.match(await response.text(), /Web quota used up for today/);
    }
  );
});

test('recur-check: 上游其他错误显式 502', async () => {
  await withMockedUpstream(
    { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => new Response('boom', { status: 500 }) },
    async (context, calls, logs) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 502);
      assert.ok(logs.some(([level]) => level === 'error'), '服务端故障必须有显式日志');
    }
  );
});

test('recur-check: 上游 200 但 JSON 坏,显式 502 不装正常', async () => {
  await withMockedUpstream(
    { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => new Response('not json at all', { status: 200 }) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 502);
    }
  );
});

test('recur-check: 缺配置 503 + 显式日志,不触达上游', async () => {
  const originalFetch = globalThis.fetch;
  const logs = [];
  const originalError = console.error;
  console.error = (...args) => logs.push(args);
  globalThis.fetch = () => { throw new Error('不应触达上游'); };
  try {
    const request = new Request(TOOL_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ phrase: 'gym every monday' }),
    });
    const response = await onRequestPost({ request, env: { AI_PROXY_ORIGIN: 'https://proxy.test' } });
    assert.equal(response.status, 503);
    assert.ok(logs.some((args) => String(args[0]).includes('recur-check: missing env')));
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalError;
  }
});

test('recur-check: 空输入 400', async () => {
  await withMockedUpstream(
    { body: { phrase: '   ', tz: 'UTC' }, upstreamImpl: () => { throw new Error('不应触达上游'); } },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 400);
    }
  );
});
