// 工具页①(一句话拆多条提醒)的表单处理:原生 form POST → 服务端调代理
// web 档(/v1/web/todo-extractions)→ 渲染结果页。零客户端 JS。
// 鉴权:X-Web-Token 只存在于 Pages 环境变量与代理 secret,浏览器拿不到;
// 访客 IP 用 CF-Connecting-IP 转发(代理按它限流:3 次/天/IP)。
// 配置(都在 Pages 项目设置里):
//   AI_PROXY_ORIGIN  代理基地址,如 https://ai.example.org
//   WEB_EXTRACT_TOKEN  与代理 `wrangler secret put WEB_EXTRACT_TOKEN` 同值
import { resolveFormTimezone, todayInZone } from '../lib/timezones.mjs';
import { describeModelRecurrence, modelRuleEndInfo, normalizeIsoDate } from '../lib/recurrence.mjs';
import { toolResultPage, htmlResponse, escapeHtml } from '../lib/render.mjs';
import { detectLocale, readForm, isSameOriginForm, requireWebEnv, fetchWebExtraction, parseExtraction, normalizeTodos, plainTitle } from '../lib/web-extract.mjs';

const TOOL_PATH = '/tools/add-multiple-reminders-at-once';
const CT = 'web-tool-split-result';
const MAX_INPUT_CHARS = 1000;
const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export async function onRequestPost(context) {
  const { request, env } = context;

  const form = await readForm(request);
  if (!form) {
    return errorResult('Form error', 'Could not read the form submission. Please use the form on the tool page.');
  }
  if (!isSameOriginForm(request)) {
    // 跨站表单会烧掉访客 IP 的共享配额:挡掉(与 recur-check.js 同口径)。
    return errorResult('Form error', 'Could not read the form submission. Please use the form on the tool page.', 403);
  }

  const text = (form.get('text') || '').trim();
  // tz 默认 auto:服务端按 request.cf.timezone 解析(美西傍晚 "tomorrow" 不再错一天)。
  const { tz } = resolveFormTimezone(form.get('tz'), request);

  if (!text) {
    return errorResult('Nothing to split', 'Type a sentence first — for example “call the dentist tomorrow at 9, send the report by Friday, pay rent on the 1st every month”.');
  }
  if (text.length > MAX_INPUT_CHARS) {
    return errorResult('Too long', `Please keep it under ${MAX_INPUT_CHARS} characters (you sent ${text.length}).`);
  }
  if (!tz) {
    return errorResult('Unknown timezone', 'Please pick a timezone from the list.');
  }
  if (!requireWebEnv(env)) {
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
    upstream = await fetchWebExtraction(env, request, { text, locale: detectLocale(text), todayIso: today, logLabel: 'split' });
  } catch (error) {
    // 访客连点时浏览器取消上一次导航 → request.signal abort → fetch 抛错。这是修复
    // 「连点烧光额度」后的预期路径(代理侧已给被取消的请求退额度),按 info 记,
    // 不和真正的上游不可达混在 error 里。
    if (request.signal.aborted) {
      console.log('split: visitor left before upstream answered');
    } else {
      console.error('split: upstream fetch failed', error);
    }
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
      // 额度与检查器工具共用(代理按 IP 计数,两工具同桶):文案说「across these
      // tools」,不能说「from this page」—— 用掉的三次可能发生在另一个工具页。
      bodyHtml: `<div class="card"><p style="margin:0">You've used today's three tries across these tools. The counter resets tomorrow.
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
        // global_budget_exceeded_web 是全 web 档的全局预算(所有访客合计),
        // 不是本页也不是本 IP 的额度:文案按「web 工具的共享额度」说。
        bodyHtml: `<div class="card"><p style="margin:0">The web tools' shared budget for today is used up. Come back tomorrow —
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

  const todos = normalizeTodos(parsed.data);
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

  // whenText 每任务只算一次(2026-11-26 审计轮 2 双 review:此前 rows/copyLines/
  // hasTiming 各自重算,含 modelRuleEndInfo 求解,同一请求最多跑两遍)。
  const whens = todos.map((todo) => whenText(todo, today));
  const rows = todos.map((todo, i) => todoRow(todo, whens[i])).join('');
  const copyLines = todos.map((todo, i) => copyLine(todo, whens[i])).join('\n');
  // 标题与尾注按「是否真有日期显示」措辞(2026-11-26 审计轮 2):basis 过滤后全部
  // 任务都没日期时,标题不能再写 "and dated",尾注也不能说 "with the dates shown above"。
  // 判据与 whenText 的日期显示同源(normalizeIsoDate + user_explicit),标题永远
  // 不会和行内日期互相矛盾;due_date 经 normalizeIsoDate 归一(2月31 滚动、13月
  // 丢弃,Swift 解码层同口径),行内显示的就是归一后的真实日历日。
  const anyDateShown = todos.some((todo) => normalizeIsoDate(todo.due_date) && todo.due_date_basis === 'user_explicit');
  // 时区线索(2026-11-26 审计轮 2):tz=Auto 时挂 VPN 的用户会被解析到出口时区,
  // "tomorrow" 可能差一天而页面此前没有任何线索;工具②的「Upcoming dates」带时区
  // 标注,这里对齐。只在确有时间信息(日期/钟点/时段/重复)时出现,纯标题列表不打扰。
  const hasTiming = whens.some(Boolean);
  const ignored = typeof parsed.data.ignored === 'string' ? parsed.data.ignored.trim() : '';
  const ignoredHtml = ignored
    ? `<p class="note">Not kept as tasks: “${escapeHtml(ignored)}”</p>`
    : '';
  const bodyHtml = `
<p class="you-said">You said: “${escapeHtml(text)}”</p>
<div class="card">${rows}</div>
${hasTiming ? `<p class="note">Dates for ${escapeHtml(tz)}.</p>` : ''}
${ignoredHtml}
<h2>Copy your list</h2>
<label class="note" for="copybox">Select all and copy (no button needed):</label>
<textarea class="copy-box" id="copybox" readonly rows="${Math.min(12, todos.length + 1)}">${escapeHtml(copyLines)}</textarea>
<p class="note">This page only splits the sentence. Reminders, repeats, widgets and Siri capture live in the app —
${anyDateShown ? 'everything you confirm there is saved with the dates shown above.' : 'everything you confirm there is saved with its dates and reminders.'}</p>`;
  return htmlResponse(toolResultPage({
    toolPath: TOOL_PATH,
    toolLabel: 'sentence splitter',
    heading: `${todos.length === 1 ? '1 task' : `${todos.length} tasks`}, split${anyDateShown ? ' and dated' : ''}`,
    bodyHtml,
    ct: CT,
  }));
}

// ---------- 渲染小件 ----------

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

function whenText(todo, todayIso) {
  const parts = [];
  // App 端拿到结果后会跑 applyDueDateBasisFilter(Store/SwiftDataModels.swift:425):
  // due_date_basis 非 user_explicit 的日期会被清掉或改用 transcript 兜底重算;
  // user_explicit 但原文没有时间线索的也会被清。官网取简化口径:非 user_explicit
  // 一律不显示日期,钟点/时段/提醒照常(App 端清日期时保留这两样)。两个已知偏差,
  // 都要移植整段 hasExplicitTimeCue 探测器才能判(任务书级取舍):
  // - user_explicit + 原文无 cue:App 清日期,网页仍显示 → 网页多显示;
  // - title_mention/inferred/nil + 原文有 cue:App 按 transcript 重算日期保留,
  //   网页隐藏 → 网页少显示(重算结果可能与模型日期不同,不显示不构成超承诺)。
  // due_date 先过 normalizeIsoDate(2026-11-26 审计轮 2 双 review):Swift 解码层
  // 把日期串变成真实日历日(2月31 滚动、13月丢弃),网页显示与 App 同一个日子,
  // 也不再出现 "Feb 31" 这种不存在的日期。
  const dueIso = normalizeIsoDate(todo.due_date);
  if (dueIso && todo.due_date_basis === 'user_explicit') parts.push(formatDueDate(dueIso));
  if (todo.due_time) parts.push(formatTime(todo.due_time));
  if (!todo.due_time && todo.time_bucket) parts.push(String(todo.time_bucket));
  if (Array.isArray(todo.reminder_times) && todo.reminder_times.length > 0) {
    parts.push(`reminders at ${todo.reminder_times.map(formatTime).filter(Boolean).join(', ')}`);
  }
  const recurrence = describeModelRecurrence(todo.recurrence_rule);
  if (recurrence) {
    // 截止也带出来(2026-11-26 审计轮 2,与工具②同源):App 会把顶层 recurrence_end /
    // 模型 end_date 写进 RecurrenceRule.endDate,复制文本与行内文案同口径。
    // start 取归一后的 due_date ?? todayIso(检查器简化,见 modelRuleEndInfo 注释)。
    const { suffix } = modelRuleEndInfo(todo.recurrence_rule, todo.recurrence_end, {
      startIso: dueIso ?? todayIso,
      todayIso,
    });
    parts.push(recurrence + suffix);
  }
  // 模型输出偶发畸形日期/时间会产出空段,过滤掉避免拼出尾随「 · 」。
  return parts.filter(Boolean).join(' · ');
}

function todoRow(todo, when) {
  return `<div class="todo-row">
  <span class="todo-title">${escapeHtml(plainTitle(todo))}</span>
  ${when ? `<span class="todo-when">${escapeHtml(when)}</span>` : '<span class="todo-when">no date</span>'}
</div>`;
}

function copyLine(todo, when) {
  const title = plainTitle(todo);
  return when ? `${title} — ${when}` : title;
}

// ---------- 共用小件 ----------

// status 口径:客户端输入问题 400(默认);服务端故障(缺配置/上游不可达/
// 上游报错/坏响应)必须 5xx —— 错误显式传播,不把服务端故障伪装成客户端错。
function errorResult(heading, message, status = 400) {
  const bodyHtml = `<div class="card err"><p style="margin:0">${escapeHtml(message)}</p></div>`;
  return htmlResponse(
    toolResultPage({ toolPath: TOOL_PATH, toolLabel: 'sentence splitter', heading, bodyHtml, ct: CT }),
    status
  );
}
