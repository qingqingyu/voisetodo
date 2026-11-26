// recurrence.mjs 单测:与 Swift RecurrenceRuleResolver 的 v1 行为对齐
// (AIProxy 侧无此测试义务 —— 这是官网工具页的展示口径,错了就是谎报产品行为)。
// 跑法:cd website && npm run test:functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveRecurrence, nextOccurrences, describeRule, formatOccurrence } from './recurrence.mjs';

// 参考日期固定:2026-11-18 是周三。
const TODAY = '2026-11-18';

test('daily:每天 / every day / daily', () => {
  assert.deepEqual(resolveRecurrence('每天喝水', TODAY), { frequency: 'daily', endDate: undefined });
  assert.deepEqual(resolveRecurrence('water the plants every day', TODAY), { frequency: 'daily', endDate: undefined });
  assert.deepEqual(resolveRecurrence('Daily standup', TODAY), { frequency: 'daily', endDate: undefined });
});

test('daily:whole-word 匹配,"daily" 不得命中 "ordinarily" 之类子串', () => {
  // "daily" 出现在其他单词内部时不算(dinnerdailies 之类的构造边界)
  assert.equal(resolveRecurrence('call Mr Dailyman about the order', TODAY), null);
});

test('daily:多词短语的空白容忍 —— 双空格/换行与单空格同口径(对齐 Swift \\s+ 语义)', () => {
  assert.deepEqual(resolveRecurrence('water the plants every  day', TODAY), { frequency: 'daily', endDate: undefined });
  assert.deepEqual(resolveRecurrence('water the plants every\nday', TODAY), { frequency: 'daily', endDate: undefined });
  assert.deepEqual(resolveRecurrence('gym every\tMonday', TODAY), { frequency: 'weekly', weekdays: [2], endDate: undefined });
});

test('weekly:every Monday, Wednesday and Friday → weekdays [2,4,6]', () => {
  assert.deepEqual(resolveRecurrence('gym every Monday, Wednesday and Friday', TODAY), {
    frequency: 'weekly',
    weekdays: [2, 4, 6],
    endDate: undefined,
  });
});

test('weekly:每周一周三周五(中文,完整写法)', () => {
  assert.deepEqual(resolveRecurrence('每周一周三周五去健身房', TODAY), {
    frequency: 'weekly',
    weekdays: [2, 4, 6],
    endDate: undefined,
  });
});

test('weekly:「每周一三五」缩写只命中周一 —— 与 Swift v1 同口径(多日连写在 App 里由 AI 解析)', () => {
  // Swift weekdayNumbers 按「周三」等完整 token 做 contains,「一三五」不含「周三」。
  // 官网工具页如实展示本地解析器的结果,不得比 App 更聪明。
  assert.deepEqual(resolveRecurrence('每周一三五去健身房', TODAY), {
    frequency: 'weekly',
    weekdays: [2],
    endDate: undefined,
  });
});

test('weekly:单日 every Tuesday', () => {
  assert.deepEqual(resolveRecurrence('take out trash every Tuesday', TODAY), {
    frequency: 'weekly',
    weekdays: [3],
    endDate: undefined,
  });
});

test('weekly:缩写 every Mon/Fri', () => {
  assert.deepEqual(resolveRecurrence('report every mon and fri', TODAY), {
    frequency: 'weekly',
    weekdays: [2, 6],
    endDate: undefined,
  });
});

test('weekly:"every week"/"weekly" 裸表达无星期 → 不解析(与 Swift v1 同口径)', () => {
  assert.equal(resolveRecurrence('team meeting every week', TODAY), null);
  assert.equal(resolveRecurrence('weekly review', TODAY), null);
});

test('monthly:monthly on the 15th / every month on the 1st / 每月1号', () => {
  assert.deepEqual(resolveRecurrence('pay rent monthly on the 1st', TODAY), {
    frequency: 'monthly',
    dayOfMonth: 1,
    endDate: undefined,
  });
  assert.deepEqual(resolveRecurrence('every month on the 15th, deep clean', TODAY), {
    frequency: 'monthly',
    dayOfMonth: 15,
    endDate: undefined,
  });
  assert.deepEqual(resolveRecurrence('每月28号还信用卡', TODAY), {
    frequency: 'monthly',
    dayOfMonth: 28,
    endDate: undefined,
  });
});

test('monthly:有 monthly 语境但无具体日 → 不解析(同 Swift)', () => {
  assert.equal(resolveRecurrence('monthly budget review', TODAY), null);
});

test('endDate:for the next 30 days(英文)', () => {
  const rule = resolveRecurrence('meds every day for the next 30 days', TODAY);
  // 2026-11-18 + 29 天 = 2026-12-17
  assert.deepEqual(rule, { frequency: 'daily', endDate: '2026-12-17' });
});

test('endDate:接下来七天(中文数字)', () => {
  const rule = resolveRecurrence('接下来七天每天打卡', TODAY);
  assert.deepEqual(rule, { frequency: 'daily', endDate: '2026-11-24' });
});

test('非重复表达 → null', () => {
  assert.equal(resolveRecurrence('call mom tomorrow', TODAY), null);
  assert.equal(resolveRecurrence('', TODAY), null);
  assert.equal(resolveRecurrence('   ', TODAY), null);
});

test('nextOccurrences:daily 从明天起连排 5 天', () => {
  const dates = nextOccurrences({ frequency: 'daily' }, TODAY, 'UTC');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-11-20', '2026-11-21', '2026-11-22', '2026-11-23']);
});

test('nextOccurrences:weekly 命中正确的星期(今天周三不算,从下一个命中日起)', () => {
  // 周一三五;2026-11-18 是周三 → 11-19(四)跳过,11-20(五)、11-23(一)…
  const dates = nextOccurrences({ frequency: 'weekly', weekdays: [2, 4, 6] }, TODAY, 'UTC');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-20', '2026-11-23', '2026-11-25', '2026-11-27', '2026-11-30']);
});

test('nextOccurrences:monthly 只取每月 5 号,2 月没有 30/31 号时跳过该月', () => {
  const dates = nextOccurrences({ frequency: 'monthly', dayOfMonth: 5 }, '2026-12-20', 'UTC');
  assert.deepEqual(dates.map((d) => d.iso), ['2027-01-05', '2027-02-05', '2027-03-05', '2027-04-05', '2027-05-05']);
  // 1 月 31 号:2 月没有 31 日 → 跳过,下一个是 3 月 31 日
  const skip = nextOccurrences({ frequency: 'monthly', dayOfMonth: 31 }, '2027-01-05', 'UTC');
  assert.deepEqual(skip.map((d) => d.iso), ['2027-01-31', '2027-03-31', '2027-05-31', '2027-07-31', '2027-08-31']);
});

test('nextOccurrences:endDate 截断', () => {
  const dates = nextOccurrences({ frequency: 'daily', endDate: '2026-11-20' }, TODAY, 'UTC');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-11-20']);
});

test('nextOccurrences:时区生效 —— 同一 UTC 时刻,东京已是次日', () => {
  // 锚点 2026-11-18T12:00Z:UTC 是 18 日,东京是 18 日 21 时(同日);
  // 选 2026-11-18T20:00Z 场景不行(锚点固定正午),改用洛杉矶验证跨日:
  // UTC 正午 = 洛杉矶凌晨 4 点,日期仍同;用东京 +1 天偏移验证迭代正确。
  const utc = nextOccurrences({ frequency: 'daily' }, '2026-11-18', 'UTC');
  const tokyo = nextOccurrences({ frequency: 'daily' }, '2026-11-18', 'Asia/Tokyo');
  assert.deepEqual(utc.map((d) => d.iso), tokyo.map((d) => d.iso));
});

test('describeRule / formatOccurrence 输出', () => {
  assert.equal(describeRule({ frequency: 'daily' }), 'Every day');
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [2] }), 'Every Monday');
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [2, 4, 6] }), 'Every Monday, Wednesday and Friday');
  assert.equal(describeRule({ frequency: 'monthly', dayOfMonth: 1 }), 'Every month on the 1st');
  assert.equal(describeRule({ frequency: 'monthly', dayOfMonth: 21 }), 'Every month on the 21st');
  assert.equal(describeRule({ frequency: 'monthly', dayOfMonth: 30 }), 'Every month on the 30th');
  assert.equal(describeRule({ frequency: 'daily', endDate: '2026-12-17' }), 'Every day, until 2026-12-17');
  const [first] = nextOccurrences({ frequency: 'weekly', weekdays: [2, 4, 6] }, TODAY, 'UTC');
  assert.equal(formatOccurrence(first), 'Fri, Nov 20, 2026');
});

test('describeRule 展示排序周一始:跨 Apple 编号边界(周日=1)不再周日在前', () => {
  // 回归(审计 2026-11-24 小问题):「Sat and Sun」解析与模型都给编号升序 [1,7],
  // 旧展示层原样输出「Every Sunday and Saturday」;周一始应为 Saturday 在前。
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [1, 7] }), 'Every Saturday and Sunday');
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [7, 1] }), 'Every Saturday and Sunday');
  // 乱序输入归一到周一始(Tue/Sun/Fri/Mon → Mon, Tue, Fri, Sun)
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [3, 1, 6, 2] }), 'Every Monday, Tuesday, Friday and Sunday');
  // 单日不受影响
  assert.equal(describeRule({ frequency: 'weekly', weekdays: [1] }), 'Every Sunday');
});

// —— 2026-11-24 增量:modelRuleOccurrences(模型规则展开,工具② AI 口径)——
// 2026-11-26 审计轮 2 追加:顶层 recurrence_end 的解析/求解/文案。
// 2026-11-26 双 review 修正追加:normalizeIsoDate(日历真实性与 Swift ICU 滚动)、
// unit 非字符串丢弃、超大 count 防炸。
import { modelRuleOccurrences, describeModelRecurrence, parseModelRecurrenceEnd, resolveModelRecurrenceEnd, describeModelRecurrenceEnd, modelRuleEndInfo, isIsoDate, normalizeIsoDate } from './recurrence.mjs';

test('model:weekly 多天 interval 1,起始日是今天时今天也列出(轮 3)', () => {
  // TODAY=2026-11-18 周三;weekdays [2,4,6]=周一三五,周三命中 → 从今天起
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 1, weekdays: [2, 4, 6], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-18', '2026-11-20', '2026-11-23']);
});

test('model:weekly interval 2 锚起始日,每两周一次', () => {
  // TODAY 周三;周二 [3] → 第一个匹配 11-24(dayFromStart=6,窗口 0),之后 12-08、12-22
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 2, weekdays: [3], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-24', '2026-12-08', '2026-12-22']);
});

test('model:daily interval 3 从起始日(今天)起每三天一次(轮 3 含今天)', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'daily', interval: 3, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-18', '2026-11-21', '2026-11-24']);
});

test('model:monthly day_of_month 从下个匹配月起算', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 1, weekdays: [], day_of_month: 15, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-15', '2027-01-15', '2027-02-15']);
});

test('model:monthly 31 号自动跳过短月', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 1, weekdays: [], day_of_month: 31, end_date: null },
    '2026-01-10', 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-01-31', '2026-03-31', '2026-05-31']);
});

test('model:monthly interval 2 按日历月差过滤(锚起始月,轮 3)', () => {
  // 起始月 = 11 月(无 startIso → 今天):12 月 monthIndex=1 奇数跳过,
  // 1 月 =2 命中,之后隔月 —— 与 EKRecurrenceRule 从 DTSTART 月数 interval 的口径一致
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 2, weekdays: [], day_of_month: 10, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2027-01-10', '2027-03-10', '2027-05-10']);
});

test('model:end_date 截断截止边界', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 1, weekdays: [4], day_of_month: null, end_date: '2026-11-25' },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-18', '2026-11-25'], '起始日今天(周三)与 11-25 在边界内;之后超出即停');
});

test('model:weekly 无 weekdays 从起始日每 interval 周一次(轮 3 含今天)', () => {
  // Swift dayDiff % (interval*7) == 0:起始日(今天)dayDiff=0 即首个出现
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 2, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-18', '2026-12-02', '2026-12-16']);
});

test('model:空规则 / 未知 frequency 返回空数组', () => {
  assert.deepEqual(modelRuleOccurrences(null, TODAY, 'UTC'), []);
  assert.deepEqual(modelRuleOccurrences({ frequency: 'yearly' }, TODAY, 'UTC', 3), []);
});

test('model:weekly interval 2 多 weekday 按起始日 7 天窗口展开(App occurs 同公式)', () => {
  // TODAY 周三 11-18(起始日);「每两周周一和周四」[2,5] → 起始日窗口(0)内:
  // 周四 11-19(dayFromStart=1)、周一 11-23(dayFromStart=5);窗口 2:周四 12-03
  // (dayFromStart=15)、周一 12-07;窗口 1(11-26 周四、11-30 周一)跳过 ——
  // 与 Swift RecurrenceRule.occurs 的 weekDiff % interval 完全一致。
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 2, weekdays: [2, 5], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-11-23', '2026-12-03']);
});

test('model:weekdays 含非整数元素判无效(App 解码 throw → 规则丢弃 → 普通任务)', () => {
  // Swift decodeIfPresent([Int]) 对 "2" / 2.5 直接 throw → 整条规则丢弃;
  // 检查器不得展示 App 建不出来的规则
  for (const weekdays of [['2'], [2.5], ['a'], [2, '3'], [true]]) {
    const rule = { frequency: 'weekly', interval: 1, weekdays, day_of_month: null, end_date: null };
    assert.deepEqual(modelRuleOccurrences(rule, TODAY, 'UTC', 2), [], `weekdays=${JSON.stringify(weekdays)}`);
    assert.equal(describeModelRecurrence(rule), '', `weekdays=${JSON.stringify(weekdays)}`);
  }
});

test('model:weekly interval 1 无 weekdays 判无效(App isValid false → 普通任务)', () => {
  const rule = { frequency: 'weekly', interval: 1, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(modelRuleOccurrences(rule, TODAY, 'UTC', 2), []);
  assert.equal(describeModelRecurrence(rule), '');
  // 越界 weekday 被静默过滤后同样落到无效(Swift init 过滤 1...7)
  const outOfRange = { frequency: 'weekly', interval: 1, weekdays: [9], day_of_month: null, end_date: null };
  assert.deepEqual(modelRuleOccurrences(outOfRange, TODAY, 'UTC', 2), []);
  // [9, 2] 过滤后剩 [2] → 有效,下周一展开
  const mixed = { frequency: 'weekly', interval: 1, weekdays: [9, 2], day_of_month: null, end_date: null };
  assert.deepEqual(modelRuleOccurrences(mixed, TODAY, 'UTC', 1).map((d) => d.iso), ['2026-11-23']);
});

test('model:展示排序周一始,不随模型给的编号升序(Sat and Sun → Saturday and Sunday)', () => {
  // 工具②现役路径(审计 2026-11-24 小问题):模型按 Apple 编号升序输出 weekdays,
  // [1,7] 原样渲染会是「Every Sunday and Saturday」;展示层须归一到周一始。
  const rule = { frequency: 'weekly', interval: 1, weekdays: [1, 7], day_of_month: null, end_date: null };
  assert.equal(describeModelRecurrence(rule), 'Every Saturday and Sunday');
  const fortnightly = { frequency: 'weekly', interval: 2, weekdays: [1, 7], day_of_month: null, end_date: null };
  assert.equal(describeModelRecurrence(fortnightly), 'Every 2 weeks on Saturday and Sunday');
  // 展示排序不影响展开:展开按日历日推进(周六先于周日出现在时间轴上)
  assert.deepEqual(modelRuleOccurrences(rule, TODAY, 'UTC', 2).map((d) => d.iso), ['2026-11-21', '2026-11-22']);
});

test('model:monthly day_of_month 0/40 判无效(App init 钳成 nil → isValid false)', () => {
  for (const day of [0, 40]) {
    const rule = { frequency: 'monthly', interval: 1, weekdays: [], day_of_month: day, end_date: null };
    assert.deepEqual(modelRuleOccurrences(rule, TODAY, 'UTC', 2), [], `day=${day}`);
    assert.equal(describeModelRecurrence(rule), '', `day=${day}`);
  }
});

test('model:interval 非整数/字符串判无效(App Int 解码 throw → 规则丢弃)', () => {
  for (const interval of ['2', 2.5, true]) {
    const rule = { frequency: 'weekly', interval, weekdays: [2], day_of_month: null, end_date: null };
    assert.deepEqual(modelRuleOccurrences(rule, TODAY, 'UTC', 2), [], `interval=${String(interval)}`);
    assert.equal(describeModelRecurrence(rule), '', `interval=${String(interval)}`);
  }
  // null interval 取默认 1(Swift decodeIfPresent ?? 1);0/负数被 max(1,·) 钳成 1
  const nullInterval = { frequency: 'daily', interval: null, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(modelRuleOccurrences(nullInterval, TODAY, 'UTC', 2).map((d) => d.iso), ['2026-11-18', '2026-11-19']);
  assert.equal(describeModelRecurrence(nullInterval), 'Every day');
  const zeroInterval = { frequency: 'daily', interval: 0, weekdays: [], day_of_month: null, end_date: null };
  assert.equal(describeModelRecurrence(zeroInterval), 'Every day');
});

test('model:monthly interval 4 自适应上限内出满五次(锚起始月,首个匹配隔 4 个月)', () => {
  // 「every 4 months on the 15th」,起始月 = 11 月:12 月~2 月 monthIndex 1-3 跳过,
  // 3 月 =4 命中,之后每 4 个月;第 5 次 2028-07-15 距起始 ~605 天,
  // 上限 31×interval×(count+1)=744 天内(旧的 400 步 / 527 步都不够)
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 4, weekdays: [], day_of_month: 15, end_date: null },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso),
    ['2027-03-15', '2027-07-15', '2027-11-15', '2028-03-15', '2028-07-15']);
});

test('model:畸形超大 interval 不死循环(硬顶 5000 步内返回)', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'daily', interval: 100000, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-18'], '起始日 dayFromStart=0 命中一次,之后 5000 步内无第二次');
});

test('model:UTC+12+ 时区(Auckland)不因锚点已是明天而晚一天/漏首次', () => {
  // 回归(2026-11-24 review):UTC 正午锚在 Pacific/Auckland(+12 冬 / +13 夏,白名单内
  // 唯一 ≥ +12 的时区)已是本地「明天」,本地「今天」= k=-1。轮 3 起起始日是今天
  // 时含今天:Auckland 的 today=11-18 必须列得出(k=-1),整体不得晚一天。
  const daily = { frequency: 'daily', interval: 1, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'Pacific/Auckland', 3).map((d) => d.iso),
    ['2026-11-18', '2026-11-19', '2026-11-20'],
    'daily 从本地今天(11-18)起连排三天'
  );
  // 2026-11-19 本身就是周四(weekdays 5=Thursday):不得漏报成下一周
  const thu = { frequency: 'weekly', interval: 1, weekdays: [5], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(thu, TODAY, 'Pacific/Auckland', 2).map((d) => d.iso),
    ['2026-11-19', '2026-11-26']
  );
  // UTC 对照:同一规则同一参考日,两个时区的日历日序列一致
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'UTC', 3).map((d) => d.iso),
    ['2026-11-18', '2026-11-19', '2026-11-20']
  );
});

test('model:间隔节奏相对起始日,UTC+12+ 时区与 UTC 同构', () => {
  // daily interval 3 / weekly interval 2 的节奏锚在起始日(本地今天)后,
  // UTC+12+ 时区与 UTC 的日期序列应完全一致(都是「今天起每 N 天/两周一次」)。
  const d3 = { frequency: 'daily', interval: 3, weekdays: [], day_of_month: null, end_date: null };
  const w2 = { frequency: 'weekly', interval: 2, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(d3, TODAY, 'Pacific/Auckland', 3).map((d) => d.iso),
    modelRuleOccurrences(d3, TODAY, 'UTC', 3).map((d) => d.iso),
    'daily interval 3:Auckland 与 UTC 同序'
  );
  assert.deepEqual(
    modelRuleOccurrences(w2, TODAY, 'Pacific/Auckland', 3).map((d) => d.iso),
    modelRuleOccurrences(w2, TODAY, 'UTC', 3).map((d) => d.iso),
    'weekly interval 2:Auckland 与 UTC 同序'
  );
});

// ---------- 顶层 recurrence_end:解析 / 求解 / 文案(2026-11-26 审计轮 2) ----------
// 口径 = Swift RecurrenceEnd(Protocols/Domain/RecurrenceEnd.swift)与
// RecurrenceEndResolver 的移植;TODAY 固定 2026-11-18(周三)。

test('parseModelRecurrenceEnd: 五种 kind 合法形状 + unit/scope 缺省', () => {
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'after_count', count: 30 }), { kind: 'after_count', count: 30, unit: 'day' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'after_count', count: 2, unit: 'week' }), { kind: 'after_count', count: 2, unit: 'week' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'weekday', weekday: 'Friday' }), { kind: 'weekday', weekday: 6, scope: 'this' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'weekday', weekday: 'mon', scope: 'next' }), { kind: 'weekday', weekday: 2, scope: 'next' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'month_end', scope: 'next' }), { kind: 'month_end', scope: 'next' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'day_of_month', day: 15 }), { kind: 'day_of_month', day: 15, scope: 'this' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'date', value: '2026-12-01' }), { kind: 'date', value: '2026-12-01' });
});

test('parseModelRecurrenceEnd: Swift decode 会 throw 的形状一律 null;非法 unit/scope 回落默认', () => {
  assert.equal(parseModelRecurrenceEnd(null), null);
  assert.equal(parseModelRecurrenceEnd('x'), null);
  assert.equal(parseModelRecurrenceEnd([1]), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'until_heat_death' }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'after_count', count: 0 }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'after_count', count: '3' }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'after_count', count: 2.5 }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'weekday', weekday: 'funday' }), null);
  // 数字不是字符串:Swift decode(String) throw → 整个 recurrence_end 丢弃
  assert.equal(parseModelRecurrenceEnd({ kind: 'weekday', weekday: 6 }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'day_of_month', day: 32 }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'date', value: '12/01/2026' }), null);
  // Swift 的 Unit(rawValue:) ?? .day / Scope(rawValue:) ?? .this:非法值回落默认,不判无效
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'after_count', count: 3, unit: 'fortnight' }), { kind: 'after_count', count: 3, unit: 'day' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'month_end', scope: 'sometime' }), { kind: 'month_end', scope: 'this' });
});

test('resolveModelRecurrenceEnd: after_count 三种 unit(含月末 clamp)', () => {
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 30, unit: 'day' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-17');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 2, unit: 'week' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-01');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 1, unit: 'month' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-18');
  // 1 月 31 日 +1 月 = 2 月 28 日(2026 非闰):Swift calendar.date(byAdding:.month) 的 clamp 语义
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 1, unit: 'month' }, { startIso: '2026-01-31', todayIso: TODAY }), '2026-02-28');
});

test('resolveModelRecurrenceEnd: weekday 含今天 / next / month_end / day_of_month clamp / date', () => {
  // TODAY 2026-11-18 是周三(Apple 4):Friday(this)=+2;Wednesday(this)=今天(含);
  // Monday(this)=+5 → 11-23;next Monday 再 +7 → 11-30(Swift daysUntil + 7 同式)
  assert.equal(resolveModelRecurrenceEnd({ kind: 'weekday', weekday: 6, scope: 'this' }, { startIso: TODAY, todayIso: TODAY }), '2026-11-20');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'weekday', weekday: 4, scope: 'this' }, { startIso: TODAY, todayIso: TODAY }), '2026-11-18');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'weekday', weekday: 2, scope: 'this' }, { startIso: TODAY, todayIso: TODAY }), '2026-11-23');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'weekday', weekday: 2, scope: 'next' }, { startIso: TODAY, todayIso: TODAY }), '2026-11-30');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'month_end', scope: 'this' }, { startIso: TODAY, todayIso: TODAY }), '2026-11-30');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'month_end', scope: 'next' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-31');
  // 本月 15 号已早于起始(18 号)→ 无效边界 null;next → 12-15
  assert.equal(resolveModelRecurrenceEnd({ kind: 'day_of_month', day: 15, scope: 'this' }, { startIso: TODAY, todayIso: TODAY }), null);
  assert.equal(resolveModelRecurrenceEnd({ kind: 'day_of_month', day: 15, scope: 'next' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-15');
  // 30 号在 2 月 clamp 到 28(2027 非闰)
  assert.equal(resolveModelRecurrenceEnd({ kind: 'day_of_month', day: 30, scope: 'next' }, { startIso: '2027-01-31', todayIso: '2027-01-31' }), '2027-02-28');
  assert.equal(resolveModelRecurrenceEnd({ kind: 'date', value: '2026-12-01' }, { startIso: TODAY, todayIso: TODAY }), '2026-12-01');
});

test('resolveModelRecurrenceEnd: 截止早于起始 → null(空规则守卫,镜像 Swift)', () => {
  assert.equal(resolveModelRecurrenceEnd({ kind: 'date', value: '2026-11-17' }, { startIso: TODAY, todayIso: TODAY }), null);
});

test('describeModelRecurrenceEnd: 五种 kind 的英文文案', () => {
  assert.equal(describeModelRecurrenceEnd({ kind: 'after_count', count: 30, unit: 'day' }), 'for 30 days');
  assert.equal(describeModelRecurrenceEnd({ kind: 'after_count', count: 1, unit: 'month' }), 'for 1 month');
  assert.equal(describeModelRecurrenceEnd({ kind: 'weekday', weekday: 6, scope: 'this' }), 'until Friday');
  assert.equal(describeModelRecurrenceEnd({ kind: 'weekday', weekday: 2, scope: 'next' }), 'until next Monday');
  assert.equal(describeModelRecurrenceEnd({ kind: 'month_end', scope: 'this' }), 'until the end of the month');
  assert.equal(describeModelRecurrenceEnd({ kind: 'month_end', scope: 'next' }), 'until the end of next month');
  assert.equal(describeModelRecurrenceEnd({ kind: 'day_of_month', day: 15, scope: 'this' }), 'until the 15th');
  assert.equal(describeModelRecurrenceEnd({ kind: 'day_of_month', day: 21, scope: 'next' }), 'until the 21st of next month');
  assert.equal(describeModelRecurrenceEnd({ kind: 'date', value: '2026-12-01' }), 'until Dec 1, 2026');
});

test('modelRuleOccurrences: structuredEndIso 截断;rule.end_date 绝对优先于结构化截止', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  // 截止 2026-11-20:起始日=今天含今天,剩 18/19/20 三条
  assert.equal(modelRuleOccurrences(daily, TODAY, 'UTC', 5, '2026-11-20').length, 3);
  // rule.end_date(11-22)比结构化截止(11-19)晚:按 rule.end_date 截 → 5 条(App 优先级,不取更早)
  assert.equal(modelRuleOccurrences({ ...daily, end_date: '2026-11-22' }, TODAY, 'UTC', 5, '2026-11-19').length, 5);
  // 无截止:满 5 条
  assert.equal(modelRuleOccurrences(daily, TODAY, 'UTC', 5).length, 5);
});

test('modelRuleEndInfo: 优先级 / 后缀 / 形状坏 = 无截止', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  const a = modelRuleEndInfo(daily, { kind: 'after_count', count: 30, unit: 'day' }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(a.iso, '2026-12-17');
  assert.equal(a.suffix, ', for 30 days');
  // rule.end_date 赢过结构化截止,后缀用绝对日期
  const b = modelRuleEndInfo({ ...daily, end_date: '2026-11-25' }, { kind: 'after_count', count: 30, unit: 'day' }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(b.iso, '2026-11-25');
  assert.equal(b.suffix, ', until Nov 25, 2026');
  // 形状坏(count 0):App (try? …) ?? nil 同口径 → 无截止,不影响规则
  const c = modelRuleEndInfo(daily, { kind: 'after_count', count: 0 }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(c.iso, null);
  assert.equal(c.suffix, '');
  // 解析成功但截止早于起始 → 无效边界,同样无截止无后缀
  const d = modelRuleEndInfo(daily, { kind: 'date', value: '2026-11-10' }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(d.iso, null);
  assert.equal(d.suffix, '');
});

test('isIsoDate: 严格 YYYY-MM-DD', () => {
  assert.equal(isIsoDate('2026-11-18'), true);
  assert.equal(isIsoDate('2026-11-4'), false);
  assert.equal(isIsoDate(null), false);
  assert.equal(isIsoDate(20261118), false);
});

// ---------- 双 review 修正(2026-11-26):normalizeIsoDate / unit 类型 / 超大 count ----------

test('normalizeIsoDate: Swift DateFormatter 同口径(实测锚)——域内日溢出滚动', () => {
  assert.equal(normalizeIsoDate('2026-11-18'), '2026-11-18');
  assert.equal(normalizeIsoDate(' 2026-11-18 '), '2026-11-18', '两端空白与 Swift trimming 同口径');
  assert.equal(normalizeIsoDate('2026-02-31'), '2026-03-03', '2月31 滚到 3月3(swift 实测:2026-03-03)');
  assert.equal(normalizeIsoDate('2026-02-30'), '2026-03-02', '2月30 滚到 3月2(swift 实测)');
  assert.equal(normalizeIsoDate('2026-02-29'), '2026-03-01', '非闰年 2月29 滚到 3月1(swift 实测)');
  assert.equal(normalizeIsoDate('2024-02-29'), '2024-02-29', '闰年 2月29 原样(swift 实测)');
  assert.equal(normalizeIsoDate('2026-04-31'), '2026-05-01', '4月31 滚到 5月1(swift 实测)');
  assert.equal(normalizeIsoDate('2026-12-31'), '2026-12-31');
});

test('normalizeIsoDate: 字段域外 = null(swift 实测:13 月 / 00 月 / 32 日 / 00 日全 nil)', () => {
  assert.equal(normalizeIsoDate('2026-13-01'), null);
  assert.equal(normalizeIsoDate('2026-00-10'), null);
  assert.equal(normalizeIsoDate('2026-01-32'), null);
  assert.equal(normalizeIsoDate('2026-02-00'), null);
  assert.equal(normalizeIsoDate('2026-12-32'), null);
  assert.equal(normalizeIsoDate('2026-2-05'), null, '非 2 位数字形状拒绝(Swift 可解析,官网从严:残差方向=少显示,记档)');
  assert.equal(normalizeIsoDate('12/01/2026'), null);
  assert.equal(normalizeIsoDate(null), null);
  assert.equal(normalizeIsoDate(0), null);
});

test('parseModelRecurrenceEnd(双 review 修正): unit 非字符串 → 整个丢弃(Swift decode throw 同口径)', () => {
  assert.equal(parseModelRecurrenceEnd({ kind: 'after_count', count: 5, unit: 3 }), null);
  assert.equal(parseModelRecurrenceEnd({ kind: 'after_count', count: 5, unit: true }), null);
  // 非法字符串与缺省仍回落 day( Swift Unit(rawValue:) ?? .day / decodeIfPresent nil)
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'after_count', count: 5, unit: 'fortnight' }), { kind: 'after_count', count: 5, unit: 'day' });
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'after_count', count: 5, unit: null }), { kind: 'after_count', count: 5, unit: 'day' });
});

test('parseModelRecurrenceEnd(双 review 修正): date value 按真实日历日归一', () => {
  assert.deepEqual(parseModelRecurrenceEnd({ kind: 'date', value: ' 2026-02-31 ' }), { kind: 'date', value: '2026-03-03' });
  assert.equal(parseModelRecurrenceEnd({ kind: 'date', value: '2026-13-01' }), null);
});

test('resolveModelRecurrenceEnd(双 review 修正): 超大 count 不炸(RangeError→500 已修),按无截止', () => {
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 999999999, unit: 'day' }, { startIso: TODAY, todayIso: TODAY }), null);
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 999999999, unit: 'week' }, { startIso: TODAY, todayIso: TODAY }), null);
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 999999999, unit: 'month' }, { startIso: TODAY, todayIso: TODAY }), null);
  // 畸形 start 无法界定边界 → 无截止(不静默换今天)
  assert.equal(resolveModelRecurrenceEnd({ kind: 'after_count', count: 3 }, { startIso: '2026-13-01', todayIso: TODAY }), null);
});

test('modelRuleEndInfo(双 review 修正): rule.end_date 13 月 → nil 让位结构化;2月31 滚动', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  // end_date 13 月:Swift decodeEndDate parse nil → endDate nil → 结构化截止生效
  const a = modelRuleEndInfo({ ...daily, end_date: '2026-13-01' }, { kind: 'date', value: '2026-12-01' }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(a.iso, '2026-12-01');
  assert.equal(a.suffix, ', until Dec 1, 2026');
  // end_date 2月30:Swift 滚动成 3月2,绝对优先照旧
  const b = modelRuleEndInfo({ ...daily, end_date: '2026-02-30' }, { kind: 'after_count', count: 30, unit: 'day' }, { startIso: TODAY, todayIso: TODAY });
  assert.equal(b.iso, '2026-03-02');
  assert.equal(b.suffix, ', until Mar 2, 2026');
  // date kind 值 2月31 → 滚动 3月3(起始在 2 月内才可见)
  const c = modelRuleEndInfo(daily, { kind: 'date', value: '2026-02-31' }, { startIso: '2026-02-01', todayIso: '2026-02-01' });
  assert.equal(c.iso, '2026-03-03');
  assert.equal(c.suffix, ', until Mar 3, 2026');
});

// ---------- 轮 3(2026-11-26):起始日 startIso —— 展开起点与 interval 锚 ----------
// 背景:截止(recurrence_end)早已按 due_date 求解,但「Upcoming dates」的展开
// 仍从明天盲列 —— 起始日在未来时列出的全是 App 不会生成的日期
// (occurs(on:startDate:) 第一行 guard day >= start)。App 端所有锚(daily 步长 /
// weekly 窗口 / monthly 月差)都从 startDate 起算,展开须用同一个起始日。

test('model 轮3:daily 起始日在未来 + for 3 days → 从起始日起列,截止截断(用户主案)', () => {
  // 「每天,持续 3 天,从 12 月 14 日开始」:start=12-14,end=12-16(after_count 3 day)
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(daily, TODAY, 'UTC', 5, '2026-12-16', '2026-12-14');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-14', '2026-12-15', '2026-12-16'],
    '起始日之前的 11-19…12-01 不是系列成员,不得出现');
});

test('model 轮3:weekly 起始日在未来 → 从起始日起列,不再多列起始日之前的周', () => {
  // 「every Monday starting Dec 14」:12-14 是周一;旧口径会从明天(11-19)起
  // 多列出 11-23、11-30、12-07 这些 App 不会生成的日期
  const monday = { frequency: 'weekly', interval: 1, weekdays: [2], day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(monday, TODAY, 'UTC', 5, null, '2026-12-14');
  assert.deepEqual(dates.map((d) => d.iso),
    ['2026-12-14', '2026-12-21', '2026-12-28', '2027-01-04', '2027-01-11']);
});

test('model 轮3:startIso 显式传今天 → 含今天(与缺省 todayIso 同值)', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'UTC', 2, null, TODAY).map((d) => d.iso),
    modelRuleOccurrences(daily, TODAY, 'UTC', 2, null, null).map((d) => d.iso)
  );
  assert.equal(modelRuleOccurrences(daily, TODAY, 'UTC', 2, null, TODAY)[0].iso, TODAY);
});

test('model 轮3:起始日已过去 → 保持「明天起」的既有口径', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(daily, TODAY, 'UTC', 3, null, '2026-11-10');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-11-20', '2026-11-21']);
});

test('model 轮3:起始日在过去时 interval 锚起始日,不再锚「第一个匹配日」', () => {
  // 起始 11-14(周六),every 2 weeks on Wednesday:App 窗口从 11-14 起算 ——
  // 11-25(周三)在窗口 1,不是系列成员;第一个 upcoming = 12-02(窗口 2)。
  // 旧口径锚「第一个匹配日 11-25」会错列 11-25、12-09、12-23。
  const wed = { frequency: 'weekly', interval: 2, weekdays: [4], day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(wed, TODAY, 'UTC', 3, null, '2026-11-14');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-02', '2026-12-16', '2026-12-30']);
});

test('model 轮3:起始日在未来时 weekly interval>1 的窗口锚起始日', () => {
  // 「每两周周一和周四,从 12-16(周三)开始」:窗口 0 = 12-16…12-22,
  // 周四 12-17(dayFromStart=1)与周一 12-21(=5)都出现;窗口 2:12-31、01-04
  const monThu = { frequency: 'weekly', interval: 2, weekdays: [2, 5], day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(monThu, TODAY, 'UTC', 4, null, '2026-12-16');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-17', '2026-12-21', '2026-12-31', '2027-01-04']);
});

test('model 轮3:monthly interval 锚起始月 —— 起始月内晚于起始日的匹配日不丢', () => {
  // 「每 3 个月的 5 号,从 12 月 1 日开始」:12-05 的 monthIndex=0(同月)命中。
  // 旧 monthDiff 对「同月晚于锚日」返回 null,会把起始月内的 12-05 整个丢掉。
  const fifth = { frequency: 'monthly', interval: 3, weekdays: [], day_of_month: 5, end_date: null };
  const dates = modelRuleOccurrences(fifth, TODAY, 'UTC', 5, null, '2026-12-01');
  assert.deepEqual(dates.map((d) => d.iso),
    ['2026-12-05', '2027-03-05', '2027-06-05', '2027-09-05', '2027-12-05']);
});

test('model 轮3:startIso 形状坏回落今天(与 recur-check 调用方同值,双保险)', () => {
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'UTC', 2, null, '2026-13-01').map((d) => d.iso),
    ['2026-11-18', '2026-11-19']
  );
});

test('model 轮3:daily interval 从起始日起每 N 天一次(未来起始日)', () => {
  // 「每 3 天,从 12 月 20 日开始」:12-20、12-23、12-26(不是从明天 11-19 起算)
  const d3 = { frequency: 'daily', interval: 3, weekdays: [], day_of_month: null, end_date: null };
  const dates = modelRuleOccurrences(d3, TODAY, 'UTC', 3, null, '2026-12-20');
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-20', '2026-12-23', '2026-12-26']);
});

test('model 轮3:UTC+12+(Auckland)× 起始日在未来 → shift 与 beginK 抵消,首条=起始日', () => {
  // Auckland 的 anchor 已是本地明天(shift=1),未来起始日 12-14 的 beginK =
  // diffDays(today, 12-14) - 1 = 25,本地日 = today + 1 + 25 = 12-14,dayFromStart=0。
  // 若 beginK 漏掉 -shift,首条会变成 12-15(整体晚一天)。
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'Pacific/Auckland', 2, null, '2026-12-14').map((d) => d.iso),
    ['2026-12-14', '2026-12-15']
  );
});

test('model 轮3:UTC+12+(Auckland)× 起始日在过去 → 本地明天起,interval 锚起始日', () => {
  // 起始 11-10(过去 8 天):列表从本地明天 11-19 起(shift=1 → beginK=0),
  // daily interval 4 的 dayFromStart 锚 11-10 —— 明天 11-19 距起始 9 天,
  // 9 % 4 ≠ 0 不命中,首条 = dayFromStart 12 的 11-22、次条 16 的 11-26。
  // 若错锚「明天」(旧口径),首条会误列 11-19。
  const d4 = { frequency: 'daily', interval: 4, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(d4, TODAY, 'Pacific/Auckland', 2, null, '2026-11-10').map((d) => d.iso),
    ['2026-11-22', '2026-11-26']
  );
});

test('model 轮3:起始日 9999-12-30 + 截止 9999-12-31 → 迭代不得越过 ISO 四位年份域', () => {
  // 轮 3 双 review 探针实证的边界:迭代跨过 9999-12-31 后 formatter 产出五位年份
  // "10000-01-01",其字典序小于 "9999-12-31" —— 无域闸时 endIso 的字符串比较
  // 静默失效,会照列 10000-01-01/02/03 这些截止后、App 不会生成的日期。
  const daily = { frequency: 'daily', interval: 1, weekdays: null, day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'Pacific/Auckland', 5, '9999-12-31', '9999-12-30').map((d) => d.iso),
    ['9999-12-30', '9999-12-31'],
    '截止在 9999-12-31:恰好两条,不得越过 ISO 四位年份域继续列'
  );
  // 无截止时同样受域闸保护:最多列到 9999-12-31,不出 "10000-…"
  const beyond = modelRuleOccurrences(daily, TODAY, 'UTC', 5, null, '9999-12-25');
  assert.ok(beyond.every((d) => d.iso <= '9999-12-31'), '任何输出不得超出四位年份域');
  assert.ok(beyond.length > 0, '域内日期正常列出');
});
