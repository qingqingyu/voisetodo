// 工具页②(重复提醒说法检查器)的表单处理:原生 form POST → 代理 web 档
// (/v1/web/todo-extractions,与工具①同一条上游、共用每天 3 次额度)→ 服务端渲染
// 结果页。零客户端 JS。
// 2026-11-24 起:展示口径从「本地确定性解析器」切换为「App 实际跑的 AI 解析」。
// 原因(审计 2026-11-24):App 的重复规则来自模型(prompt 每次都输出 recurrence_rule),
// 本地 resolveRecurrence 只在模型完全没返回该字段时才兜底(Protocols/Models.swift:392),
// 把它当对外展示会让工具替 App 说它做不到的事 —— 而且是往差了说(「每周一三五健身」
// 本地档只认出 Every Monday)。本页只渲染响应里的重复规则部分。
import { describeModelRecurrence, modelRuleOccurrences, formatOccurrence } from '../lib/recurrence.mjs';
import { resolveFormTimezone, todayInZone } from '../lib/timezones.mjs';
import { toolResultPage, htmlResponse, escapeHtml } from '../lib/render.mjs';
import { detectLocale, readForm, requireWebEnv, fetchWebExtraction } from '../lib/web-extract.mjs';

const TOOL_PATH = '/tools/recurring-reminder-checker';
const CT = 'web-tool-recur-result';

export async function onRequestPost(context) {
  const { request, env } = context;

  const form = await readForm(request);
  if (!form) {
    return errorResult('Form error', 'Could not read the form submission. Please use the form on the tool page.');
  }

  const phrase = (form.get('phrase') || '').trim().slice(0, 500);
  // tz 默认 auto:服务端按 request.cf.timezone 解析(与工具①同口径)。
  const { tz } = resolveFormTimezone(form.get('tz'), request);

  if (!phrase) {
    return errorResult('Nothing to check', 'Type or paste a phrase first — for example “remind me every Monday, Wednesday and Friday”.');
  }
  if (!tz) {
    return errorResult('Unknown timezone', 'Please pick a timezone from the list.');
  }
  if (!requireWebEnv(env)) {
    // 显式报错,不静默降级(CLAUDE.md 错误显式传播):缺配置是部署事故,
    // 用户可见文案不泄露内部细节,日志里留全量原因。
    console.error('recur-check: missing env', {
      hasOrigin: Boolean(env.AI_PROXY_ORIGIN),
      hasToken: Boolean(env.WEB_EXTRACT_TOKEN),
    });
    return errorResult('Tool not available', 'This tool is not configured on the server right now. Please try again later.', 503);
  }

  const today = todayInZone(tz);
  let upstream;
  try {
    upstream = await fetchWebExtraction(env, request, { text: phrase, locale: detectLocale(phrase), todayIso: today, logLabel: 'recur-check' });
  } catch (error) {
    // 访客连点时浏览器取消上一次导航 → request.signal abort → fetch 抛错。
    // 代理侧已给被取消的请求退额度,按 info 记,不和真正的上游不可达混在 error 里。
    if (request.signal.aborted) {
      console.log('recur-check: visitor left before upstream answered');
    } else {
      console.error('recur-check: upstream fetch failed', error);
    }
    return errorResult('Could not reach the service', 'The checking service did not respond. Nothing was saved — please try again in a moment.', 503);
  }

  if (upstream.status === 429) {
    // 与工具①共用配额,代理用 X-RateLimit-Type 区分两档:web_ip_daily(每天 3 次)
    // 与 web_velocity(每分钟 6 次)。用户侧含义完全不同,分开说。
    const rateType = upstream.headers.get('X-RateLimit-Type') || 'web_ip_daily';
    if (rateType === 'web_velocity') {
      return htmlResponse(toolResultPage({
        toolPath: TOOL_PATH,
        toolLabel: 'recurring reminder checker',
        heading: 'That was quick',
        bodyHtml: `<div class="card"><p style="margin:0">Several tries in a row — the page pauses for about a minute to keep things fair.
Nothing was saved; wait a moment and try again.</p></div>`,
        ct: CT,
      }));
    }
    return htmlResponse(toolResultPage({
      toolPath: TOOL_PATH,
      toolLabel: 'recurring reminder checker',
      heading: 'Daily tries used up',
      bodyHtml: `<div class="card"><p style="margin:0">You've used today's three tries across these tools. The counter resets tomorrow.
In the <strong>app</strong>, every capture runs this parse — with reminders, repeats and widgets on top.</p></div>`,
      ct: CT,
    }));
  }
  if (upstream.status === 503) {
    const errBody = await upstream.json().catch(() => ({}));
    if (errBody.error === 'global_budget_exceeded_web') {
      return htmlResponse(toolResultPage({
        toolPath: TOOL_PATH,
        toolLabel: 'recurring reminder checker',
        heading: 'Web quota used up for today',
        bodyHtml: `<div class="card"><p style="margin:0">This page's daily quota is finished. Come back tomorrow —
or continue in the <strong>app</strong>, where every capture runs this parse.</p></div>`,
        ct: CT,
      }));
    }
    console.error('recur-check: upstream 503', errBody);
    return errorResult('Service unavailable', 'The checking service is temporarily unavailable. Nothing was saved — please try again later.', 503);
  }
  if (upstream.status === 413) {
    return errorResult('Too long', 'Please shorten the phrase.');
  }
  if (upstream.status !== 200) {
    const detail = await upstream.text().catch(() => '');
    console.error('recur-check: upstream error', { status: upstream.status, detail: detail.slice(0, 500) });
    return errorResult('Check failed', 'The checking service returned an error. Nothing was saved — please try again in a moment.', 502);
  }

  const raw = await upstream.text();
  const parsed = parseExtraction(raw);
  if (!parsed.parseOk) {
    // 上游 200 但 JSON 坏:显式报错,不给用户一个空结果装正常。
    console.error('recur-check: unparseable upstream body', raw.slice(0, 500));
    return errorResult('Check failed', 'The checking service returned something unexpected. Nothing was saved — please try again.', 502);
  }

  const todos = Array.isArray(parsed.data.todos) ? parsed.data.todos : [];
  const recurring = todos
    .map((todo) => ({ title: String(todo.title || ''), rule: todo.recurrence_rule }))
    .filter((entry) => entry.rule && describeModelRecurrence(entry.rule));

  if (recurring.length === 0) {
    // 模型没给出任何重复规则:如实说 —— App 会把这些任务建成不重复的普通任务。
    // 这是「展示 App 实际行为」口径的一部分,不拿本地解析器编一个规则出来。
    const titles = todos.map((todo) => String(todo.title || '')).filter(Boolean);
    const listed = titles.length
      ? `<p class="note">It would be kept as a plain task${titles.length > 1 ? 's' : ''} without a repeat: ${titles.map((t) => `“${escapeHtml(t)}”`).join(', ')}.</p>`
      : '';
    const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(phrase)}”</p>
<div class="card"><p style="margin:0">No repeat in this phrase — nothing here would recur.</p></div>
${listed}
<p class="note">If you meant a repeat, name it explicitly (“every Monday”, “monthly on the 1st”, “every other week”) —
in the app you confirm the rule on the review card before anything is saved.</p>`;
    return htmlResponse(toolResultPage({
      toolPath: TOOL_PATH,
      toolLabel: 'recurring reminder checker',
      heading: 'No repeat in this phrase',
      bodyHtml,
      ct: CT,
    }));
  }

  const cards = recurring.map(({ title, rule }) => {
    const ruleText = describeModelRecurrence(rule);
    // 「接下来五次」的展开口径见 modelRuleOccurrences:interval>1 以第一个匹配日为锚
    // (App 端锚任务首个 dueDate,检查器没有任务,取第一个匹配日等价)。
    const dates = modelRuleOccurrences(rule, today, tz, 5);
    const listHtml = dates.map((d) => `<li>${escapeHtml(formatOccurrence(d))}</li>`).join('');
    return `<div class="card">
  ${title ? `<p class="todo-title">${escapeHtml(title)}</p>` : ''}
  <p class="note" style="margin:0 0 4px">VoiceTodo understands this as:</p>
  <p class="rule-text">${escapeHtml(ruleText)}</p>
  <p class="note" style="margin:0 0 10px">The next five times (${escapeHtml(tz)}):</p>
  <ul class="date-list">${listHtml}</ul>
</div>`;
  }).join('');
  const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(phrase)}”</p>
${cards}
<p class="note">In the app, saying this while capturing creates the task with the repeat already set —
no picker, no repeats menu. You confirm the rule on the review card before anything is saved.</p>`;
  return htmlResponse(toolResultPage({
    toolPath: TOOL_PATH,
    toolLabel: 'recurring reminder checker',
    heading: 'What your phrase means',
    bodyHtml,
    ct: CT,
  }));
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

// status 口径:客户端输入问题 400(默认);服务端故障(缺配置/上游不可达/
// 上游报错/坏响应)必须 5xx —— 错误显式传播,不把服务端故障伪装成客户端错。
function errorResult(heading, message, status = 400) {
  const bodyHtml = `<div class="card err"><p style="margin:0">${escapeHtml(message)}</p></div>`;
  return htmlResponse(
    toolResultPage({ toolPath: TOOL_PATH, toolLabel: 'recurring reminder checker', heading, bodyHtml, ct: CT }),
    status
  );
}
