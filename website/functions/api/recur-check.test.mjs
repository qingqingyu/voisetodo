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
async function withMockedUpstream({ body, cf, visitorSignal, origin, upstreamImpl }, fn) {
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
        ...(origin ? { origin } : {}),
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

test('recur-check: 周六周日跨编号边界的展示排序(Sat and Sun → Saturday and Sunday)', async () => {
  // 回归(审计 2026-11-24 小问题):模型按 Apple 编号升序给 weekdays [1,7],
  // 页面不得渲染「Every Sunday and Saturday」;未来五次按日历日推进。
  const weekendRuleBody = {
    todos: [{
      title: 'family time',
      due_date: null,
      due_time: null,
      time_bucket: null,
      recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [1, 7], day_of_month: null, end_date: null },
      due_date_basis: null,
    }],
    ignored: '',
  };
  await withMockedUpstream(
    { body: { phrase: 'family time every Sat and Sun', tz: 'UTC' }, upstreamImpl: () => jsonUpstream(weekendRuleBody) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Every Saturday and Sunday/);
      assert.doesNotMatch(html, /Every Sunday and Saturday/);
      assert.doesNotMatch(html, /Sunday, Saturday/);
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
      assert.match(html, /It would be kept as a plain task without a repeat: “Buy milk”/);
      assert.doesNotMatch(html, /<ul class="date-list">/, '无重复页不得渲染日期列表');
      assert.doesNotMatch(html, /understands this as/);
    }
  );
});

test('recur-check: 上游 200 但零任务时走「Nothing to check」页(不谎报 No repeat)', async () => {
  await withMockedUpstream(
    { body: { phrase: 'buy milk tomorrow', tz: 'UTC' }, upstreamImpl: () => jsonUpstream({ todos: [], ignored: '' }) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Nothing to check/);
      assert.match(html, /No tasks were recognized/);
      assert.doesNotMatch(html, /No repeat in this phrase/, '零任务不得说成「解析到了但不重复」');
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

test('recur-check: 超长输入(>500)显式 400 不静默截断(与 split.js 超长口径一致)', async () => {
  await withMockedUpstream(
    { body: { phrase: 'x'.repeat(501), tz: 'UTC' }, upstreamImpl: () => { throw new Error('不应触达上游'); } },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 400);
      const html = await response.text();
      assert.ok(html.includes('Too long'));
      assert.ok(html.includes('501'));
    }
  );
});

test('recur-check: 展开不足五次时按实际条数说(不硬说 five)', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'report every 4 months on the 15th', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Report',
          recurrence_rule: { frequency: 'monthly', interval: 4, weekdays: [], day_of_month: 15, end_date: null },
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      const html = await response.text();
      // 自适应上限(双 review 修复轮):interval 4 的第 5 次在 400 步之外,仍能出满五次
      assert.equal((html.match(/<li>/g) || []).length, 5);
      assert.match(html, /The next five times/);
    }
  );
});

test('recur-check: 一条都展不开时明说,不渲染空列表', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'gym every wednesday until nov 19', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Gym',
          recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [4], day_of_month: null, end_date: '2026-11-19' },
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /No upcoming dates to show for this rule/);
      assert.doesNotMatch(html, /<ul class="date-list">/);
      assert.doesNotMatch(html, /The next five/);
    }
  );
});

test('recur-check: 上游 200 合法 JSON 但形状不对(标量/数组)显式 502 不裸 500', async () => {
  for (const body of ['null', '[1,2]', '"ok"', '123']) {
    await withMockedUpstream(
      { body: { phrase: 'a', tz: 'UTC' }, upstreamImpl: () => new Response(body, { status: 200 }) },
      async (context) => {
        const response = await onRequestPost(context);
        assert.equal(response.status, 502, `body=${body}`);
      }
    );
  }
});

test('recur-check: todos 里混入 null / 非对象元素不抛,按剩余元素渲染', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'gym every monday', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({ todos: [null, 'x', { title: 'Gym', recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [2] } }], ignored: '' }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Every Monday/);
      // 周一规则能正常展开五次(归一化只剔除 null / 非对象元素)
      assert.equal((html.match(/<li>/g) || []).length, 5);
      // 非 string title 不得渲染成 [object Object]
      assert.doesNotMatch(html, /\[object Object\]/);
    }
  );
});

test('recur-check: 同源 Origin 放行,跨站与 Origin:null 拒 403 且不触上游', async () => {
  await withMockedUpstream(
    { body: { phrase: 'gym every monday', tz: 'UTC' }, origin: 'https://site.test', upstreamImpl: () => jsonUpstream(weeklyRuleBody) },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200, '同源 POST 正常处理');
    }
  );
  for (const origin of ['https://evil.test', 'null']) {
    await withMockedUpstream(
      { body: { phrase: 'a', tz: 'UTC' }, origin, upstreamImpl: () => { throw new Error('不应触达上游'); } },
      async (context) => {
        const response = await onRequestPost(context);
        assert.equal(response.status, 403, `origin=${origin}`);
      }
    );
  }
});

test('recur-check: 混合短语里无重复的任务列出来,不静默消失', async () => {
  await withMockedUpstream(
    {
      body: { phrase: 'gym every monday, buy milk', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [
          { title: 'Gym', recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [2], day_of_month: null, end_date: null } },
          { title: 'Buy milk', recurrence_rule: null },
          { title: '', recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [], day_of_month: null, end_date: null } },
        ],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Every Monday/);
      // App 会丢弃的畸形规则(App isValid false)不进卡片:只有 Gym 一张规则卡
      assert.equal((html.match(/VoiceTodo understands this as:/g) || []).length, 1);
      assert.match(html, /Also kept as a plain task without a repeat: “Buy milk”/);
      // 空标题不进列表
      assert.doesNotMatch(html, /“”/);
      assert.equal((html.match(/<li>/g) || []).length, 5);
    }
  );
});

// ---------- 顶层 recurrence_end 渲染(2026-11-26 审计轮 2) ----------
// 用真实 todayInZone 构造确定性日期,不依赖墙钟。

const plusDays = (iso, n) => new Date(Date.parse(`${iso}T12:00:00.000Z`) + n * 86400000).toISOString().slice(0, 10);

test('recur-check: recurrence_end after_count → 规则文案带时长,五次照常展开', async () => {
  const today = todayInZone('UTC');
  await withMockedUpstream(
    {
      body: { phrase: 'meds every day for the next 30 days', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Take meds', due_date: today, due_time: null, time_bucket: null,
          recurrence_rule: { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null },
          recurrence_end: { kind: 'after_count', count: 30, unit: 'day' },
          due_date_basis: 'user_explicit',
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('Every day, for 30 days'), '规则文案应带时长截止(页面自带示例场景)');
      assert.ok(html.includes('The next five times'), '30 天内足够展示五次');
    },
  );
});

test('recur-check: recurrence_end date 截止在两天后 → 只列两条,不显示截止后的日期', async () => {
  const today = todayInZone('UTC');
  await withMockedUpstream(
    {
      body: { phrase: 'gym every day until Friday', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Gym', due_date: today, due_time: null, time_bucket: null,
          recurrence_rule: { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null },
          recurrence_end: { kind: 'date', value: plusDays(today, 2) },
          due_date_basis: 'user_explicit',
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(/until [A-Z][a-z]{2} \d{1,2}, \d{4}/.test(html), '规则文案应带 until 绝对日期');
      assert.ok(html.includes('The next 2 times'), '只剩两条(明天/后天)');
      assert.equal((html.match(/<li>/g) || []).length, 2, '日期列表恰好两条,截止后不出现');
    },
  );
});

test('recur-check: recurrence_end 形状坏(count 0)→ 无截止按无界展示,规则不受影响', async () => {
  const today = todayInZone('UTC');
  await withMockedUpstream(
    {
      body: { phrase: 'meds every day', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Take meds', due_date: null, due_time: null, time_bucket: null,
          recurrence_rule: { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null },
          recurrence_end: { kind: 'after_count', count: 0 },
          due_date_basis: null,
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('>Every day<'), '规则仍渲染、不带截止后缀');
      assert.ok(html.includes('The next five times'), '按无界展开五次');
      assert.ok(!html.includes(', for '), '没有时长后缀');
    },
  );
});

// ---------- 双 review 修正(2026-11-26):畸形日期 / 超大 count 不炸不渲染垃圾 ----------

test('recur-check: recurrence_end date 值 13 月 → 无截止,页面不出现 "undefined"', async () => {
  const today = todayInZone('UTC');
  await withMockedUpstream(
    {
      body: { phrase: 'meds every day', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Take meds', due_date: null, due_time: null, time_bucket: null,
          recurrence_rule: { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null },
          recurrence_end: { kind: 'date', value: '2026-13-01' },
          due_date_basis: null,
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200, '域外月份 = 无截止(Swift parseISODate nil 同口径),不该 500');
      const html = await response.text();
      assert.ok(!html.includes('undefined'), '不得渲染 "undefined 1, 2026" 这类垃圾');
      assert.ok(html.includes('>Every day<'), '规则仍按无截止渲染');
      assert.ok(html.includes('The next five times'), '无截止按无界展开');
    },
  );
});

test('recur-check: after_count 超大 count → 不炸(RangeError→500 已修),按无截止', async () => {
  const today = todayInZone('UTC');
  await withMockedUpstream(
    {
      body: { phrase: 'meds every day', tz: 'UTC' },
      upstreamImpl: () => jsonUpstream({
        todos: [{
          title: 'Take meds', due_date: null, due_time: null, time_bucket: null,
          recurrence_rule: { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null },
          recurrence_end: { kind: 'after_count', count: 999999999, unit: 'day' },
          due_date_basis: null,
        }],
        ignored: '',
      }),
    },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200, '超大 count = Swift calendar.date(byAdding:) nil → 无截止,不 500');
      const html = await response.text();
      assert.ok(html.includes('The next five times'), '无截止按无界展开');
      assert.ok(!html.includes('for 999999999'), '不渲染荒谬时长文案');
    },
  );
});
