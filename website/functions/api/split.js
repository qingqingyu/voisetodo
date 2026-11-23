// 工具页①(一句话拆多条提醒)的表单处理:原生 form POST → 服务端调代理
// web 档(/v1/web/todo-extractions)→ 渲染结果页。零客户端 JS。
// 鉴权:X-Web-Token 只存在于 Pages 环境变量与代理 secret,浏览器拿不到;
// 访客 IP 用 CF-Connecting-IP 转发(代理按它限流:3 次/天/IP)。
// 配置(都在 Pages 项目设置里):
//   AI_PROXY_ORIGIN  代理基地址,如 https://ai.example.org
//   WEB_EXTRACT_TOKEN  与代理 `wrangler secret put WEB_EXTRACT_TOKEN` 同值
import { isKnownTimezone, todayInZone } from '../lib/timezones.mjs';
import { describeModelRecurrence } from '../lib/recurrence.mjs';
import { toolResultPage, htmlResponse, escapeHtml } from '../lib/render.mjs';

const TOOL_PATH = '/tools/add-multiple-reminders-at-once';
const CT = 'web-tool-split-result';
const MAX_INPUT_CHARS = 1000;
const UPSTREAM_TIMEOUT_MS = 45000; // 对齐 App 端整体超时预算(代理 failover 最坏情形)
const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export async function onRequestPost(context) {
  const { request, env } = context;

  const form = await readForm(request);
  if (form instanceof Response) return form;

  const text = (form.get('text') || '').trim();
  const tz = form.get('tz') || 'UTC';

  if (!text) {
    return errorResult('Nothing to split', 'Type a sentence first — for example “call the dentist tomorrow at 9, send the report by Friday, pay rent on the 1st every month”.');
  }
  if (text.length > MAX_INPUT_CHARS) {
    return errorResult('Too long', `Please keep it under ${MAX_INPUT_CHARS} characters (you sent ${text.length}).`);
  }
  if (!isKnownTimezone(tz)) {
    return errorResult('Unknown timezone', 'Please pick a timezone from the list.');
  }
  if (!env.AI_PROXY_ORIGIN || !env.WEB_EXTRACT_TOKEN) {
    // 显式报错,不静默降级(CLAUDE.md 错误显式传播):缺配置是部署事故,
    // 用户可见文案不泄露内部细节,日志里留全量原因。
    console.error('split: missing env', {
      hasOrigin: Boolean(env.AI_PROXY_ORIGIN),
      hasToken: Boolean(env.WEB_EXTRACT_TOKEN),
    });
    return errorResult('Tool not available', 'This tool is not configured on the server right now. Please try again later.', 503);
  }

  const today = todayInZone(tz);
  let upstream;
  try {
    upstream = await fetch(`${env.AI_PROXY_ORIGIN.replace(/\/+$/, '')}/v1/web/todo-extractions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Web-Token': env.WEB_EXTRACT_TOKEN,
        'X-Web-Client-IP': request.headers.get('CF-Connecting-IP') || 'anonymous',
        'X-Local-Date': today,
      },
      body: JSON.stringify({ transcript: text, locale: detectLocale(text) }),
      // 透传访客断连信号(2026-11-23 线上实测修复):零 JS 表单点提交后无反馈,
      // 用户会连点 —— 浏览器取消前几次导航,只有最后一次的结果被看到。把
      // request.signal 带给上游,代理检测到断连就退掉那次每日额度(没看到的
      // 请求不占 3 次/天);同时保留 45s 超时兜底。
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(UPSTREAM_TIMEOUT_MS)]),
    });
  } catch (error) {
    console.error('split: upstream fetch failed', error);
    return errorResult('Could not reach the service', 'The splitting service did not respond. Nothing was saved — please try again in a moment.', 503);
  }

  if (upstream.status === 429) {
    // 代理用 X-RateLimit-Type 区分两档 429:web_ip_daily(每天 3 次)与
    // web_velocity(每分钟 6 次)。两者用户侧含义完全不同 —— 每日档明天才
    // 重置,velocity 档一分钟就恢复,混在一起会把「稍等一分钟」说成
    // 「今天用完了」。
    const rateType = upstream.headers.get('X-RateLimit-Type') || 'web_ip_daily';
    if (rateType === 'web_velocity') {
      return htmlResponse(toolResultPage({
        toolPath: TOOL_PATH,
        toolLabel: 'sentence splitter',
        heading: 'That was quick',
        bodyHtml: `<div class="card"><p style="margin:0">Several tries in a row — the page pauses for about a minute to keep things fair.
Nothing was saved; wait a moment and try again.</p></div>`,
        ct: CT,
      }));
    }
    return htmlResponse(toolResultPage({
      toolPath: TOOL_PATH,
      toolLabel: 'sentence splitter',
      heading: 'Daily tries used up',
      bodyHtml: `<div class="card"><p style="margin:0">You've used today's three tries from this page. The counter resets tomorrow.
In the <strong>app</strong>, the same split runs every time you capture — with reminders, repeats and widgets on top.</p></div>`,
      ct: CT,
    }));
  }
  if (upstream.status === 503) {
    const errBody = await upstream.json().catch(() => ({}));
    if (errBody.error === 'global_budget_exceeded_web') {
      return htmlResponse(toolResultPage({
        toolPath: TOOL_PATH,
        toolLabel: 'sentence splitter',
        heading: 'Web quota used up for today',
        bodyHtml: `<div class="card"><p style="margin:0">This page's daily quota is finished. Come back tomorrow —
or continue in the <strong>app</strong>, where the same split runs on every capture.</p></div>`,
        ct: CT,
      }));
    }
    console.error('split: upstream 503', errBody);
    return errorResult('Service unavailable', 'The splitting service is temporarily unavailable. Nothing was saved — please try again later.', 503);
  }
  if (upstream.status === 413) {
    return errorResult('Too long', `The service accepts up to ${MAX_INPUT_CHARS} characters. Please shorten your sentence.`);
  }
  if (upstream.status !== 200) {
    const detail = await upstream.text().catch(() => '');
    console.error('split: upstream error', { status: upstream.status, detail: detail.slice(0, 500) });
    return errorResult('Split failed', 'The splitting service returned an error. Nothing was saved — please try again in a moment.', 502);
  }

  const raw = await upstream.text();
  const parsed = parseExtraction(raw);
  if (!parsed.parseOk) {
    // 上游 200 但 JSON 坏:显式报错,不给用户一个空列表装正常。
    console.error('split: unparseable upstream body', raw.slice(0, 500));
    return errorResult('Split failed', 'The splitting service returned something unexpected. Nothing was saved — please try again.', 502);
  }

  const todos = Array.isArray(parsed.data.todos) ? parsed.data.todos : [];
  if (todos.length === 0) {
    return htmlResponse(toolResultPage({
      toolPath: TOOL_PATH,
      toolLabel: 'sentence splitter',
      heading: 'No tasks found',
      bodyHtml: `<p class="you-said">You said: “${escapeHtml(text)}”</p>
<div class="card"><p style="margin:0">No clear action items were found in that sentence. Try naming the things you want to do —
the parser keeps decisions and errands too, but skips feelings and background chatter.</p></div>`,
      ct: CT,
    }));
  }

  const rows = todos.map((todo) => todoRow(todo)).join('');
  const copyLines = todos.map((todo) => copyLine(todo)).join('\n');
  const ignored = typeof parsed.data.ignored === 'string' ? parsed.data.ignored.trim() : '';
  const ignoredHtml = ignored
    ? `<p class="note">Not kept as tasks: “${escapeHtml(ignored)}”</p>`
    : '';
  const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(text)}”</p>
<div class="card">${rows}</div>
${ignoredHtml}
<h2>Copy your list</h2>
<label class="note" for="copybox">Select all and copy (no button needed):</label>
<textarea class="copy-box" id="copybox" readonly rows="${Math.min(12, todos.length + 1)}">${escapeHtml(copyLines)}</textarea>
<p class="note">This page only splits the sentence. Reminders, repeats, widgets and Siri capture live in the app —
everything you confirm there is saved with the dates shown above.</p>`;
  return htmlResponse(toolResultPage({
    toolPath: TOOL_PATH,
    toolLabel: 'sentence splitter',
    heading: todos.length === 1 ? '1 task, split and dated' : `${todos.length} tasks, split and dated`,
    bodyHtml,
    ct: CT,
  }));
}

// ---------- 渲染小件 ----------

// locale 口径:App 端发用户真实 locale(代理按它选 few-shot 语言),工具页
// 零 JS 读不到系统 locale,退而按输入文字的书写系统猜 —— 官网宣称「the same
// parse the app runs」,中文句子走英文档 prompt 就名不副实了。代理侧
// normalizeLocale 只认 en/zh/ja,猜错回 en,不会产生新值。
function detectLocale(text) {
  if (/[぀-ヿ]/.test(text)) return 'ja';
  if (/[一-鿿]/.test(text)) return 'zh';
  return 'en';
}

function formatDueDate(iso) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(iso))) return '';
  const [, m, d] = iso.split('-');
  return `${MONTH_SHORT[parseInt(m, 10) - 1]} ${parseInt(d, 10)}, ${iso.slice(0, 4)}`;
}

function formatTime(hhmm) {
  const match = /^(\d{2}):(\d{2})$/.test(String(hhmm)) ? String(hhmm).split(':') : null;
  if (!match) return '';
  const h = parseInt(match[0], 10);
  const suffix = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${match[1]} ${suffix}`;
}

function whenText(todo) {
  const parts = [];
  if (todo.due_date) parts.push(formatDueDate(todo.due_date));
  if (todo.due_time) parts.push(formatTime(todo.due_time));
  if (!todo.due_time && todo.time_bucket) parts.push(String(todo.time_bucket));
  if (Array.isArray(todo.reminder_times) && todo.reminder_times.length > 0) {
    parts.push(`reminders at ${todo.reminder_times.map(formatTime).filter(Boolean).join(', ')}`);
  }
  const recurrence = describeModelRecurrence(todo.recurrence_rule);
  if (recurrence) parts.push(recurrence);
  // 模型输出偶发畸形日期/时间会产出空段,过滤掉避免拼出尾随「 · 」。
  return parts.filter(Boolean).join(' · ');
}

function todoRow(todo) {
  const when = whenText(todo);
  return `<div class="todo-row">
  <span class="todo-title">${escapeHtml(todo.title || '')}</span>
  ${when ? `<span class="todo-when">${escapeHtml(when)}</span>` : '<span class="todo-when">no date</span>'}
</div>`;
}

function copyLine(todo) {
  const when = whenText(todo);
  return when ? `${todo.title || ''} — ${when}` : (todo.title || '');
}

// ---------- 共用小件 ----------

function parseExtraction(text) {
  try {
    return { parseOk: true, data: JSON.parse(stripMarkdownFence(text)) };
  } catch {
    return { parseOk: false, data: null };
  }
}

function stripMarkdownFence(text) {
  const trimmed = String(text).trim();
  const fence = /^```(?:json)?\s*([\s\S]*?)\s*```$/.exec(trimmed);
  return fence ? fence[1] : trimmed;
}

async function readForm(request) {
  const contentType = request.headers.get('content-type') || '';
  if (!contentType.includes('application/x-www-form-urlencoded')) {
    return errorResult('Form error', 'This page expects a normal form submission. Please use the form on the tool page.');
  }
  try {
    return new URLSearchParams(await request.text());
  } catch (error) {
    console.error('split: form parse failed', error);
    return errorResult('Form error', 'Could not read the form submission. Please go back and try again.');
  }
}

// status 口径:客户端输入问题 400(默认);服务端故障(缺配置/上游不可达/
// 上游报错/坏响应)必须 5xx —— 错误显式传播,不把服务端故障伪装成客户端错。
function errorResult(heading, message, status = 400) {
  const bodyHtml = `<div class="card err"><p style="margin:0">${escapeHtml(message)}</p></div>`;
  return htmlResponse(
    toolResultPage({ toolPath: TOOL_PATH, toolLabel: 'sentence splitter', heading, bodyHtml, ct: CT }),
    status
  );
}
