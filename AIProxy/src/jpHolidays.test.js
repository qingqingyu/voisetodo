// jpHolidays.mjs 单测(任务书 docs/eval-ja-batch2-holidays-task.md §3/§8)。
// 跑法:cd AIProxy && npm test
//
// 基准数据 = 内閣府「国民の祝日・休日」CSV(https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv)
// 2026/2027 全量条目,2026-11-27 下载核对(与任务书按规则算的表逐条一致)。
// CSV 把振替休日/国民の休日统称「休日」——本表保留官方名称,断言时这两类只验日期。
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  jpHolidaysBetween, jpHolidayName, isJpBusinessDay, nthJpBusinessDayAfter,
  jpWeekStartBusinessDay, thisWeekFriday, nextJpHoliday,
} from "./jpHolidays.js";

/// 内閣府 CSV 2026/2027 全量(官方原文;「休日」= 振替休日或国民の休日)。
const OFFICIAL_CSV = [
  ["2026-01-01", "元日"], ["2026-01-12", "成人の日"], ["2026-02-11", "建国記念の日"],
  ["2026-02-23", "天皇誕生日"], ["2026-03-20", "春分の日"], ["2026-04-29", "昭和の日"],
  ["2026-05-03", "憲法記念日"], ["2026-05-04", "みどりの日"], ["2026-05-05", "こどもの日"],
  ["2026-05-06", "休日"], ["2026-07-20", "海の日"], ["2026-08-11", "山の日"],
  ["2026-09-21", "敬老の日"], ["2026-09-22", "休日"], ["2026-09-23", "秋分の日"],
  ["2026-10-12", "スポーツの日"], ["2026-11-03", "文化の日"], ["2026-11-23", "勤労感謝の日"],
  ["2027-01-01", "元日"], ["2027-01-11", "成人の日"], ["2027-02-11", "建国記念の日"],
  ["2027-02-23", "天皇誕生日"], ["2027-03-21", "春分の日"], ["2027-03-22", "休日"],
  ["2027-04-29", "昭和の日"], ["2027-05-03", "憲法記念日"], ["2027-05-04", "みどりの日"],
  ["2027-05-05", "こどもの日"], ["2027-07-19", "海の日"], ["2027-08-11", "山の日"],
  ["2027-09-20", "敬老の日"], ["2027-09-23", "秋分の日"], ["2027-10-11", "スポーツの日"],
  ["2027-11-03", "文化の日"], ["2027-11-23", "勤労感謝の日"],
];

test("jpHolidays: 2026/2027 与内閣府官方 CSV 全量一致(日期集合 + 具名祝日名称)", () => {
  for (const year of [2026, 2027]) {
    const ours = jpHolidaysBetween(`${year}-01-01`, `${year}-12-31`);
    assert.notEqual(ours, null, `${year} 应可计算`);
    const official = OFFICIAL_CSV.filter(([iso]) => iso.startsWith(String(year)));
    assert.deepEqual(
      ours.map((h) => h.iso),
      official.map(([iso]) => iso),
      `${year} 节假日日期集合必须与官方 CSV 逐条一致`
    );
    for (const [iso, name] of official) {
      const got = jpHolidayName(iso);
      if (name === "休日") {
        // 官方统称;本实现区分振替休日 / 国民の休日,只验「是休日且带这两类标签之一」
        assert.ok(got === "振替休日" || got === "国民の休日", `${iso} 应为 振替休日/国民の休日,得到 ${got}`);
        // 细分自证:2026-05-06 振替(5/3 周日)、2026-09-22 国民の休日(敬老の日と秋分の日に挟まれる)、
        // 2027-03-22 振替(3/21 春分の日 が日曜)——与任务书 §3 按规则算的表一致
        if (iso === "2026-05-06" || iso === "2027-03-22") assert.equal(got, "振替休日");
        if (iso === "2026-09-22") assert.equal(got, "国民の休日");
      } else {
        assert.equal(got, name, `${iso} 名称应为 ${name}`);
      }
    }
    // 年内没有多余条目(集合已 deepEqual 钉住;这里显式断言总数防 fixture 抄漏)
    assert.equal(ours.length, official.length);
  }
});

test("jpHolidays: 2000–2099 边界内可算、超界返回 null(注入侧按算不出兜底)", () => {
  assert.notEqual(jpHolidaysBetween("2000-01-01", "2000-12-31"), null);
  assert.notEqual(jpHolidaysBetween("2099-01-01", "2099-12-31"), null);
  assert.equal(jpHolidaysBetween("1999-12-01", "2000-01-31"), null);
  assert.equal(jpHolidaysBetween("2099-12-01", "2100-01-31"), null);
  assert.equal(isJpBusinessDay("2100-01-04"), null);
  assert.equal(nthJpBusinessDayAfter("2099-12-28", 5), null, "跨入 2100 算不出");
});

test("isJpBusinessDay: 周末/祝日/振替/国民の休日都不是营业日,平日才是", () => {
  assert.equal(isJpBusinessDay("2026-11-18"), true);  // 周三
  assert.equal(isJpBusinessDay("2026-11-21"), false); // 周六
  assert.equal(isJpBusinessDay("2026-11-22"), false); // 周日
  assert.equal(isJpBusinessDay("2026-11-23"), false); // 勤労感謝の日(周一)
  assert.equal(isJpBusinessDay("2026-05-06"), false); // 振替休日(周三)
  assert.equal(isJpBusinessDay("2026-09-22"), false); // 国民の休日(周二)
  // 年末年始(12/29–1/3)与お盆不是法定假日:平日照常营业(任务书 §1 拍板)
  assert.equal(isJpBusinessDay("2026-12-29"), true);
  assert.equal(isJpBusinessDay("2027-01-04"), true);
  assert.equal(isJpBusinessDay("2026-08-14"), true, "お盆期间(8/14 周五)不是法定假日,算营业日");
  assert.equal(isJpBusinessDay("2026-08-15"), false, "周六按周末,不按盆休");
  assert.equal(isJpBusinessDay("2026-08-17"), true, "盆休不在法定节假日表内");
});

/// §8.1 各锚期望值(Part B 单测 + 固定锚 eval 共用)。
const ANCHOR_VECTORS = [
  // [锚, 翌営業日, 3営業日, 5営業日, 15営業日, 週明け, 今週中, 次の勤労感謝の日, 次のスポーツの日]
  ["2026-01-07", "2026-01-08", "2026-01-13", "2026-01-15", "2026-01-29", "2026-01-13", "2026-01-09", "2026-11-23", "2026-10-12"],
  ["2026-04-29", "2026-04-30", "2026-05-07", "2026-05-11", "2026-05-25", "2026-05-07", "2026-05-01", "2026-11-23", "2026-10-12"],
  ["2026-09-16", "2026-09-17", "2026-09-24", "2026-09-28", "2026-10-13", "2026-09-24", "2026-09-18", "2026-11-23", "2026-10-12"],
  ["2026-11-18", "2026-11-19", "2026-11-24", "2026-11-26", "2026-12-10", "2026-11-24", "2026-11-20", "2026-11-23", "2027-10-11"],
  ["2027-01-06", "2027-01-07", "2027-01-12", "2027-01-14", "2027-01-28", "2027-01-12", "2027-01-08", "2027-11-23", "2027-10-11"],
];

test("任务书 §8.1:五个锚的 N営業日/週明け/今週中/次の祝日 全部期望值", () => {
  for (const [anchor, b1, b3, b5, b15, weekStart, friday, kinrou, sports] of ANCHOR_VECTORS) {
    assert.equal(nthJpBusinessDayAfter(anchor, 1), b1, `${anchor} 翌営業日`);
    assert.equal(nthJpBusinessDayAfter(anchor, 3), b3, `${anchor} 3営業日`);
    assert.equal(nthJpBusinessDayAfter(anchor, 5), b5, `${anchor} 5営業日`);
    assert.equal(nthJpBusinessDayAfter(anchor, 15), b15, `${anchor} 15営業日`);
    assert.equal(jpWeekStartBusinessDay(anchor), weekStart, `${anchor} 週明け`);
    assert.equal(thisWeekFriday(anchor), friday, `${anchor} 今週中`);
    assert.equal(nextJpHoliday(anchor, "勤労感謝の日"), kinrou, `${anchor} 次の勤労感謝の日`);
    assert.equal(nextJpHoliday(anchor, "スポーツの日"), sports, `${anchor} 次のスポーツの日`);
  }
});

test("任务书 §3:thisWeekFriday 周六=今天、周日=本周五;週明け 从周日数", () => {
  assert.equal(thisWeekFriday("2026-11-21"), "2026-11-21", "周六 → 今天");
  assert.equal(thisWeekFriday("2026-11-22"), "2026-11-27", "周日 → 本周五(周日起始的本周)");
  assert.equal(jpWeekStartBusinessDay("2026-11-22"), "2026-11-24", "周日说 週明け → 下周一(非节假日)");
  // 周五是节假日仍算周五(不顺延,任务书 §1)
  assert.equal(thisWeekFriday("2026-09-14"), "2026-09-18", "9/18 周五是普通日");
  assert.equal(thisWeekFriday("2026-11-16"), "2026-11-20", "11/20 周五");
  // 週明け 的「之后第一个周一」:周三说 → 下周一;周一说 → 次周一(撞节假日顺延)
  assert.equal(jpWeekStartBusinessDay("2026-11-16"), "2026-11-24", "周一说 週明け → 次周一 11/23 是勤労感謝の日 → 顺延 11/24");
});

test("任务书 §8.1:两个 10 营业日列表(注入内容与 eval 期望同源)", () => {
  const list = (iso) => Array.from({ length: 10 }, (_, i) => nthJpBusinessDayAfter(iso, i + 1));
  assert.deepEqual(list("2026-11-18"), [
    "2026-11-19", "2026-11-20", "2026-11-24", "2026-11-25", "2026-11-26",
    "2026-11-27", "2026-11-30", "2026-12-01", "2026-12-02", "2026-12-03",
  ]);
  assert.deepEqual(list("2026-04-29"), [
    "2026-04-30", "2026-05-01", "2026-05-07", "2026-05-08", "2026-05-11",
    "2026-05-12", "2026-05-13", "2026-05-14", "2026-05-15", "2026-05-18",
  ]);
});

test("nextJpHoliday: 含今天 / 名字不认识 → null;非法入参抛错", () => {
  assert.equal(nextJpHoliday("2026-11-23", "勤労感謝の日"), "2026-11-23", "今天就是该节假日 → 今天");
  assert.equal(nextJpHoliday("2026-01-07", "元の日"), null, "不存在的祝日名");
  assert.equal(nextJpHoliday("2026-01-07", "海の日"), "2026-07-20");
  assert.throws(() => nextJpHoliday("bad", "元日"), /非法/);
  assert.throws(() => nthJpBusinessDayAfter("2026-01-07", 0), /非法/);
  assert.throws(() => jpHolidaysBetween("bad", "2026-12-31"), /非法/);
});
