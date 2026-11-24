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

// 同源表单闸:Origin 头存在且与实际接收请求的源不一致时拒绝。第三方页面可以用
// 访客的浏览器自动 POST 表单烧掉访客 IP 的每日 3 次共享配额(反 CSRF 的最小形式,
// 工具端点无 cookie 无会话,只需要挡跨站归因)。按 request.url 的实际源比较,不写死
// 域名 —— 主域、pages.dev 旧域、preview 部署全部自动正确。Origin 缺失(直连/curl)
// 放行,不把正常流量挡在外面;Origin 解析失败按拒绝处理(fail-closed,显式口径)。
export function isSameOriginForm(request) {
  const origin = request.headers.get('origin');
  if (!origin) return true;
  try {
    return new URL(request.url).origin === new URL(origin).origin;
  } catch {
    return false;
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

// 解析代理响应体。上游 200 但内容不可用(JSON 坏,或合法 JSON 但不是对象 ——
// 代理把模型 text 原样返回,模型可能给 null/数组/标量,调用方取 data.todos 会
// TypeError → 裸 500)时 parseOk=false,由调用方显式 502(错误显式传播:不给
// 用户一个空结果装正常)。两个工具的上游是同一条提取流程,响应都可能是带
// ```json 围栏的模型原文,剥围栏与形状校验口径共用一份。
export function parseExtraction(text) {
  try {
    const data = JSON.parse(stripMarkdownFence(text));
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      return { parseOk: false, data: null };
    }
    return { parseOk: true, data };
  } catch {
    return { parseOk: false, data: null };
  }
}

// todos 数组归一化:模型可能给 [null] / ["x"] / 嵌套数组 —— 只留纯对象元素,
// 调用方对元素的属性读取不再抛 TypeError。
export function normalizeTodos(data) {
  const raw = data && Array.isArray(data.todos) ? data.todos : [];
  return raw.filter((todo) => todo && typeof todo === 'object' && !Array.isArray(todo));
}

// title 只按字符串取:对象/数字等模型跑偏输出不渲染成 "[object Object]"。
export function plainTitle(todo) {
  return typeof todo.title === 'string' ? todo.title : '';
}

function stripMarkdownFence(text) {
  const trimmed = String(text).trim();
  const fence = /^```(?:json)?\s*([\s\S]*?)\s*```$/.exec(trimmed);
  return fence ? fence[1] : trimmed;
}
