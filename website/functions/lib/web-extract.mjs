// 官网两个工具页(split.js / recur-check.js)共用的代理 web 档调用小件。
// 两个工具走同一条上游(/v1/web/todo-extractions)、同一套鉴权头、同一种断连透传、
// 同一种表单读取 —— 收口在这里,修一处两端生效。官网零依赖:只用 Workers/Pages
// 运行时全局,不跨目录 import。
export const WEB_EXTRACT_PATH = '/v1/web/todo-extractions';

// 上游超时对齐 App 端整体超时预算(代理 failover 最坏情形)。
export const UPSTREAM_TIMEOUT_MS = 45000;

// 代理 web 档所需的两项 Pages 配置都在,才算可用。
export function requireWebEnv(env) {
  return Boolean(env.AI_PROXY_ORIGIN && env.WEB_EXTRACT_TOKEN);
}

// 上游 fetch 的 AbortSignal:访客断连 + 超时,任一触发即取消。
//
// 为什么要透传访客断连(2026-11-23 线上实测修复):零 JS 表单点提交后无反馈,用户
// 会连点 —— 浏览器取消前几次导航,只有最后一次的结果被看到。把 request.signal 带给
// 上游,代理检测到断连就退掉那次每日额度(没看到的请求不占 3 次/天)。
//
// 运行时前提:request.signal 要真的会 abort,Pages 项目需要兼容标志
// enable_request_signal(兼容日期 ≥ 2026-11-17 才默认开启),否则这里透传的是一个
// 永不触发的信号,修复在线上空转(不会报错,只是不生效)。
//
// AbortSignal.any 加 typeof 守卫:缺失时退回「只有超时」的旧信号并显式告警,
// 而不是让每次表单提交都抛 TypeError 变成 503 —— 那比修复前更糟。
// (代理侧同款合并与 fallback 见 AIProxy/src/adapters/base.js mergeSignals;
// 官网零依赖、不跨目录 import,这里只保留最小守卫。)
export function upstreamSignal(visitorSignal, logLabel = 'web-extract') {
  const timeoutSignal = AbortSignal.timeout(UPSTREAM_TIMEOUT_MS);
  if (typeof AbortSignal.any !== 'function') {
    console.warn(`${logLabel}: AbortSignal.any unavailable; visitor disconnects will not cancel the upstream request`);
    return timeoutSignal;
  }
  return AbortSignal.any([visitorSignal, timeoutSignal]);
}

// locale 口径:App 端发用户真实 locale(代理按它选 few-shot 语言),工具页
// 零 JS 读不到系统 locale,退而按输入文字的书写系统猜 —— 官网宣称「the same
// parse the app runs」,中文句子走英文档 prompt 就名不副实了。代理侧
// normalizeLocale 只认 en/zh/ja,猜错回 en,不会产生新值。
export function detectLocale(text) {
  if (/[぀-ヿ]/.test(text)) return 'ja';
  if (/[一-鿿]/.test(text)) return 'zh';
  return 'en';
}

export async function readForm(request) {
  const contentType = request.headers.get('content-type') || '';
  if (!contentType.includes('application/x-www-form-urlencoded')) {
    return null;
  }
  try {
    return new URLSearchParams(await request.text());
  } catch (error) {
    console.error('web-extract: form parse failed', error);
    return null;
  }
}

// 调代理 web 档。只负责「发出去」:HTTP 状态码与响应体的处理留在各工具的
// handler(两个工具对 429/503/413 的用户文案不同)。网络层失败(含访客断连
// 触发的 abort)直接抛出,由调用方分流日志。
export async function fetchWebExtraction(env, request, { text, locale, todayIso, logLabel }) {
  return fetch(`${env.AI_PROXY_ORIGIN.replace(/\/+$/, '')}${WEB_EXTRACT_PATH}`, {
    method: 'POST',
    headers: new Headers({
      'Content-Type': 'application/json',
      'X-Web-Token': env.WEB_EXTRACT_TOKEN,
      'X-Web-Client-IP': request.headers.get('CF-Connecting-IP') || 'anonymous',
      'X-Local-Date': todayIso,
    }),
    body: JSON.stringify({ transcript: text, locale }),
    signal: upstreamSignal(request.signal, logLabel),
  });
}
