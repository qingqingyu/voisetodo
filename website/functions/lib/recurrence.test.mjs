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
import { modelRuleOccurrences, describeModelRecurrence } from './recurrence.mjs';

test('model:weekly 多天 interval 1,第一个匹配日严格晚于 today', () => {
  // TODAY=2026-11-18 周三;weekdays [2,4,6]=周一三五 → 下一个周五 11-20
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 1, weekdays: [2, 4, 6], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-20', '2026-11-23', '2026-11-25']);
});

test('model:weekly interval 2 以第一个匹配日为锚,每两周一次', () => {
  // TODAY 周三;周二 [3] → 第一个匹配 11-24,之后 12-08、12-22
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 2, weekdays: [3], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-24', '2026-12-08', '2026-12-22']);
});

test('model:daily interval 3 从明天起每三天一次', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'daily', interval: 3, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-11-22', '2026-11-25']);
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

test('model:monthly interval 2 按日历月差过滤', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 2, weekdays: [], day_of_month: 10, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-12-10', '2027-02-10', '2027-04-10']);
});

test('model:end_date 截断截止边界', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 1, weekdays: [4], day_of_month: null, end_date: '2026-11-25' },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-25'], '周三 11-25 在边界内;之后超出即停');
});

test('model:weekly 无 weekdays 以明天为锚每 interval 周一次', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'weekly', interval: 2, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 3
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19', '2026-12-03', '2026-12-17']);
});

test('model:空规则 / 未知 frequency 返回空数组', () => {
  assert.deepEqual(modelRuleOccurrences(null, TODAY, 'UTC'), []);
  assert.deepEqual(modelRuleOccurrences({ frequency: 'yearly' }, TODAY, 'UTC', 3), []);
});

test('model:weekly interval 2 多 weekday 按锚点 7 天窗口展开(App occurs 同公式)', () => {
  // TODAY 周三 11-18;「每两周周一和周四」[2,5] → 锚 = 周四 11-19;
  // 同窗口(锚后 7 天内)的周一 11-23 也出现;下一个窗口周四 12-03、周一 12-07;
  // 窗口 1(11-27 周四、11-30 周一)落在奇数窗口,跳过 —— 与 Swift
  // RecurrenceRule.occurs 的 weekDiff % interval 完全一致。
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
  assert.deepEqual(modelRuleOccurrences(nullInterval, TODAY, 'UTC', 2).map((d) => d.iso), ['2026-11-19', '2026-11-20']);
  assert.equal(describeModelRecurrence(nullInterval), 'Every day');
  const zeroInterval = { frequency: 'daily', interval: 0, weekdays: [], day_of_month: null, end_date: null };
  assert.equal(describeModelRecurrence(zeroInterval), 'Every day');
});

test('model:monthly interval 4 自适应上限内出满五次(400 步只够 3 次)', () => {
  // 「every 4 months on the 15th」:第 5 次 2028-04-15 距锚 516 天,超过旧 400 步上限
  const dates = modelRuleOccurrences(
    { frequency: 'monthly', interval: 4, weekdays: [], day_of_month: 15, end_date: null },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso),
    ['2026-12-15', '2027-04-15', '2027-08-15', '2027-12-15', '2028-04-15']);
});

test('model:畸形超大 interval 不死循环(硬顶 5000 步内返回)', () => {
  const dates = modelRuleOccurrences(
    { frequency: 'daily', interval: 100000, weekdays: [], day_of_month: null, end_date: null },
    TODAY, 'UTC', 5
  );
  assert.deepEqual(dates.map((d) => d.iso), ['2026-11-19']);
});

test('model:UTC+12+ 时区(Auckland)不因锚点已是明天而晚一天/漏首次', () => {
  // 回归(2026-11-24 review):UTC 正午锚在 Pacific/Auckland(+12 冬 / +13 夏,白名单内
  // 唯一 ≥ +12 的时区)已是本地「明天」,固定从 k=1 起算会让全部日期整体晚一天、
  // 漏掉真实首次出现(实测修前 daily next3 = 11-20/21/22、weekly-Thu = 11-26)。
  const daily = { frequency: 'daily', interval: 1, weekdays: [], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'Pacific/Auckland', 3).map((d) => d.iso),
    ['2026-11-19', '2026-11-20', '2026-11-21'],
    'daily 首个未来日 = 明天(2026-11-19)'
  );
  // 2026-11-19 本身就是周四(weekdays 5=Thursday):不得漏报成下一周
  const thu = { frequency: 'weekly', interval: 1, weekdays: [5], day_of_month: null, end_date: null };
  assert.deepEqual(
    modelRuleOccurrences(thu, TODAY, 'Pacific/Auckland', 2).map((d) => d.iso),
    ['2026-11-19', '2026-11-26']
  );
  // UTC 对照:修复对既有语义零变化
  assert.deepEqual(
    modelRuleOccurrences(daily, TODAY, 'UTC', 3).map((d) => d.iso),
    ['2026-11-19', '2026-11-20', '2026-11-21']
  );
});

test('model:间隔节奏相对第一个未来日,startK=0 与 startK=1 同构', () => {
  // daily interval 3 / weekly interval 2 的节奏锚从 k=1 改为相对 startK 后,
  // UTC+12+ 时区与 UTC 的日期序列应完全一致(都是「明天起每 N 天/两周一次」)。
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
