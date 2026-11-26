// split.js 单测:工具页①表单处理里「把访客断连信号透传给上游」这一段。
// 背景(2026-11-23 线上实测):零 JS 表单提交后无反馈,用户连点 → 浏览器取消前几次
// 导航;代理靠这个信号识别被取消的请求并退每日额度。信号没透传到位 = 修复空转。
// 跑法:cd website && npm run test:functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { onRequestPost } from './split.js';
import { todayInZone } from '../lib/timezones.mjs';

const TOOL_URL = 'https://site.test/tools/add-multiple-reminders-at-once';
const UPSTREAM_URL = 'https://proxy.test/v1/web/todo-extractions';

// 替换全局 fetch 并截获上游调用的 init;同时静音并截获 console,供断言「有显式日志」。
async function withMockedUpstream(upstreamImpl, visitorSignal, fn) {
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
      body: new URLSearchParams({ text: 'call the dentist tomorrow', tz: 'UTC' }),
      signal: visitorSignal,
    });
    const context = { request, env: { AI_PROXY_ORIGIN: 'https://proxy.test', WEB_EXTRACT_TOKEN: 'web-token' } };
    return await fn(context, calls, logs);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    console.warn = originalWarn;
    console.error = originalError;
  }
}

const okUpstream = () => new Response(JSON.stringify({ todos: [{ title: 'Call the dentist', due_date: '2026-11-24' }], ignored: '' }), {
  status: 200,
  headers: { 'Content-Type': 'application/json' },
});

test('split: 访客断连信号透传给上游 fetch(连点取消的那次请求可被代理识别)', async () => {
  const visitor = new AbortController();
  await withMockedUpstream(okUpstream, visitor.signal, async (context, calls) => {
    let upstreamSignal;
    const response = await onRequestPost(context);
    assert.equal(response.status, 200, '正常路径仍返回结果页');
    assert.equal(calls.length, 1, '应恰好调一次上游');
    assert.equal(calls[0].url, UPSTREAM_URL);
    upstreamSignal = calls[0].init.signal;
    assert.ok(upstreamSignal, '上游 fetch 必须带 signal');
    assert.equal(upstreamSignal.aborted, false, '访客未离开时上游 signal 不应提前 abort');

    visitor.abort();
    assert.equal(upstreamSignal.aborted, true, '访客断连后上游 signal 必须 abort(否则代理看不到断连)');
  });
});

test('split: 上游 fetch 不复用访客的 signal 对象本身(超时兜底独立存在)', async () => {
  const visitor = new AbortController();
  await withMockedUpstream(okUpstream, visitor.signal, async (context, calls) => {
    await onRequestPost(context);
    assert.notEqual(calls[0].init.signal, visitor.signal, '应是合并后的新 signal,而非直接传 request.signal');
  });
});

test('split: 运行时缺 AbortSignal.any 时不抛错 —— 上游照常调用并显式告警', async () => {
  const visitor = new AbortController();
  const originalAny = AbortSignal.any;
  AbortSignal.any = undefined;
  try {
    await withMockedUpstream(okUpstream, visitor.signal, async (context, calls, logs) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200, '缺 AbortSignal.any 时提交仍应成功,不能整页 503');
      assert.equal(calls.length, 1, '上游仍应被调用');
      assert.ok(calls[0].init.signal, '至少保留超时兜底 signal');
      visitor.abort();
      assert.equal(calls[0].init.signal.aborted, false, '降级路径不透传访客断连(只靠超时)');
      assert.ok(
        logs.some(([level, msg]) => level === 'warn' && String(msg).includes('AbortSignal.any unavailable')),
        '降级必须显式告警,不能静默'
      );
    });
  } finally {
    AbortSignal.any = originalAny;
  }
});

test('split: 上游 fetch 被取消(访客连点)→ 503 结果页,按 info 记录而非 error', async () => {
  const visitor = new AbortController();
  const abortingUpstream = async (_url, init) => {
    // 模拟运行时:访客断连 → 合并 signal abort → fetch 抛 AbortError
    const signal = init.signal;
    visitor.abort();
    assert.equal(signal.aborted, true);
    throw Object.assign(new Error('This operation was aborted'), { name: 'AbortError' });
  };
  await withMockedUpstream(abortingUpstream, visitor.signal, async (context, _calls, logs) => {
    const response = await onRequestPost(context);
    assert.equal(response.status, 503);
    assert.ok((await response.text()).includes('Could not reach the service'));
    assert.ok(
      logs.some(([level, msg]) => level === 'log' && String(msg).includes('visitor left')),
      '访客取消是预期路径,应有 info 日志'
    );
    assert.equal(
      logs.filter(([level]) => level === 'error').length, 0,
      '访客取消不是上游故障,不应记 error'
    );
  });
});

test('split: 上游真故障(非断连)→ 503 结果页并记 error', async () => {
  const failingUpstream = async () => {
    throw new TypeError('fetch failed');
  };
  await withMockedUpstream(failingUpstream, new AbortController().signal, async (context, _calls, logs) => {
    const response = await onRequestPost(context);
    assert.equal(response.status, 503);
    assert.ok(
      logs.some(([level, msg]) => level === 'error' && String(msg).includes('upstream fetch failed')),
      '上游不可达必须记 error(不静默吞错)'
    );
  });
});

// —— 2026-11-24 增量:basis 过滤 + tz auto(参数化骨架,与上方 withMockedUpstream 同构)——

async function withSplitRequest({ body, cf, origin }, upstreamImpl, fn) {
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
      headers: { 'content-type': 'application/x-www-form-urlencoded', 'CF-Connecting-IP': '203.0.113.7', ...(origin ? { origin } : {}) },
      body: new URLSearchParams(body),
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

test('split: due_date_basis 非 user_explicit 的日期不展示(App basis 过滤同口径),钟点照常', async () => {
  const upstream = (basis) => new Response(
    JSON.stringify({ todos: [{ title: 'Call the dentist', due_date: '2026-11-25', due_time: '09:00', time_bucket: null, reminder_times: [], due_date_basis: basis }], ignored: '' }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  );
  await withSplitRequest(
    { body: { text: 'call the dentist tomorrow', tz: 'UTC' } },
    () => upstream('title_mention'),
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.match(html, /Call the dentist/);
      assert.doesNotMatch(html, /Nov 25, 2026/, '非 user_explicit 的日期不得展示');
      assert.match(html, /9:00 AM/, '钟点 App 端保留,照常展示');
    }
  );
});

test('split: due_date_basis 缺失(null)同样不展示日期', async () => {
  const upstream = () => new Response(
    JSON.stringify({ todos: [{ title: 'Errand', due_date: '2026-11-26', due_time: null, time_bucket: null, reminder_times: [], due_date_basis: null }], ignored: '' }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  );
  await withSplitRequest(
    { body: { text: 'errand', tz: 'UTC' } },
    upstream,
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.doesNotMatch(html, /Nov 26, 2026/);
      assert.match(html, /no date/);
    }
  );
});

test('split: user_explicit 日期照常展示', async () => {
  const upstream = () => new Response(
    JSON.stringify({ todos: [{ title: 'Call the dentist', due_date: '2026-11-25', due_time: null, time_bucket: null, reminder_times: [], due_date_basis: 'user_explicit' }], ignored: '' }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  );
  await withSplitRequest(
    { body: { text: 'call the dentist tomorrow', tz: 'UTC' } },
    upstream,
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      assert.match(await response.text(), /Nov 25, 2026/);
    }
  );
});

test('split: tz=auto 用 request.cf.timezone 算 X-Local-Date,cf 缺失回落 UTC', async () => {
  const upstream = () => new Response(JSON.stringify({ todos: [], ignored: '' }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  await withSplitRequest(
    { body: { text: 'call mom', tz: 'auto' }, cf: { timezone: 'America/New_York' } },
    upstream,
    async (context, calls) => {
      await onRequestPost(context);
      assert.equal(calls[0].init.headers.get('X-Local-Date'), todayInZone('America/New_York'));
    }
  );
  await withSplitRequest(
    { body: { text: 'call mom', tz: 'auto' } },
    upstream,
    async (context, calls) => {
      await onRequestPost(context);
      assert.equal(calls[0].init.headers.get('X-Local-Date'), todayInZone('UTC'));
    }
  );
});

test('split: 上游 200 合法 JSON 但形状不对(标量/数组)显式 502 不裸 500', async () => {
  for (const body of ['null', '{"todos": [null, "x"]}', '"ok"']) {
    await withSplitRequest(
      { body: { text: 'call mom', tz: 'UTC' } },
      () => new Response(body, { status: 200 }),
      async (context) => {
        const response = await onRequestPost(context);
        // [null,"x"] 被归一化掉后 todos 为空 → 走「No tasks found」200;其余 502
        const expected = body === '{"todos": [null, "x"]}' ? 200 : 502;
        assert.equal(response.status, expected, `body=${body}`);
      }
    );
  }
});

test('split: 非字符串 title 不渲染 [object Object]', async () => {
  await withSplitRequest(
    { body: { text: 'call mom', tz: 'UTC' } },
    () => new Response(JSON.stringify({ todos: [{ title: { nested: true }, due_date: null, due_time: null, time_bucket: null, reminder_times: [], due_date_basis: null }], ignored: '' }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.doesNotMatch(html, /\[object Object\]/);
    }
  );
});

test('split: 跨站 Origin 拒 403 且不触上游,同源放行', async () => {
  await withSplitRequest(
    { body: { text: 'call mom', tz: 'UTC' }, origin: 'https://site.test' },
    () => new Response(JSON.stringify({ todos: [], ignored: '' }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 200, '同源 POST 正常处理');
    }
  );
  await withSplitRequest(
    { body: { text: 'call mom', tz: 'UTC' }, origin: 'https://evil.test' },
    () => { throw new Error('不应触达上游'); },
    async (context) => {
      const response = await onRequestPost(context);
      assert.equal(response.status, 403);
    }
  );
});

// ---------- 标题措辞 / 时区线索 / 截止后缀(2026-11-26 审计轮 2) ----------
// 文件顶部的 withMockedUpstream 把表单写死成固定文案,这里用参数化骨架。

async function withSplitForm(form, upstreamImpl, fn) {
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  console.error = () => {};
  globalThis.fetch = async () => upstreamImpl();
  try {
    const request = new Request(TOOL_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', 'CF-Connecting-IP': '203.0.113.7' },
      body: new URLSearchParams(form),
    });
    const context = { request, env: { AI_PROXY_ORIGIN: 'https://proxy.test', WEB_EXTRACT_TOKEN: 'web-token' } };
    return await fn(await onRequestPost(context));
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalError;
  }
}

test('split: 有 user_explicit 日期 → 标题 "split and dated" + 时区线索行', async () => {
  await withSplitForm(
    { text: 'call the dentist tomorrow and pay rent on the 1st', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [
        { title: 'Call the dentist', due_date: '2026-12-24', due_date_basis: 'user_explicit' },
        { title: 'Pay rent', due_date: '2026-12-25', due_date_basis: 'user_explicit' },
      ],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('2 tasks, split and dated'), '有日期时标题保留 and dated');
      assert.ok(html.includes('Dates for UTC.'), '时间信息存在时显示时区线索');
    },
  );
});

test('split: basis 过滤后全部无日期 → 标题去掉 "and dated",尾注同步换措辞', async () => {
  await withSplitForm(
    { text: 'call the dentist someday', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [
        { title: 'Call the dentist', due_date: '2026-12-24', due_date_basis: 'inferred', time_bucket: 'afternoon' },
      ],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('1 task, split'), '无日期时标题不带 and dated');
      assert.ok(!html.includes('and dated'), '标题不出现 and dated');
      assert.ok(!html.includes('with the dates shown above'), '尾注不再指向「上方日期」');
      assert.ok(html.includes('saved with its dates and reminders'), '尾注换成不指向具体日期的措辞');
      assert.ok(html.includes('Dates for UTC.'), '有时段(time_bucket)仍显示时区线索');
      assert.ok(html.includes('afternoon'), '时段照常显示');
    },
  );
});

test('split: 完全无时间信息 → 无时区线索行', async () => {
  await withSplitForm(
    { text: 'buy milk', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [{ title: 'Buy milk', due_date: null, due_time: null, time_bucket: null }],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('1 task, split'));
      assert.ok(!html.includes('Dates for'), '无任何时间信息时不显示时区线索');
      assert.ok(html.includes('no date'), '行内如实显示 no date');
    },
  );
});

test('split: 复制文本带 recurrence_end 截止后缀(与 App 写入 endDate 同口径)', async () => {
  await withSplitForm(
    { text: 'physio every Monday for two weeks', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [{
        title: 'Physio', due_date: null, due_time: null, time_bucket: null,
        recurrence_rule: { frequency: 'weekly', interval: 1, weekdays: [2], day_of_month: null, end_date: null },
        recurrence_end: { kind: 'after_count', count: 2, unit: 'week' },
      }],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('Every Monday, for 2 weeks'), '行内与复制文本都带截止时长');
      assert.ok(html.includes('Dates for UTC.'), '重复信息也算时间线索');
    },
  );
});

// ---------- 双 review 修正(2026-11-26):畸形 due_date 归一后展示(App 解码层同口径) ----------

test('split: due_date 2月31 → 归一成 Mar 3 显示,标题仍 "and dated"(与 App 滚动一致)', async () => {
  await withSplitForm(
    { text: 'file taxes by end of February', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [{ title: 'File taxes', due_date: '2026-02-31', due_date_basis: 'user_explicit' }],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('Mar 3, 2026'), '显示滚动后的真实日历日(不在 App 里显示 "Feb 31")');
      assert.ok(!html.includes('Feb 31'), '不得渲染不存在的日期');
      assert.ok(html.includes('1 task, split and dated'), '归一成功 = 有日期,标题保留 and dated(与行内不矛盾)');
    },
  );
});

test('split: due_date 13 月 → 无日期显示,标题去掉 "and dated"', async () => {
  await withSplitForm(
    { text: 'call the dentist', tz: 'UTC' },
    () => new Response(JSON.stringify({
      todos: [{ title: 'Call the dentist', due_date: '2026-13-01', due_date_basis: 'user_explicit', due_time: null, time_bucket: null }],
      ignored: '',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    async (response) => {
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(!html.includes('and dated'), '域外月份 = 无日期(Swift parse nil),标题不得说 dated');
      assert.ok(!html.includes('undefined'), '不渲染 undefined');
      assert.ok(html.includes('no date'), '行内如实显示 no date');
      assert.ok(!html.includes('Dates for'), '无任何时间信息 → 无时区线索行');
    },
  );
});
