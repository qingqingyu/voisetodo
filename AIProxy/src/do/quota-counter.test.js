// QuotaCounter DO 单元测试。
//
// 这里测的是"DO 类的纯逻辑"——用 fake storage 直接驱动,不需要起 Miniflare。
// DO 平台保证的输入串行化(并发安全)不在单测范围,要靠 Step 3 的 Miniflare
// 集成测试来验证(并发 N 个请求,断言 200 数量精确等于 min(limit, N))。
//
// 测试覆盖:
//   1. consume 基础语义:扣减、remaining 计算、首次写入触发 alarm
//   2. consume 到上限:allowed=false,used 不超限
//   3. consume amount > remaining:部分扣减(allowed=true, taken=remaining)
//   4. refund:正常递减 / 退到 0 删 key / 退多于 used 不变负
//   5. key/date 隔离:不同 key、不同日期互不影响
//   6. consume-rolling 滚动窗口:跨小时桶求和 / 打穿拒绝 / 老桶滚出恢复 / 边界
//   7. alarm 清理:保留今天+昨天,更早删除(滚动窗口需读昨天的桶)
//   8. 输入校验:无效 body / 缺字段 / 非法 date/hour/windowHours 都返回 400
//   9. inspect:只读查询
//  10. reset:测试用清零

import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { QuotaCounter, _testInternals } from "./quota-counter.js";

// MARK: - Fake DO infrastructure

class FakeStorage {
  constructor() {
    this.map = new Map();
    this.alarm = null;
  }
  get(key) {
    return Promise.resolve(this.map.get(key));
  }
  put(key, value) {
    this.map.set(key, value);
    return Promise.resolve();
  }
  delete(key) {
    this.map.delete(key);
    return Promise.resolve();
  }
  list() {
    return Promise.resolve(new Map(this.map));
  }
  getAlarm() {
    return Promise.resolve(this.alarm);
  }
  setAlarm(time) {
    this.alarm = time;
    return Promise.resolve();
  }
  deleteAlarm() {
    this.alarm = null;
    return Promise.resolve();
  }
}

class FakeDOState {
  constructor() {
    this.storage = new FakeStorage();
  }
}

function makeDO() {
  const state = new FakeDOState();
  const instance = new QuotaCounter(state, {});
  return { state, instance };
}

function postBody(path, body) {
  return new Request(`https://do.local${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
}

function getWithQuery(path, params) {
  const qs = new URLSearchParams(params).toString();
  return new Request(`https://do.local${path}?${qs}`, { method: "GET" });
}

async function consume(instance, body) {
  const response = await instance.fetch(postBody("/consume", body));
  return { status: response.status, body: await response.json() };
}

async function consumeRolling(instance, body) {
  const response = await instance.fetch(postBody("/consume-rolling", body));
  return { status: response.status, body: await response.json() };
}

async function refund(instance, body) {
  const response = await instance.fetch(postBody("/refund", body));
  return { status: response.status, body: await response.json() };
}

async function inspect(instance, params) {
  const response = await instance.fetch(getWithQuery("/inspect", params));
  return { status: response.status, body: await response.json() };
}

async function reset(instance, body) {
  const response = await instance.fetch(postBody("/reset", body));
  return { status: response.status, body: await response.json() };
}

// MARK: - consume 基础语义

test("consume 单次:扣减 1,首次写入触发 alarm", async () => {
  const { state, instance } = makeDO();
  const result = await consume(instance, { key: "device-A", date: "2026-07-26", limit: 100 });

  assert.equal(result.status, 200);
  assert.equal(result.body.allowed, true);
  assert.equal(result.body.used, 1);
  assert.equal(result.body.remaining, 99);
  assert.equal(result.body.limit, 100);
  assert.equal(result.body.taken, 1);

  // storage 落了带日期的 key
  const stored = await state.storage.get("2026-07-26:device-A");
  assert.deepEqual(stored, { used: 1 });

  // alarm 被设置(非 null 即可,具体时间由实现决定)
  assert.ok(state.storage.alarm !== null, "alarm should be set on first consume");
});

test("consume 不传 amount 默认扣 1", async () => {
  const { instance } = makeDO();
  const result = await consume(instance, { key: "d", date: "2026-07-26", limit: 5 });
  assert.equal(result.body.taken, 1);
  assert.equal(result.body.used, 1);
});

test("consume amount=3 一次扣 3", async () => {
  const { instance } = makeDO();
  const result = await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 3 });
  assert.equal(result.body.taken, 3);
  assert.equal(result.body.used, 3);
  assert.equal(result.body.remaining, 97);
});

// MARK: - 上限 / 超限

test("consume 到上限:第 limit+1 次拒绝", async () => {
  const { instance } = makeDO();
  for (let i = 0; i < 5; i++) {
    const r = await consume(instance, { key: "d", date: "2026-07-26", limit: 5 });
    assert.equal(r.body.allowed, true);
  }
  // 第 6 次
  const blocked = await consume(instance, { key: "d", date: "2026-07-26", limit: 5 });
  assert.equal(blocked.body.allowed, false);
  assert.equal(blocked.body.used, 5);
  assert.equal(blocked.body.remaining, 0);
  assert.equal(blocked.body.taken, 0);
});

test("consume amount > remaining 时部分扣减,allowed=true", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 98 });
  // remaining=2,扣 5 只能扣 2
  const result = await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 5 });
  assert.equal(result.body.allowed, true);
  assert.equal(result.body.taken, 2);
  assert.equal(result.body.used, 100);
  assert.equal(result.body.remaining, 0);
});

test("consume 在剩余 0 时再来 amount=5 直接拒绝(allowed=false)", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 1 });
  const result = await consume(instance, { key: "d", date: "2026-07-26", limit: 1, amount: 5 });
  assert.equal(result.body.allowed, false);
  assert.equal(result.body.taken, 0);
  assert.equal(result.body.used, 1);
});

// MARK: - refund

test("refund 正常递减", async () => {
  const { state, instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 5 });
  const result = await refund(instance, { key: "d", date: "2026-07-26", amount: 2 });
  assert.equal(result.body.refunded, 2);
  assert.equal(result.body.used, 3);
  const stored = await state.storage.get("2026-07-26:d");
  assert.deepEqual(stored, { used: 3 });
});

test("refund 不传 amount 默认退 1", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 3 });
  const result = await refund(instance, { key: "d", date: "2026-07-26" });
  assert.equal(result.body.refunded, 1);
  assert.equal(result.body.used, 2);
});

test("refund 退到 0 删 storage key,保持干净", async () => {
  const { state, instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 3 });
  const result = await refund(instance, { key: "d", date: "2026-07-26", amount: 3 });
  assert.equal(result.body.refunded, 3);
  assert.equal(result.body.used, 0);
  const stored = await state.storage.get("2026-07-26:d");
  assert.equal(stored, undefined);
});

test("refund amount > used 只退到 0,不变负", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 2 });
  const result = await refund(instance, { key: "d", date: "2026-07-26", amount: 99 });
  assert.equal(result.body.refunded, 2);
  assert.equal(result.body.used, 0);
});

test("refund 在 used=0 时 refunded=0 used=0,不报错", async () => {
  const { instance } = makeDO();
  const result = await refund(instance, { key: "d", date: "2026-07-26", amount: 5 });
  assert.equal(result.body.refunded, 0);
  assert.equal(result.body.used, 0);
});

// MARK: - key / date 隔离

test("不同 key 互不影响", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "device-A", date: "2026-07-26", limit: 100, amount: 5 });
  const rB = await consume(instance, { key: "device-B", date: "2026-07-26", limit: 100 });
  assert.equal(rB.body.used, 1);
  assert.equal(rB.body.remaining, 99);
});

test("不同日期互不影响(同 key)", async () => {
  const { instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 100 });
  // 同 key 但次日:应该完全独立
  const r2 = await consume(instance, { key: "d", date: "2026-07-27", limit: 100 });
  assert.equal(r2.body.allowed, true);
  assert.equal(r2.body.used, 1);
  assert.equal(r2.body.remaining, 99);
});

test("同 key 同日期 0 时跨日切换被允许(模拟跨日恢复)", async () => {
  const { instance } = makeDO();
  // 第一天打满
  for (let i = 0; i < 5; i++) {
    await consume(instance, { key: "d", date: "2026-07-26", limit: 5 });
  }
  const blocked = await consume(instance, { key: "d", date: "2026-07-26", limit: 5 });
  assert.equal(blocked.body.allowed, false);
  // 第二天同一个 key 又能用
  const next = await consume(instance, { key: "d", date: "2026-07-27", limit: 5 });
  assert.equal(next.body.allowed, true);
});

// MARK: - consume-rolling(滚动窗口)

test("consume-rolling 单次:计数落在当前小时桶,首次写入触发 alarm", async () => {
  const { state, instance } = makeDO();
  const result = await consumeRolling(instance, {
    key: "global-budget", hour: "2026-07-26T14", limit: 100, windowHours: 6
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.allowed, true);
  assert.equal(result.body.used, 1);
  assert.equal(result.body.remaining, 99);
  assert.equal(result.body.taken, 1);

  // storage 落的是小时桶 key(13 字符),不是日桶
  const stored = await state.storage.get("2026-07-26T14:global-budget");
  assert.deepEqual(stored, { used: 1 });
  assert.ok(state.storage.alarm !== null, "alarm should be set on first rolling consume");
});

test("consume-rolling 窗口求和:跨多个小时桶的计数一起算额度", async () => {
  const { instance } = makeDO();
  // 3 小时前的桶扣 3,当前小时默认 amount=1 → 窗口总和 4
  await consumeRolling(instance, { key: "g", hour: "2026-07-26T11", limit: 10, windowHours: 6, amount: 3 });
  const result = await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 10, windowHours: 6 });
  assert.equal(result.body.allowed, true);
  assert.equal(result.body.used, 4); // 3 + 1(本次 amount 默认 1)
  assert.equal(result.body.remaining, 6);
});

test("consume-rolling 窗口总和到上限:allowed=false 且不计数", async () => {
  const { state, instance } = makeDO();
  await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 2, windowHours: 6, amount: 2 });
  const blocked = await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 2, windowHours: 6 });
  assert.equal(blocked.body.allowed, false);
  assert.equal(blocked.body.used, 2);
  assert.equal(blocked.body.taken, 0);
  assert.deepEqual(await state.storage.get("2026-07-26T14:g"), { used: 2 }, "拒绝时不追加计数");
});

test("consume-rolling 老桶滚出窗口即恢复,窗口边界精确到 1 小时", async () => {
  const { instance } = makeDO();
  // windowHours=6, limit=1:14:00 打满并拒绝
  await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 1, windowHours: 6 });
  const blocked = await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 1, windowHours: 6 });
  assert.equal(blocked.body.allowed, false);

  // 19:00 的窗口 = [14:00..19:00],仍含 14:00 桶 → 拒绝
  const stillBlocked = await consumeRolling(instance, { key: "g", hour: "2026-07-26T19", limit: 1, windowHours: 6 });
  assert.equal(stillBlocked.body.allowed, false, "19:00 窗口仍覆盖 14:00 桶");

  // 20:00 的窗口 = [15:00..20:00],14:00 桶滚出 → 恢复
  const recovered = await consumeRolling(instance, { key: "g", hour: "2026-07-26T20", limit: 1, windowHours: 6 });
  assert.equal(recovered.body.allowed, true, "20:00 窗口不再含 14:00 桶");
});

test("consume-rolling 跨 UTC 日滚动:昨天的桶计入今天的窗口,滚出后回落", async () => {
  const { instance } = makeDO();
  // 昨天 23:00 扣 1(6h 窗口在 04:00 时覆盖昨天 23:00)
  await consumeRolling(instance, { key: "g", hour: "2026-07-25T23", limit: 1, windowHours: 6 });
  const at4 = await consumeRolling(instance, { key: "g", hour: "2026-07-26T04", limit: 1, windowHours: 6 });
  assert.equal(at4.body.allowed, false, "04:00 窗口 = [23:00..04:00],含昨天 23:00 桶");
  const at5 = await consumeRolling(instance, { key: "g", hour: "2026-07-26T05", limit: 1, windowHours: 6 });
  assert.equal(at5.body.allowed, true, "05:00 窗口 = [00:00..05:00],昨天 23:00 桶已滚出");
});

test("consume-rolling 不同 key 的窗口互不影响", async () => {
  const { instance } = makeDO();
  await consumeRolling(instance, { key: "global-budget", hour: "2026-07-26T14", limit: 1, windowHours: 6 });
  const other = await consumeRolling(instance, { key: "global-budget-pro", hour: "2026-07-26T14", limit: 1, windowHours: 6 });
  assert.equal(other.body.allowed, true);
});

test("consume-rolling hour 格式非法返回 400", async () => {
  const { instance } = makeDO();
  const cases = ["2026-07-26", "2026-07-26T7", "2026/07/26T14", ""];
  for (const hour of cases) {
    const r = await consumeRolling(instance, { key: "g", hour, limit: 10, windowHours: 6 });
    assert.equal(r.status, 400, `hour="${hour}" 应 400`);
    assert.equal(r.body.error, "invalid_hour");
  }
});

test("consume-rolling hour 日历语义非法(T99点/13月)返回 400 而非抛异常", async () => {
  const { instance } = makeDO();
  // 正则形状通过但 Date.parse 为 NaN:放行会让 hourBucketsEndingAt 里
  // new Date(NaN).toISOString() 抛 RangeError,DO 变 500 —— 必须在入口 400。
  // (V8 对「2 月 30 日」是宽松滚动解析不返回 NaN,落成隔离桶 key,不在拒绝范围)
  const cases = ["2026-07-26T99", "2026-13-01T10"];
  for (const hour of cases) {
    const r = await consumeRolling(instance, { key: "g", hour, limit: 10, windowHours: 6 });
    assert.equal(r.status, 400, `hour="${hour}" 应 400`);
    assert.equal(r.body.error, "invalid_hour");
  }
});

test("consume-rolling windowHours 非法(0/25/1.5/缺省)返回 400", async () => {
  const { instance } = makeDO();
  for (const windowHours of [0, 25, 1.5]) {
    const r = await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 10, windowHours });
    assert.equal(r.status, 400, `windowHours=${windowHours} 应 400`);
    assert.equal(r.body.error, "invalid_window_hours");
  }
  const missing = await consumeRolling(instance, { key: "g", hour: "2026-07-26T14", limit: 10 });
  assert.equal(missing.status, 400);
  assert.equal(missing.body.error, "invalid_window_hours");
});

test("hourBucketsEndingAt:索引 0 是当前桶,跨日/跨月正确回退", async () => {
  const { hourBucketsEndingAt } = _testInternals;
  const buckets = hourBucketsEndingAt("2026-07-26T02", 4);
  assert.deepEqual(buckets, ["2026-07-26T02", "2026-07-26T01", "2026-07-26T00", "2026-07-25T23"]);
  // 跨月边界:7 月 1 日 0 点回退 1 小时 = 6 月 30 日 23 点
  const monthEdge = hourBucketsEndingAt("2026-07-01T00", 2);
  assert.deepEqual(monthEdge, ["2026-07-01T00", "2026-06-30T23"]);
});

// MARK: - alarm

test("alarm 清理保留今天+昨天(滚动窗口还需读昨天的桶),更早的删除", async () => {
  const { state, instance } = makeDO();
  // 写入三个不同日期
  await consume(instance, { key: "d", date: "2026-07-24", limit: 100, amount: 1 });
  await consume(instance, { key: "d", date: "2026-07-25", limit: 100, amount: 1 });
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 1 });
  assert.equal(state.storage.map.size, 3);

  // 触发 alarm —— 假设今天是 2026-07-26
  // 用 fake timer 不必要,直接调用 alarm 方法,内部用 todayDateString() 决定清理边界
  // 我们临时 monkey-patch Date 来固定"今天"
  const realDate = Date;
  const fixedToday = new realDate("2026-07-26T12:00:00.000Z");
  globalThis.Date = class extends realDate {
    constructor(...args) {
      if (args.length === 0) {
        super(fixedToday.getTime());
      } else {
        super(...args);
      }
    }
    static now() {
      return fixedToday.getTime();
    }
  };

  try {
    await instance.alarm();
  } finally {
    globalThis.Date = realDate;
  }

  // 7-24 被清;7-25(昨天)、7-26(今天)留下 —— UTC 0 点后的滚动窗口
  // 仍要读昨天的小时桶,删昨天会让窗口被低估、熔断变松
  assert.equal(state.storage.map.has("2026-07-24:d"), false);
  assert.equal(state.storage.map.has("2026-07-25:d"), true);
  assert.equal(state.storage.map.has("2026-07-26:d"), true);
  // alarm 被重设到次日(非 null)
  assert.ok(state.storage.alarm !== null);
});

test("ensureDailyAlarm 只设一次:第二次 consume 不覆盖已有 alarm", async () => {
  const { state, instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100 });
  const firstAlarm = state.storage.alarm;
  assert.ok(firstAlarm !== null);
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100 });
  assert.equal(state.storage.alarm, firstAlarm, "alarm 不应被覆盖");
});

// MARK: - 输入校验

test("consume 缺 key 返回 400", async () => {
  const { instance } = makeDO();
  const r = await consume(instance, { date: "2026-07-26", limit: 100 });
  assert.equal(r.status, 400);
  assert.equal(r.body.error, "invalid_key");
});

test("consume date 格式非法返回 400", async () => {
  const { instance } = makeDO();
  const r1 = await consume(instance, { key: "d", date: "2026/07/26", limit: 100 });
  assert.equal(r1.status, 400);
  const r2 = await consume(instance, { key: "d", date: "2026-7-26", limit: 100 });
  assert.equal(r2.status, 400);
  const r3 = await consume(instance, { key: "d", date: "", limit: 100 });
  assert.equal(r3.status, 400);
});

test("consume limit 非法返回 400", async () => {
  const { instance } = makeDO();
  const r1 = await consume(instance, { key: "d", date: "2026-07-26", limit: 0 });
  assert.equal(r1.status, 400);
  const r2 = await consume(instance, { key: "d", date: "2026-07-26", limit: -5 });
  assert.equal(r2.status, 400);
  const r3 = await consume(instance, { key: "d", date: "2026-07-26", limit: "abc" });
  assert.equal(r3.status, 400);
});

test("consume amount 非法返回 400", async () => {
  const { instance } = makeDO();
  const r1 = await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 0 });
  assert.equal(r1.status, 400);
  const r2 = await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: -1 });
  assert.equal(r2.status, 400);
});

test("consume body 不是 JSON 返回 400 invalid_json", async () => {
  const { instance } = makeDO();
  const req = new Request("https://do.local/consume", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "not-json"
  });
  const response = await instance.fetch(req);
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.equal(body.error, "invalid_json");
});

// MARK: - inspect / reset

test("inspect 返回当前 used,不修改 storage", async () => {
  const { state, instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 7 });
  const sizeBefore = state.storage.map.size;
  const r = await inspect(instance, { key: "d", date: "2026-07-26" });
  assert.equal(r.status, 200);
  assert.equal(r.body.used, 7);
  assert.equal(state.storage.map.size, sizeBefore, "inspect must not write");
});

test("inspect 未写入的 key 返回 used=0", async () => {
  const { instance } = makeDO();
  const r = await inspect(instance, { key: "never", date: "2026-07-26" });
  assert.equal(r.status, 200);
  assert.equal(r.body.used, 0);
});

test("reset 清零指定 key/date", async () => {
  const { state, instance } = makeDO();
  await consume(instance, { key: "d", date: "2026-07-26", limit: 100, amount: 5 });
  await consume(instance, { key: "other", date: "2026-07-26", limit: 100, amount: 3 });
  const r = await reset(instance, { key: "d", date: "2026-07-26" });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(state.storage.map.has("2026-07-26:d"), false);
  // other 不受影响
  assert.equal(state.storage.map.has("2026-07-26:other"), true);
});

// MARK: - 路由

test("未知路径返回 404", async () => {
  const { instance } = makeDO();
  const req = new Request("https://do.local/nope", { method: "POST" });
  const response = await instance.fetch(req);
  assert.equal(response.status, 404);
});
