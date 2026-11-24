// 重复规则解析器(Pages Function /api/recur-check 用)。
// ⚠️ 口径对齐 iOS 端 Protocols/Domain/RecurrenceRuleResolver.swift(v1 明确表达):
// 只认确定性写法,模糊表达在 App 里继续交给 dueHint / AI 解析。改 Swift 版时
// 必须同步改这里 —— 两边是同一套用户可见行为(官网工具页展示的解读 = App 的解读)。
// 差异说明:Swift 版的 endDate 起点会先过 TodoDueDateResolver 解析 dueHint,
// 这里没有那套日期解析器,起点退化为「今天」—— 对 "for the next N days" 这类
// 纯时长表达,起点本来就是今天,行为一致。

// Apple Calendar 惯例(与 prompt 规则 5、RecurrenceRule.swift 一致):
// Sunday=1, Monday=2, …, Saturday=7。
const WEEKDAY_NAMES = {
  1: 'Sunday',
  2: 'Monday',
  3: 'Tuesday',
  4: 'Wednesday',
  5: 'Thursday',
  6: 'Friday',
  7: 'Saturday',
};
const WEEKDAY_SHORT = {
  1: 'Sun',
  2: 'Mon',
  3: 'Tue',
  4: 'Wed',
  5: 'Thu',
  6: 'Fri',
  7: 'Sat',
};

// 英文星期词(Swift TodoDueDateResolver.englishWeekdays 同表)。
const ENGLISH_WEEKDAYS = [
  { tokens: ['sunday', 'sun'], value: 1 },
  { tokens: ['monday', 'mon'], value: 2 },
  { tokens: ['tuesday', 'tue', 'tues'], value: 3 },
  { tokens: ['wednesday', 'wed'], value: 4 },
  { tokens: ['thursday', 'thu', 'thur', 'thurs'], value: 5 },
  { tokens: ['friday', 'fri'], value: 6 },
  { tokens: ['saturday', 'sat'], value: 7 },
];

const CHINESE_WEEKDAYS = [
  { tokens: ['周日', '星期日', '礼拜日', '周天', '星期天', '礼拜天', '每周日', '每星期日'], value: 1 },
  { tokens: ['周一', '星期一', '礼拜一', '每周一', '每星期一'], value: 2 },
  { tokens: ['周二', '星期二', '礼拜二', '每周二', '每星期二'], value: 3 },
  { tokens: ['周三', '星期三', '礼拜三', '每周三', '每星期三'], value: 4 },
  { tokens: ['周四', '星期四', '礼拜四', '每周四', '每星期四'], value: 5 },
  { tokens: ['周五', '星期五', '礼拜五', '每周五', '每星期五'], value: 6 },
  { tokens: ['周六', '星期六', '礼拜六', '每周六', '每星期六'], value: 7 },
];

/// 英文短语包含判定(Swift containsEnglishPhrase 同口径):空格视为 \s+,
/// 两侧不允许紧邻其他拉丁字母(whole-word)。
/// 注意空格转换必须对裸空格做:Swift 侧 NSRegularExpression.escapedPattern 会
/// 把空格转义成 "\ " 再替换,JS 的等价转义字符类不含空格,直接替换 ' ' 即可。
function containsEnglishPhrase(lowerText, phrase) {
  const escaped = phrase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ /g, '\\s+');
  return new RegExp(`(?<![A-Za-z])${escaped}(?![A-Za-z])`).test(lowerText);
}

function firstRegexCapture(pattern, text) {
  const match = new RegExp(pattern).exec(text);
  return match ? match[1] : null;
}

/// 中文数字天数解析(Swift parseDayCount 同口径,一到三百六十五范围由调用方校验)。
function parseDayCount(raw) {
  if (/^\d+$/.test(raw)) return parseInt(raw, 10);
  const values = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (raw === '十') return 10;
  if (raw.includes('十')) {
    const parts = raw.split('十');
    const tens = values[parts[0][0]] ?? 1;
    const ones = parts.length > 1 && parts[1] ? (values[parts[1][0]] ?? 0) : 0;
    return tens * 10 + ones;
  }
  return values[raw[0]] ?? null;
}

function durationDays(text) {
  const compactText = text.replace(/ /g, '');
  const chinesePatterns = [
    '(?:(?:未来|接下来|接下来的|连续|连着|往后|之后的|未来的))([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天',
    '([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天(?:内|里|之内)',
  ];
  for (const pattern of chinesePatterns) {
    const value = firstRegexCapture(pattern, compactText);
    const days = value ? parseDayCount(value) : null;
    if (days !== null && days >= 1 && days <= 366) return days;
  }
  const lower = text.toLowerCase();
  const englishPatterns = [
    'over\\s+the\\s+next\\s+([0-9]{1,3})\\s+days',
    'for\\s+(?:the\\s+)?next\\s+([0-9]{1,3})\\s+days',
    'next\\s+([0-9]{1,3})\\s+days',
    'for\\s+([0-9]{1,3})\\s+days',
  ];
  for (const pattern of englishPatterns) {
    const value = firstRegexCapture(pattern, lower);
    if (value !== null) {
      const days = parseInt(value, 10);
      if (days >= 1 && days <= 366) return days;
    }
  }
  return null;
}

function isWeeklyExpression(text) {
  const lower = text.toLowerCase();
  return (
    text.includes('每周') ||
    text.includes('每星期') ||
    text.includes('每礼拜') ||
    containsEnglishPhrase(lower, 'every week') ||
    containsEnglishPhrase(lower, 'weekly') ||
    ENGLISH_WEEKDAYS.some((entry) => entry.tokens.some((token) => containsEnglishPhrase(lower, `every ${token}`)))
  );
}

function weekdayNumbers(text) {
  const values = CHINESE_WEEKDAYS.filter((entry) => entry.tokens.some((token) => text.includes(token))).map((entry) => entry.value);
  const lower = text.toLowerCase();
  for (const entry of ENGLISH_WEEKDAYS) {
    if (entry.tokens.some((token) => containsEnglishPhrase(lower, `every ${token}`) || containsEnglishPhrase(lower, token))) {
      values.push(entry.value);
    }
  }
  return [...new Set(values)].sort((a, b) => a - b);
}

function monthlyDay(text) {
  const lower = text.toLowerCase();
  const hasMonthlyCue =
    text.includes('每月') ||
    text.includes('每个月') ||
    containsEnglishPhrase(lower, 'every month') ||
    containsEnglishPhrase(lower, 'monthly');
  if (!hasMonthlyCue) return null;
  const patterns = [
    '每(?:个)?月\\s*(\\d{1,2})\\s*[号日]',
    'monthly\\s+on\\s+the\\s+(\\d{1,2})',
    'every\\s+month\\s+on\\s+the\\s+(\\d{1,2})',
  ];
  for (const pattern of patterns) {
    const value = firstRegexCapture(pattern, text);
    if (value === null) continue;
    const day = parseInt(value, 10);
    if (day >= 1 && day <= 31) return day;
  }
  return null;
}

function addDaysIso(isoDate, days) {
  const ms = Date.parse(`${isoDate}T00:00:00.000Z`) + days * 86400000;
  return new Date(ms).toISOString().slice(0, 10);
}

/// 解析一段话里的重复规则。
/// @param {string} text 用户输入(官网工具页单输入框,相当于 Swift 版 dueHint+title+detail 拼接)
/// @param {string} todayIso 参考日期 YYYY-MM-DD(调用方按时区算好传入)
/// @returns {{frequency: 'daily'|'weekly'|'monthly', weekdays?: number[], dayOfMonth?: number, endDate?: string}|null}
export function resolveRecurrence(text, todayIso) {
  const trimmed = String(text || '').trim();
  if (!trimmed) return null;
  const lower = trimmed.toLowerCase();
  const days = durationDays(trimmed);
  const endDate = days && days > 0 ? addDaysIso(todayIso, days - 1) : undefined;

  if (trimmed.includes('每天') || trimmed.includes('每日') ||
    containsEnglishPhrase(lower, 'every day') || containsEnglishPhrase(lower, 'daily')) {
    return { frequency: 'daily', endDate };
  }
  const monthly = monthlyDay(trimmed);
  if (monthly !== null) {
    return { frequency: 'monthly', dayOfMonth: monthly, endDate };
  }
  if (isWeeklyExpression(trimmed)) {
    const weekdays = weekdayNumbers(trimmed);
    if (weekdays.length > 0) {
      return { frequency: 'weekly', weekdays, endDate };
    }
  }
  return null;
}

/// 时区内的日历部件。epochMs 每步 +86400s 迭代:任何时区的偏移变化(<24h)
/// 都不会跳日/重日,日期严格逐日推进(与 App 端 Calendar 迭代语义一致)。
/// 格式化器由调用方构造传入(nextOccurrences 循环内最多 400 次调用,
/// 每轮 new 一个 Intl.DateTimeFormat 是纯浪费)。
function partsInZone(fmt, epochMs) {
  const parts = {};
  for (const p of fmt.formatToParts(new Date(epochMs))) parts[p.type] = p.value;
  const weekdayIndex = { Sun: 1, Mon: 2, Tue: 3, Wed: 4, Thu: 5, Fri: 6, Sat: 7 }[parts.weekday];
  return { iso: `${parts.year}-${parts.month}-${parts.day}`, weekday: weekdayIndex, day: parseInt(parts.day, 10) };
}

/// 未来 count 次出现日期(严格晚于 today,从明天起算 —— 「接下来 N 次」口径)。
/// weekly 的 interval>1(every two weeks)App 里由 AI 解析,本解析器不覆盖
/// (与 Swift v1 同口径),不会走到这里。
export function nextOccurrences(rule, todayIso, timeZone, count = 5) {
  const out = [];
  // 迭代以「今天 12:00 UTC + N 天」为锚:所有时区在任何偏移下都落在正确的日历日。
  const anchorMs = Date.parse(`${todayIso}T12:00:00.000Z`);
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short',
  });
  for (let k = 1; k <= 400 && out.length < count; k++) {
    const parts = partsInZone(fmt, anchorMs + k * 86400000);
    let match = false;
    if (rule.frequency === 'daily') match = true;
    else if (rule.frequency === 'weekly') match = rule.weekdays.includes(parts.weekday);
    else if (rule.frequency === 'monthly') match = parts.day === rule.dayOfMonth;
    if (match) {
      if (rule.endDate && parts.iso > rule.endDate) break;
      out.push(parts);
    }
  }
  return out;
}

const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export function formatOccurrence(parts) {
  const [, m, d] = parts.iso.split('-');
  return `${WEEKDAY_SHORT[parts.weekday]}, ${MONTH_SHORT[parseInt(m, 10) - 1]} ${parseInt(d, 10)}, ${parts.iso.slice(0, 4)}`;
}

function ordinal(n) {
  const rem100 = n % 100;
  if (rem100 >= 11 && rem100 <= 13) return `${n}th`;
  return `${n}${{ 1: 'st', 2: 'nd', 3: 'rd' }[n % 10] ?? 'th'}`;
}

/// 人话描述规则(工具页结果文案;英文站,只出英文)。
export function describeRule(rule) {
  let text;
  if (rule.frequency === 'daily') {
    text = 'Every day';
  } else if (rule.frequency === 'weekly') {
    const names = rule.weekdays.map((w) => WEEKDAY_NAMES[w]);
    if (names.length === 1) {
      text = `Every ${names[0]}`;
    } else {
      text = `Every ${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
    }
  } else {
    text = `Every month on the ${ordinal(rule.dayOfMonth)}`;
  }
  if (rule.endDate) {
    text += `, until ${rule.endDate}`;
  }
  return text;
}

/// 展开模型 recurrence_rule(prompt 规则 5 形状:{frequency, interval, weekdays,
/// day_of_month, end_date})的未来 count 次日期,供工具②渲染「接下来五次」。
/// 与 describeModelRecurrence 同源,都是模型输出(不是本地 resolveRecurrence 的
/// 规则形状)。口径:
/// - 起点严格晚于 today(「接下来」从明天起算,与 nextOccurrences 一致);
/// - interval>1 的 weekly/monthly 以「第一个匹配日」为锚,之后每 interval 个周期
///   出现一次 —— App 端重复系列的锚是任务首个 dueDate,检查器没有任务,取第一个
///   匹配日等价(文档需注明这是展示口径);
/// - daily interval N 从明天起每 N 天一次;weekly 无 weekdays 以明天为锚每 interval 周一次;
///   monthly 无 day_of_month 以明天的日号为锚,该日号不存在的月份(如 31 号小月)自然跳过;
/// - end_date(YYYY-MM-DD)之后的匹配日截断(模型规则 5b 的截止边界);
/// - 迭代上限 400 步,防畸形规则(如 weekday 不在任何日历日出现)死循环。
export function modelRuleOccurrences(rule, todayIso, timeZone, count = 5) {
  if (!rule || !rule.frequency) return [];
  const interval = Number(rule.interval) >= 2 ? Math.floor(Number(rule.interval)) : 1;
  const weekdays = Array.isArray(rule.weekdays) ? rule.weekdays.filter((w) => WEEKDAY_NAMES[w]) : [];
  const dayOfMonth = Number(rule.day_of_month);
  const hasDayOfMonth = Number.isInteger(dayOfMonth) && dayOfMonth >= 1 && dayOfMonth <= 31;
  const endIso = /^\d{4}-\d{2}-\d{2}$/.test(String(rule.end_date || '')) ? String(rule.end_date) : null;

  const anchorMs = Date.parse(`${todayIso}T12:00:00.000Z`);
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short',
  });
  // monthly 无 day_of_month 的锚日号:明天的日号(k=1 那天)
  const fallbackDay = rule.frequency === 'monthly' && !hasDayOfMonth
    ? partsInZone(fmt, anchorMs + 86400000).day
    : null;

  const out = [];
  let anchorK = null;   // interval>1 时第一个匹配日的步数
  let anchorIso = null; // monthly 用:月差按日历月算,需要第一个匹配日的 iso
  for (let k = 1; k <= 400 && out.length < count; k++) {
    const parts = partsInZone(fmt, anchorMs + k * 86400000);
    let match = false;
    if (rule.frequency === 'daily') {
      match = (k - 1) % interval === 0;
    } else if (rule.frequency === 'weekly') {
      match = weekdays.length > 0 ? weekdays.includes(parts.weekday) : (k - 1) % (7 * interval) === 0;
    } else if (rule.frequency === 'monthly') {
      match = hasDayOfMonth ? parts.day === dayOfMonth : parts.day === fallbackDay;
    }
    if (!match) continue;
    if (endIso && parts.iso > endIso) break;

    if (interval > 1 && anchorK !== null) {
      // 周期内过滤:weekly 按 7 天步长,monthly 按日历月差
      if (rule.frequency === 'weekly') {
        if ((k - anchorK) % (7 * interval) !== 0) continue;
      } else if (rule.frequency === 'monthly') {
        const monthsBetween = monthDiff(anchorIso, parts.iso);
        if (monthsBetween === null || monthsBetween % interval !== 0) continue;
      }
    }
    if (anchorK === null) {
      anchorK = k;
      anchorIso = parts.iso;
    }
    out.push(parts);
  }
  return out;
}

/// 两个 iso 日之间的日历月差(同日或前日为整月);无法构成整月关系返回 null
/// (monthly 匹配日本就同日号,理论上恒为整月,null 只兜畸形输入)。
function monthDiff(fromIso, toIso) {
  const [fy, fm, fd] = fromIso.split('-').map(Number);
  const [ty, tm, td] = toIso.split('-').map(Number);
  const months = (ty - fy) * 12 + (tm - fm);
  return td <= fd ? months : null;
}

/// 描述代理 extract 返回的 recurrence_rule(prompt 规则 5 的形状:
/// {frequency, interval, weekdays, day_of_month})。与 describeRule 的差异:
/// 模型可给 interval>1(every two weeks)和 weekly+空 weekdays —— 那是 AI
/// 解析的覆盖面,本地解析器(v1)不产出,但拆句工具页要能渲染。
export function describeModelRecurrence(rule) {
  if (!rule || !rule.frequency) return '';
  const interval = Number(rule.interval) >= 2 ? Number(rule.interval) : 1;
  const weekdays = Array.isArray(rule.weekdays) ? rule.weekdays.filter((w) => WEEKDAY_NAMES[w]) : [];
  if (rule.frequency === 'daily') {
    return interval === 1 ? 'Every day' : `Every ${interval} days`;
  }
  if (rule.frequency === 'weekly') {
    if (interval > 1) {
      if (weekdays.length === 0) return `Every ${interval} weeks`;
      return `Every ${interval} weeks on ${weekdayList(weekdays)}`;
    }
    return weekdays.length ? `Every ${weekdayList(weekdays)}` : 'Weekly';
  }
  if (rule.frequency === 'monthly') {
    const day = Number(rule.day_of_month);
    if (Number.isInteger(day) && day >= 1 && day <= 31) {
      return interval === 1 ? `Every month on the ${ordinal(day)}` : `Every ${interval} months on the ${ordinal(day)}`;
    }
    return interval === 1 ? 'Every month' : `Every ${interval} months`;
  }
  return '';
}

function weekdayList(weekdays) {
  const names = weekdays.map((w) => WEEKDAY_NAMES[w]);
  return names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}
