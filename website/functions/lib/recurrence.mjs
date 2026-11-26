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
  // 超出 JS Date 表示范围(如 after_count 巨大 count)返回 null 而不是让
  // toISOString() 抛 RangeError(2026-11-26 审计轮 2 双 review:畸形 recurrence_end
  // 曾能把工具页打成 500,与 expandIpv6 判空同类)。Swift 端对应
  // calendar.date(byAdding:) 越界返回 nil → 无截止。
  const d = new Date(ms);
  return Number.isFinite(d.getTime()) ? d.toISOString().slice(0, 10) : null;
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

/// 展示层周内排序:周一始(ISO 顺序)。Apple 编号周日=1 最小,按编号排会把
/// 「Sat and Sun」显示成「Every Sunday and Saturday」(审计 2026-11-24 小问题);
/// 模型给的 weekdays 同样是编号升序(prompt 示例 [2,4,6],归一化亦排序),
/// 工具②切 AI 后问题仍在,须在展示层统一收口。只影响文案,不回写规则 ——
/// 规则内部表示(weekdayNumbers / Swift 对照)保持编号升序。
/// Apple→ISO 周序:Mon(2)→0、Tue(3)→1 … Sat(7)→5、Sun(1)→6。
function weekdayDisplayNameOrder(weekdays) {
  return [...weekdays].sort((a, b) => ((a + 5) % 7) - ((b + 5) % 7));
}

/// 人话描述规则(工具页结果文案;英文站,只出英文)。
export function describeRule(rule) {
  let text;
  if (rule.frequency === 'daily') {
    text = 'Every day';
  } else if (rule.frequency === 'weekly') {
    const names = weekdayDisplayNameOrder(rule.weekdays).map((w) => WEEKDAY_NAMES[w]);
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
/// day_of_month, end_date})的未来 count 次日期,供工具②渲染「Upcoming dates」。
/// 与 describeModelRecurrence 同源,都是模型输出(不是本地 resolveRecurrence 的
/// 规则形状)。口径(2026-11-26 轮 3 起以「系列起始日」为准,见 startIso 参数):
/// - 起始日在未来 → 从起始日起列;是今天 → 含今天(App 系列从今天就开始);
///   已过去 → 保持「明天起」的既有展示口径。App 端 occurs(on:startDate:) 第一行
///   就是 guard day >= start,起始日之前的日期一律不是系列成员,「从明天盲列」
///   会把 App 不会生成的日期说成会生成(轮 3 修复的主案);
/// - interval 的锚 = 系列起始日(不是第一个匹配日):App 端 occurs() 的
///   dayDiff / weekDiff 全部从 startDate 起算。起始日在过去、展开从明天开始时,
///   「第一个匹配日」可能落在与起始日奇偶不同的周窗口,以 App 为准锚起始日;
/// - weekly + weekdays + interval>1 的周期内过滤与 App 端
///   RecurrenceRule.occurs(on:startDate:)(Protocols/Domain/RecurrenceRule.swift:130)
///   同公式:weekDiff = 距起始日天数整除 7,weekDiff % interval == 0 —— 起始日后
///   同一个 7 天窗口内的所有 weekdays 都匹配(「每两周周一和周四」两条都出现),
///   不是只留锚 weekday;weekly 无 weekdays 从起始日每 interval*7 天一次
///   (Swift dayDiff % (interval*7) == 0 同式);
/// - monthly 无 day_of_month 被 isValidModelRule 判无效 —— App 端 isValid 同样丢弃,
///   下面的 fallbackDay 分支只是闸门未来放宽时的保留路径,当前不可达;
/// - monthly interval>1 按日历月差过滤、daily interval>1 按 N 天步长(都从起始日
///   起算)—— 注意 App 端 occurs() 对 monthly/daily 都忽略 interval
///   (RecurrenceRule.swift:145-152 的 monthly 分支不读 interval、daily 分支恒 true),
///   但 App 的系统日历镜像(SystemCalendarWriter.ekRecurrenceRule)把 interval 传给
///   EKRecurrenceRule:App 自身在 in-app 展开/日历镜像两边有张力。检查器取 interval
///   语义(与模型契约「每三天/每三个月」、日历镜像一致),月差按 EK 口径只数年月
///   (起始月为 0,见 monthIndex),此张力记为 App 侧既有问题。
/// - 截止截断(2026-11-26 审计轮 2 起):end_date(YYYY-MM-DD)之后的匹配日停;
///   另接受第 5 参 structuredEndIso —— 顶层 recurrence_end(规则 5b)经
///   resolveModelRecurrenceEnd 算出的截止。优先级镜像 App(Protocols/Models.swift:384
///   「模型 end_date(绝对)> 结构化 recurrence_end」):rule.end_date 有效则忽略
///   结构化截止,不取更早者。两路截止都经 normalizeIsoDate 归一(字段域校验 +
///   滚动,同 Swift DateFormatter)。形状坏的 recurrence_end = 无截止(App 端
///   (try? …) ?? nil 同口径),不影响规则有效性;
/// - 迭代上限自适应:400 步(≈13 个月)只够 monthly interval ≤ 3 出满五次,
///   按 count×周期放大(interval 锚在起始日后,首个匹配月最多隔 interval 个月,
///   上限按 31×interval×(count+1) 天),硬顶 5000 步防畸形规则(超大 interval)
///   拖垮 Function。
/// @param {string|null} startIso 系列起始日(任务首个 due_date,YYYY-MM-DD)。
///   null / 形状坏回落 todayIso —— 与 recur-check 调用方
///   normalizeIsoDate(todo.due_date) ?? today 同值,双保险。
export function modelRuleOccurrences(rule, todayIso, timeZone, count = 5, structuredEndIso = null, startIso = null) {
  if (!isValidModelRule(rule)) return [];
  const interval = Number(rule.interval) >= 2 ? Math.floor(Number(rule.interval)) : 1;
  // weekday 只留 1...7(与 Swift init 的静默过滤同口径;有效性闸门已拦掉
  // 非整数元素),过滤后必是数字,includes(parts.weekday) 可直接比较。
  const weekdays = Array.isArray(rule.weekdays) ? rule.weekdays.filter((w) => WEEKDAY_NAMES[w]) : [];
  const dayOfMonth = Number(rule.day_of_month);
  const hasDayOfMonth = Number.isInteger(dayOfMonth) && dayOfMonth >= 1 && dayOfMonth <= 31;
  // 两路截止都过 normalizeIsoDate(2026-11-26 审计轮 2 双 review):Swift 端
  // end_date 字符串在 decodeEndDate 里就走 DateFormatter(域校验+滚动),
  // "2026-13-01" → nil(无截止),不是原样字符串。
  const ruleEndIso = normalizeIsoDate(rule.end_date);
  const extraEndIso = normalizeIsoDate(structuredEndIso);
  const endIso = ruleEndIso ?? extraEndIso;

  // 系列起始日(轮 3):形状坏回落 todayIso —— recur-check 调用方已经先过
  // normalizeIsoDate(todo.due_date) ?? today,这里再兜一次防直传原始字符串。
  const start = normalizeIsoDate(startIso) ?? todayIso;

  const anchorMs = Date.parse(`${todayIso}T12:00:00.000Z`);
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short',
  });
  // 时区日偏移(2026-11-24 review 引入,轮 3 泛化):UTC 正午锚在偏移 ≥ +12 的
  // 时区(白名单内唯一 Pacific/Auckland,+12 冬 / +13 夏)已是本地「明天」,
  // 本地日 = todayIso + shift + k;其余时区 shift=0。(每步 +86400s 仍逐日推进:
  // 偏移变化 <24h,不会跳日/重日,见 partsInZone 注释。)
  const shift = partsInZone(fmt, anchorMs).iso > todayIso ? 1 : 0;
  // 列表起点:起始日在未来 → 起始日;是今天 → 含今天(轮 3 小案:App 系列从今天
  // 就开始,「Every day, for 3 days」今天起算应列满三天);已过去 → 明天
  // (保持既有「接下来」展示口径,起始日之前的成员本来就不该列)。
  const beginIso = start > todayIso ? start : start === todayIso ? todayIso : addDaysIso(todayIso, 1);
  const beginK = diffDays(todayIso, beginIso) - shift;
  // interval 锚偏移:距起始日的天数(起始日可在过去 → 可为负)。展开日恒 ≥ 起始日,
  // dayFromStart ≥ 0,无负数取模歧义。
  const anchorOffset = diffDays(todayIso, start);
  // monthly 无 day_of_month 的锚日号:第一个列出日的日号。当前闸门下 monthly 必有
  // 合法 day_of_month,此分支不可达,保留为闸门放宽时的既定语义。
  const fallbackDay = rule.frequency === 'monthly' && !hasDayOfMonth
    ? partsInZone(fmt, anchorMs + (beginK + shift) * 86400000).day
    : null;

  // 步长上限:monthly 首个匹配月最多隔 interval 个月(≈31×interval 天),之后每
  // 次匹配 ≤31×interval 天;interval=1 时保底 400(与 nextOccurrences 同档,
  // 不回退既有覆盖)。
  const stepCap = Math.min(Math.max(400, 31 * interval * (count + 1)), 5000);

  const out = [];
  for (let k = beginK; k < beginK + stepCap && out.length < count; k++) {
    const parts = partsInZone(fmt, anchorMs + k * 86400000);
    const dayFromStart = k + shift - anchorOffset;
    let match = false;
    if (rule.frequency === 'daily') {
      match = dayFromStart % interval === 0;
    } else if (rule.frequency === 'weekly') {
      // 有 weekdays:周几命中 + 周期内过滤(App occurs() 同公式:weekDiff 整除 7
      // 后 % interval);无 weekdays:从起始日每 interval*7 天一次(Swift 同式)。
      match = weekdays.length > 0
        ? weekdays.includes(parts.weekday) && Math.floor(dayFromStart / 7) % interval === 0
        : dayFromStart % (7 * interval) === 0;
    } else if (rule.frequency === 'monthly') {
      match = hasDayOfMonth ? parts.day === dayOfMonth : parts.day === fallbackDay;
      if (match && interval > 1) match = monthIndex(start, parts.iso) % interval === 0;
    }
    if (!match) continue;
    if (endIso && parts.iso > endIso) break;
    out.push(parts);
  }
  return out;
}

/// 两个 ISO 日的天数差(b - a)。两端都锚 UTC 正午再相减,差恒为 86400s 整数倍,
/// 不受任何时区偏移影响。
function diffDays(aIso, bIso) {
  return Math.round((Date.parse(`${bIso}T12:00:00.000Z`) - Date.parse(`${aIso}T12:00:00.000Z`)) / 86400000);
}

/// 日历月差(EKRecurrenceRule interval 口径):只数年月、不看日 —— 起始月为 0,
/// 每过一个日历月 +1,同月内先后不构成差。(旧 monthDiff 对「同月晚于锚日」返回
/// null,锚在起始日而非匹配日之后会把起始月内的匹配日整月丢掉,轮 3 修正;
/// 旧锚 = 第一个匹配日时两者数值恒等,不回退既有输出。)
function monthIndex(fromIso, toIso) {
  const [fy, fm] = fromIso.split('-').map(Number);
  const [ty, tm] = toIso.split('-').map(Number);
  return (ty - fy) * 12 + (tm - fm);
}

/// 模型 recurrence_rule 的有效性闸门 —— 镜像 App 端两道硬闸,凡 App 会丢弃
/// (变成普通任务)的规则,这里都判无效:
/// 1. 严格解码(RecurrenceRule.init(from:)):frequency 必须是 daily/weekly/monthly;
///    interval/weekdays/day_of_month 必须是 JSON 整数(字符串 "2"、小数 2.5 直接
///    decode throw → 整条规则丢弃);interval/weekdays/day_of_month 为 null 分别取
///    默认 1 / [] / nil;end_date 类型不对被 try? 容忍成 nil(规则仍有效);
/// 2. isValid(RecurrenceRule.swift:100-106):weekly 需 weekdays(钳到 1...7 后)
///    非空或 interval>1;monthly 需 dayOfMonth(钳到 1...31 后)非 nil —— 0/40 被
///    init 钳成 nil → 无效;daily 恒有效。
/// 周内 weekday 越界(如 9)不是解码错误:init 会静默过滤(weekdays [9,2] → [2] 仍有效)。
export function isValidModelRule(rule) {
  if (!rule || typeof rule !== 'object' || Array.isArray(rule)) return false;
  if (rule.frequency !== 'daily' && rule.frequency !== 'weekly' && rule.frequency !== 'monthly') return false;
  const intervalPresent = rule.interval !== null && rule.interval !== undefined;
  if (intervalPresent && !isPlainJsonInteger(rule.interval)) return false;
  const interval = intervalPresent ? rule.interval : 1;
  let weekdays = [];
  if (rule.weekdays !== null && rule.weekdays !== undefined) {
    if (!Array.isArray(rule.weekdays) || !rule.weekdays.every((w) => isPlainJsonInteger(w))) return false;
    weekdays = rule.weekdays.filter((w) => w >= 1 && w <= 7);
  }
  let dayOfMonth = null;
  if (rule.day_of_month !== null && rule.day_of_month !== undefined) {
    if (!isPlainJsonInteger(rule.day_of_month)) return false;
    const day = Number(rule.day_of_month);
    dayOfMonth = day >= 1 && day <= 31 ? day : null;
  }
  if (rule.frequency === 'weekly') return weekdays.length > 0 || interval > 1;
  if (rule.frequency === 'monthly') return dayOfMonth !== null;
  return true;
}

// JSON 整数判定:reject 字符串 "2" / 布尔 / 小数(Swift Int 解码语义),
// 超出安全整数范围同样 reject(Swift Int64 解码越界会 throw)。
// 注意布尔陷阱:Number(true) === 1 会漏判,必须先查 typeof。
function isPlainJsonInteger(value) {
  return typeof value === 'number' && Number.isInteger(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER;
}

/// 描述代理 extract 返回的 recurrence_rule(prompt 规则 5 的形状:
/// {frequency, interval, weekdays, day_of_month})。与 describeRule 的差异:
/// 模型可给 interval>1(every two weeks)和 weekly+空 weekdays —— 那是 AI
/// 解析的覆盖面,本地解析器(v1)不产出,但拆句工具页要能渲染。
/// 无效规则(isValidModelRule 为 false,App 端会丢弃建普通任务)返回 '',调用方
/// 据此走「没有重复」的诚实展示 —— 不替 App 展示它建不出来的规则。
export function describeModelRecurrence(rule) {
  if (!isValidModelRule(rule)) return '';
  const interval = Number(rule.interval ?? 1) >= 2 ? Math.floor(Number(rule.interval)) : 1;
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
  const names = weekdayDisplayNameOrder(weekdays).map((w) => WEEKDAY_NAMES[w]);
  return names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

// ---------- 顶层 recurrence_end(规则 5b):解析 / 求解 / 文案(2026-11-26 审计轮 2) ----------
// 审计背景:工具②/① 此前只读 todos[].recurrence_rule,顶层 recurrence_end 全程没碰 ——
// 页面自带示例 "meds every day for the next 30 days" 只显示 "Every day",截止被丢;
// "until Friday" 会列出截止之后的日期。以下三个导出把 App 端
// RecurrenceEnd + RecurrenceEndResolver(Protocols/Domain/RecurrenceEnd*.swift)移植过来,
// 展示与截断都用 App 真正会写进 RecurrenceRule.endDate 的那个截止。

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/// 严格 YYYY-MM-DD 判定(模型畸形日期防御,调用方据此回落今天)。
export function isIsoDate(value) {
  return ISO_DATE_RE.test(String(value ?? ''));
}

/// ISO 日期串 → 真实日历日归一(2026-11-26 审计轮 2 双 review 补):
/// Swift 端 DateFormatter("yyyy-MM-dd") 的解析语义(实测锚定)是 ICU 的
/// 「字段域校验 + 滚动解析」——月必须 1-12、日必须 1-31(越域 → nil),
/// 域内日溢出按月长滚进后续月份("2026-02-31"→03-03、"2026-04-31"→05-01)。
/// 纯形状正则会把 "2026-13-01" 放进文案渲染出 "undefined 1, 2026"、把
/// "2026-02-31" 原样显示 —— App 从不显示这些。所有作为「日期」消费的模型
/// 字段(due_date / rule.end_date / recurrence_end.date)都必须先过这里;
/// 归一失败(null)= Swift parseISODate 落 nil 的同口径:无该日期/无截止。
export function normalizeIsoDate(raw) {
  const s = String(raw ?? '').trim();
  if (!isIsoDate(s)) return null;
  const [y, m, d] = s.split('-').map(Number);
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  // 日溢出滚动:while 至多两轮(d ≤ 31,最短月 28)。不用 Date.UTC —— 它对
  // 0-99 年份有 1900+ 映射陷阱,Swift 无此行为。
  let yy = y, mm = m, dd = d;
  while (dd > daysInMonth(yy, mm)) {
    dd -= daysInMonth(yy, mm);
    mm += 1;
    if (mm > 12) { mm = 1; yy += 1; }
  }
  return ymdIso(yy, mm, dd);
}

/// weekday 名(含常见缩写,大小写不敏感)→ Apple 编号(1=周日…7=周六)。
/// 镜像 Swift RecurrenceEnd.weekdayNumber(from:)(走 TodoDueDateResolver.englishWeekdays)。
const WEEKDAY_NAME_TO_NUMBER = {
  sunday: 1, sun: 1,
  monday: 2, mon: 2,
  tuesday: 3, tue: 3, tues: 3,
  wednesday: 4, wed: 4,
  thursday: 5, thu: 5, thur: 5, thurs: 5,
  friday: 6, fri: 6,
  saturday: 7, sat: 7,
};

/// scope 归一化:Swift Scope(rawValue:) ?? .this —— 缺省/非法值回落 this,不是判无效。
function parseScope(raw) {
  return String(raw ?? 'this').toLowerCase() === 'next' ? 'next' : 'this';
}

/// 归一化模型顶层 recurrence_end。任何 Swift RecurrenceEnd.init(from:) 会 throw 的
/// 形状(unknown kind / count 非正整数 / weekday 名不认识 / day 越界 / value 非日期)
/// 返回 null —— App 端 decode 失败的口径是 (try? …) ?? nil:规则保留、无截止;
/// 这里同口径,不因此把任务判成「无重复」。unit/scope 的非法**字符串**按 Swift
/// 一样回落默认(day / this);unit 为非字符串类型时 Swift decodeIfPresent(String)
/// 会 throw → 整个 recurrence_end 丢弃(2026-11-26 审计轮 2 双 review 修正:此前
/// String() 强转保留了 App 没有的截止);scope 任意畸形都被 try? 吞 → this。
/// count/day 用严格整数判定(字符串 "3"、小数、布尔都是 decode throw)。
export function parseModelRecurrenceEnd(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  if (typeof raw.kind !== 'string') return null;
  const kind = raw.kind.trim().toLowerCase();
  if (kind === 'after_count') {
    if (!isPlainJsonInteger(raw.count) || raw.count <= 0) return null;
    if (raw.unit !== undefined && raw.unit !== null && typeof raw.unit !== 'string') return null;
    const unitRaw = raw.unit === undefined || raw.unit === null ? 'day' : raw.unit.toLowerCase();
    const unit = ['day', 'week', 'month'].includes(unitRaw) ? unitRaw : 'day';
    return { kind, count: raw.count, unit };
  }
  if (kind === 'weekday') {
    if (typeof raw.weekday !== 'string') return null;
    const weekday = WEEKDAY_NAME_TO_NUMBER[raw.weekday.trim().toLowerCase()];
    if (!weekday) return null;
    return { kind, weekday, scope: parseScope(raw.scope) };
  }
  if (kind === 'month_end') {
    return { kind, scope: parseScope(raw.scope) };
  }
  if (kind === 'day_of_month') {
    if (!isPlainJsonInteger(raw.day) || raw.day < 1 || raw.day > 31) return null;
    return { kind, day: raw.day, scope: parseScope(raw.scope) };
  }
  if (kind === 'date') {
    // Swift 形状层只查非空字符串,真伪在 resolver 的 parseISODate 落 nil;这里用
    // normalizeIsoDate 一步到位(2026-11-26 审计轮 2 双 review 修正:此前只过形状
    // 正则,"2026-13-01" 会渲染出 "until undefined 1, 2026"):字段域外(13 月/
    // 32 日)= 无截止,域内日溢出滚动("2026-02-31"→03-03)与 Swift 实测一致。
    if (typeof raw.value !== 'string') return null;
    const value = normalizeIsoDate(raw.value);
    return value === null ? null : { kind, value };
  }
  return null;
}

/// ISO 日历日的 weekday(Apple 编号 1=周日…7=周六)。todayIso 本就是调用方按时区
/// 算好的「本地今天」,它的星期几/年月是这一天自身的属性,与再套哪个时区无关
/// (UTC 正午锚只是取 UTC 日历视图,不会跨日)。
function weekdayOfIso(iso) {
  return new Date(Date.parse(`${iso}T12:00:00.000Z`)).getUTCDay() + 1;
}

function daysInMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function nextYearMonth(year, month) {
  return month === 12 ? [year + 1, 1] : [year, month + 1];
}

function ymdIso(year, month, day) {
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

/// 加 N 个日历月,日号按目标月天数 clamp(Swift calendar.date(byAdding:.month) 语义:
/// 1 月 31 日 +1 月 = 2 月 28/29 日)。
function addMonthsIso(iso, months) {
  const [y, m, d] = iso.split('-').map(Number);
  const total = y * 12 + (m - 1) + months;
  const [ny, nm] = [Math.floor(total / 12), (total % 12) + 1];
  return ymdIso(ny, nm, Math.min(d, daysInMonth(ny, nm)));
}

/// Swift RecurrenceEndResolver.resolve 的端口(全部确定性日历运算,不算错日期):
/// - after_count:end = start + (count-1) 天 / (count×7-1) 天 / count 个月(同日号);
/// - weekday:从「今天」起最近的该 weekday(含今天),scope=next 再 +7 天;
/// - month_end / day_of_month:本/下月的月末 / 第 day 天(按当月天数 clamp);
/// - date:照抄;
/// - 截止早于起始 = 无效边界 → null(Swift endDay >= startDay 守卫,防空规则)。
/// 与 App 的唯一口径差异:start 的取值。App = 模型 dueDate ?? 文本解析兜底 ?? 今天
/// (Protocols/Models.swift:377-383);官网没有文本解析器,调用方传
/// due_date ?? todayIso(带日期的短语模型几乎总给 due_date,残余偏差记结果文档)。
export function resolveModelRecurrenceEnd(end, { startIso, todayIso }) {
  if (!end) return null;
  // start 归一(2026-11-26 审计轮 2 双 review):Swift 的 start 永远是已解析的 Date
  // (解码层滚动/丢弃已发生);这里收的是字符串,同样先归一成真实日历日,
  // 畸形 start 无法界定边界 → 无截止(不静默换成今天,避免谎报)。
  const start = normalizeIsoDate(startIso);
  if (start === null) return null;
  let iso = null;
  if (end.kind === 'after_count') {
    // addDaysIso 对超大 count 返回 null(JS Date 表示范围外),镜像 Swift
    // calendar.date(byAdding:) 越界 nil → 无截止,而不是抛 RangeError 打 500。
    if (end.unit === 'day') iso = addDaysIso(start, end.count - 1);
    else if (end.unit === 'week') iso = addDaysIso(start, end.count * 7 - 1);
    else iso = addMonthsIso(start, end.count);
  } else if (end.kind === 'weekday') {
    const daysUntil = (end.weekday - weekdayOfIso(todayIso) + 7) % 7; // 0…6,0=今天(含)
    iso = addDaysIso(todayIso, daysUntil + (end.scope === 'next' ? 7 : 0));
  } else if (end.kind === 'month_end') {
    const [y, m] = todayIso.split('-').map(Number);
    const [ey, em] = end.scope === 'next' ? nextYearMonth(y, m) : [y, m];
    iso = ymdIso(ey, em, daysInMonth(ey, em));
  } else if (end.kind === 'day_of_month') {
    const [y, m] = todayIso.split('-').map(Number);
    const [ey, em] = end.scope === 'next' ? nextYearMonth(y, m) : [y, m];
    iso = ymdIso(ey, em, Math.min(end.day, daysInMonth(ey, em)));
  } else {
    iso = end.value;
  }
  // 出口统一归一:addMonthsIso 超大 count 会产 "NaN-NaN-NaN"、date kind 的 value
  // 已在 parse 层归一,这里再兜一次,保证出口要么是真实 ISO 日要么 null。
  const normalized = normalizeIsoDate(iso);
  // ISO 日期的字典序 = 日历序,直接比较即「endDay >= startDay」(空规则守卫)。
  return normalized !== null && normalized >= start ? normalized : null;
}

/// ISO 日期 → "Dec 1, 2026"(与 formatOccurrence 同一套月份缩写,不带星期)。
export function formatIsoDate(iso) {
  if (!ISO_DATE_RE.test(String(iso))) return String(iso);
  const [, m, d] = iso.split('-');
  return `${MONTH_SHORT[parseInt(m, 10) - 1]} ${parseInt(d, 10)}, ${iso.slice(0, 4)}`;
}

/// 截止的人话描述(英文站,只出英文):after_count 用时长口径("for 30 days"),
/// 其余用 "until …";scope=next 的三种都带 next 限定。
export function describeModelRecurrenceEnd(end) {
  if (!end) return null;
  if (end.kind === 'after_count') {
    const label = { day: 'day', week: 'week', month: 'month' }[end.unit];
    return `for ${end.count} ${end.count === 1 ? label : `${label}s`}`;
  }
  if (end.kind === 'weekday') {
    const name = WEEKDAY_NAMES[end.weekday];
    return end.scope === 'next' ? `until next ${name}` : `until ${name}`;
  }
  if (end.kind === 'month_end') {
    return end.scope === 'next' ? 'until the end of next month' : 'until the end of the month';
  }
  if (end.kind === 'day_of_month') {
    return end.scope === 'next' ? `until the ${ordinal(end.day)} of next month` : `until the ${ordinal(end.day)}`;
  }
  return `until ${formatIsoDate(end.value)}`;
}

/// 一站式:模型 rule + 顶层 recurrence_end → 有效截止与展示后缀。
/// 优先级镜像 App(Protocols/Models.swift:384-389):模型 rule.end_date(绝对)>
/// 结构化 recurrence_end(确定性算)> 无;recurrence_end 形状坏 = 无截止。
/// 返回 { iso, suffix }:iso = 有效截止日(null = 无截止,不截断);suffix = 带
/// 前导「, 」的后缀串('' = 不加)。iso 可直接传给 modelRuleOccurrences 第 5 参。
export function modelRuleEndInfo(rule, recurrenceEndRaw, { startIso, todayIso }) {
  // rule.end_date 过 normalizeIsoDate(2026-11-26 审计轮 2 双 review):对齐 Swift
  // decodeEndDate 的 DateFormatter 解析(13 月 → nil,2 月 31 → 滚动成真实日)。
  const ruleEndIso = normalizeIsoDate(rule?.end_date ?? null);
  const endObj = parseModelRecurrenceEnd(recurrenceEndRaw);
  const structuredIso = endObj ? resolveModelRecurrenceEnd(endObj, { startIso, todayIso }) : null;
  const iso = ruleEndIso ?? structuredIso;
  const suffix = ruleEndIso
    ? `, until ${formatIsoDate(ruleEndIso)}`
    : endObj && structuredIso
      ? `, ${describeModelRecurrenceEnd(endObj)}`
      : '';
  return { iso, suffix };
}
