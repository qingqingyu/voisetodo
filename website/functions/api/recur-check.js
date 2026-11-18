// 工具页②(重复提醒说法检查器)的表单处理:原生 form POST → 服务端渲染结果页。
// 零客户端 JS:解析纯本地(functions/lib/recurrence.mjs,与 App 端
// RecurrenceRuleResolver.swift 同口径),不调代理、零模型成本,无配额。
import { resolveRecurrence, nextOccurrences, describeRule, formatOccurrence } from '../lib/recurrence.mjs';
import { isKnownTimezone, todayInZone } from '../lib/timezones.mjs';
import { toolResultPage, htmlResponse, escapeHtml } from '../lib/render.mjs';

const TOOL_PATH = '/tools/recurring-reminder-checker';
const CT = 'web-tool-recur-result';

export async function onRequestPost(context) {
  const { request } = context;

  const form = await readForm(request);
  if (form instanceof Response) return form;

  const phrase = (form.get('phrase') || '').trim().slice(0, 500);
  const tz = form.get('tz') || 'UTC';

  if (!phrase) {
    return errorResult('Nothing to check', 'Type or paste a phrase first — for example “remind me every Monday, Wednesday and Friday”.');
  }
  if (!isKnownTimezone(tz)) {
    return errorResult('Unknown timezone', 'Please pick a timezone from the list.');
  }

  const today = todayInZone(tz);
  const rule = resolveRecurrence(phrase, today);

  if (!rule) {
    const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(phrase)}”</p>
<div class="card">
  <p><strong>Not in the deterministic set.</strong> This phrasing isn't one of the repeat patterns the
  capture parser recognizes on its own — in the app it goes to the AI parser, which understands many
  more variations (“every other Tuesday”, “weekdays”, “on the 1st of each month”, …) and still shows
  you the result for confirmation before anything is saved.</p>
</div>
<p class="note">Phrases this checker does recognize on its own: “every day” / “daily”, “every Monday, Wednesday and Friday”,
“every month on the 1st”, plus the same forms in Chinese.</p>`;
    return htmlResponse(toolResultPage({
      toolPath: TOOL_PATH,
      toolLabel: 'recurring reminder checker',
      heading: 'Not a plain repeat pattern',
      bodyHtml,
      ct: CT,
    }));
  }

  const dates = nextOccurrences(rule, today, tz, 5);
  const listHtml = dates.map((d) => `<li>${escapeHtml(formatOccurrence(d))}</li>`).join('');
  const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(phrase)}”</p>
<div class="card">
  <p class="note" style="margin:0 0 4px">VoiceTodo understands this as:</p>
  <p class="rule-text">${escapeHtml(describeRule(rule))}</p>
  <p class="note" style="margin:0 0 10px">The next five times (${escapeHtml(tz)}):</p>
  <ul class="date-list">${listHtml}</ul>
</div>
<p class="note">In the app, saying this while capturing creates the task with the repeat already set —
no picker, no repeats menu. This page only reads the phrase; it never creates anything.</p>`;
  return htmlResponse(toolResultPage({
    toolPath: TOOL_PATH,
    toolLabel: 'recurring reminder checker',
    heading: 'What your phrase means',
    bodyHtml,
    ct: CT,
  }));
}

// ---------- 共用小件 ----------

async function readForm(request) {
  const contentType = request.headers.get('content-type') || '';
  if (!contentType.includes('application/x-www-form-urlencoded')) {
    return errorResult('Form error', 'This page expects a normal form submission. Please use the form on the tool page.');
  }
  try {
    return new URLSearchParams(await request.text());
  } catch (error) {
    console.error('recur-check: form parse failed', error);
    return errorResult('Form error', 'Could not read the form submission. Please go back and try again.');
  }
}

function errorResult(heading, message) {
  const bodyHtml = `<div class="card err"><p style="margin:0">${escapeHtml(message)}</p></div>`;
  return htmlResponse(
    toolResultPage({ toolPath: TOOL_PATH, toolLabel: 'recurring reminder checker', heading, bodyHtml, ct: CT }),
    400
  );
}
