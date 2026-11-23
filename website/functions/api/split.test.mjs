// split.js 单测:工具页①表单处理里「把访客断连信号透传给上游」这一段。
// 背景(2026-11-23 线上实测):零 JS 表单提交后无反馈,用户连点 → 浏览器取消前几次
// 导航;代理靠这个信号识别被取消的请求并退每日额度。信号没透传到位 = 修复空转。
// 跑法:cd website && npm run test:functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { onRequestPost } from './split.js';

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
