// 强一致配额计数器 Durable Object。
//
// 为什么需要它:Cloudflare KV 上的 read-modify-write(get → +1 → put)在并发下
// 丢失更新 —— 每个 await 都是交错点,两个并发请求会读到同一个 current、各自算出
// current + 1、各自 put,最终只 +1。Durable Object 的输入是串行化的,read-modify-write
// 在 DO 内部是真正的原子操作。
//
// 接口(走 fetch 入口,符合 DurableObject 标准):
//   POST /consume          { key, date, limit, amount? }                → { allowed, used, remaining, limit, taken }
//   POST /consume-rolling  { key, hour, limit, windowHours, amount? }   → { allowed, used, remaining, limit, taken }
//   POST /refund           { key, date, amount? }                       → { refunded, used }
//   GET  /inspect          ?key=&date=                                  → { used }
//   POST /reset            { key, date }                                → { ok }   // 测试用,生产可关
//
// consume 的"部分授予"语义:当 amount > remaining 但 remaining > 0 时,返回
//   { allowed: true, taken: <remaining>, used: <limit>, remaining: 0 }
// 即"能扣多少扣多少",**不会**因 amount 不够而全拒绝。调用方需要检查 taken 是否
// 等于预期 amount;不等表示部分授予。当前所有调用方都传 amount=1,不会触发部分授予,
// 但 API 形态保留供未来批量计费场景使用。
//
// 计数 key 里带日期(YYYY-MM-DD),不同日期天然隔离。每天 UTC 0:05 触发 alarm 清理
// 历史 storage,避免无限增长。alarm 在首次写入时设置,触发后再设下一个,保证持续。
//
// consume-rolling(全局预算熔断用):按 UTC 小时桶(YYYY-MM-DDTHH)计数,窗口 =
// 以 hour 为终点的最近 windowHours 个桶(含当桶),consume 时先求窗口内总和再判限。
// 命中时计数落在当前小时桶;老桶随时间自然滚出窗口,不需要显式重置 —— 这是
// 「打穿后锁死到 UTC 0 点(国内用户最晚 ~10h)」的修复:窗口内阈值由调用方按
// 日限 × windowHours/24 折算,持续刷量的日成本天花板不变,而单次打穿的锁死上限
// 被压缩到 ≤ windowHours(每小时边界重评一次)。窗口内阈值折算在 worker 侧做,
// DO 保持通用计数器职责。
//
// 清理边界(两套端点共用):保留「今天 + 昨天」两天的桶,只删 < 昨天 的 key。
// 不能只保留今天 —— UTC 0:05 的 alarm 会把滚动窗口仍需要读取的「昨天的小时桶」
// 全删掉(24h 窗口在 00:05 仍需昨天 01:00 起的桶),导致跨 UTC 0 点后窗口被
// 低估、熔断变松。windowHours 上限 24,两天保留对任意合法窗口都够。
//
// alarm 链的脆弱点:依赖 CF 调度器按时触发。若某次 alarm 未触发(调度器异常),
// 当前实例的 alarm 不会自我恢复 —— 下次 consume 不会重设 alarm(getAlarm 返回非 null
// 的过期时间戳)。最坏情况:DO storage 残留少量过期 key,占用 storage 配额但不影响
// 计数正确性(storageKey 带日期隔离)。运维监控点:storage key 数量,超阈值告警。

export class QuotaCounter {
  // state: DurableObjectState
  // env: Worker env(本 DO 不依赖 env,保留以备未来需要)
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    // 路径分发先于 body 解析 —— 未知路径直接 404,不因缺 body 误报 400 invalid_json
    if (path !== "/consume" && path !== "/consume-rolling" && path !== "/refund" && path !== "/inspect" && path !== "/reset") {
      return json({ error: "not_found" }, 404);
    }

    let body = {};
    if (request.method === "POST") {
      try {
        body = await request.json();
      } catch (error) {
        return json({ error: "invalid_json" }, 400);
      }
    }

    switch (path) {
      case "/consume":
        return this.handleConsume(body);
      case "/consume-rolling":
        return this.handleConsumeRolling(body);
      case "/refund":
        return this.handleRefund(body);
      case "/inspect":
        return this.handleInspect(url);
      case "/reset":
        return this.handleReset(body);
    }
    // 上面路径校验已保证不会走到这里
    return json({ error: "not_found" }, 404);
  }

  // 原子地 read → check → increment。DO 的串行化输入保证并发安全。
  // amount > 1 时按"能扣多少扣多少",不会因额度不足而全拒绝。
  //   例:limit=100, used=98, amount=5 → allowed=true, taken=2, used=100, remaining=0
  async handleConsume(body) {
    const validated = validateConsumeInput(body);
    if (validated.error) return json({ error: validated.error }, 400);
    const { key, date, limit, amount } = validated;

    const storageKey = storageKeyFor(key, date);
    const current = await readUsed(this.state.storage, storageKey);

    if (current >= limit) {
      return json({
        allowed: false,
        used: current,
        remaining: 0,
        limit,
        taken: 0
      });
    }

    const take = Math.min(amount, limit - current);
    const newUsed = current + take;
    await this.state.storage.put(storageKey, { used: newUsed });
    await this.ensureDailyAlarm(date);

    return json({
      allowed: true,
      used: newUsed,
      remaining: limit - newUsed,
      limit,
      taken: take
    });
  }

  // 滚动窗口版 consume(全局预算熔断用)。窗口 = 以 hour 为终点的最近
  // windowHours 个 UTC 小时桶(含当桶),对窗口内全部桶求和后判限,命中则
  // 计入当前小时桶。窗口随时间自然滚动 —— 老桶滚出窗口后总和自动回落,
  // 不需要任何显式重置,这是"锁死到 UTC 0 点"问题的结构性修复。
  // 跨 24 个桶的 read-sum-write 仍是原子的:DO input gate 在 storage 操作
  // 期间不投递新事件,gets 与 put 之间只有同步代码,无交错点。
  // 部分授予语义与 /consume 一致(当前调用方都传 amount=1,不会触发)。
  async handleConsumeRolling(body) {
    const validated = validateConsumeRollingInput(body);
    if (validated.error) return json({ error: validated.error }, 400);
    const { key, hour, limit, windowHours, amount } = validated;

    const buckets = hourBucketsEndingAt(hour, windowHours);
    const records = await Promise.all(
      buckets.map((bucket) => this.state.storage.get(storageKeyFor(key, bucket)))
    );
    const windowUsed = records.reduce((sum, record) => sum + readUsedValue(record), 0);

    if (windowUsed >= limit) {
      return json({
        allowed: false,
        used: windowUsed,
        remaining: 0,
        limit,
        taken: 0
      });
    }

    const take = Math.min(amount, limit - windowUsed);
    const currentStorageKey = storageKeyFor(key, hour);
    const newUsed = readUsedValue(records[0]) + take;
    await this.state.storage.put(currentStorageKey, { used: newUsed });
    await this.ensureDailyAlarm(hour.slice(0, 10));

    return json({
      allowed: true,
      used: windowUsed + take,
      remaining: limit - windowUsed - take,
      limit,
      taken: take
    });
  }

  // 递减计数。用于补偿(已扣配额但其他检查 deny 了,需要把钱退回)。
  // amount 超过 used 时只退到 0,不会变负。
  async handleRefund(body) {
    const validated = validateRefundInput(body);
    if (validated.error) return json({ error: validated.error }, 400);
    const { key, date, amount } = validated;

    const storageKey = storageKeyFor(key, date);
    const current = await readUsed(this.state.storage, storageKey);
    const decrement = Math.min(amount, current);
    const newUsed = current - decrement;

    if (newUsed === 0) {
      // 删 key 而不是 put { used: 0 },让 storage 保持干净
      await this.state.storage.delete(storageKey);
    } else {
      await this.state.storage.put(storageKey, { used: newUsed });
    }

    return json({ refunded: decrement, used: newUsed });
  }

  // 只读,不修改。给调试/可观测性用。
  async handleInspect(url) {
    const key = url.searchParams.get("key");
    const date = url.searchParams.get("date");
    if (!key || !isValidDate(date)) {
      return json({ error: "invalid_query" }, 400);
    }
    const used = await readUsed(this.state.storage, storageKeyFor(key, date));
    return json({ used });
  }

  // 把指定 key/date 的计数清零。测试用,生产环境可通过删除 DO 实例实现等效效果。
  async handleReset(body) {
    const validated = validateResetInput(body);
    if (validated.error) return json({ error: validated.error }, 400);
    const { key, date } = validated;
    await this.state.storage.delete(storageKeyFor(key, date));
    return json({ ok: true });
  }

  // 单 DO 实例只有一个 alarm slot。在首次写入时设到次日 UTC 0:05,
  // alarm 触发时清理所有 < 昨天 的记录(保留今天+昨天两天,见文件头「清理边界」),
  // 并设下一个 alarm。这样无论 DO 实例服务多少 key/桶,都能持续清理过期数据。
  async ensureDailyAlarm(date) {
    const existing = await this.state.storage.getAlarm();
    if (existing !== null) return;
    // 次日 UTC 0:05。+24h 到次日 0:00,再 +5 分钟避开整点(降低 CF 调度抖动撞上大量 DO 同时 alarm)。
    const tomorrowMs = Date.parse(`${date}T00:00:00.000Z`) + 24 * 3600 * 1000 + 5 * 60 * 1000;
    if (!Number.isFinite(tomorrowMs)) return;
    this.state.storage.setAlarm(tomorrowMs);
  }

  async alarm() {
    const today = todayDateString();
    // 保留边界 = 昨天。滚动窗口最长 24h,UTC 0:05 清理时昨天的桶仍可能被读取
    // (00:05 的 24h 窗口覆盖昨天 01:00 起的桶),删昨天会让窗口跨 UTC 0 点后
    // 被低估。今天+昨天两天,对 windowHours ≤ 24 的任何窗口都够。
    const cutoff = dateMinusOneDay(today);
    const list = await this.state.storage.list();
    for (const [key] of list) {
      const datePart = datePartFromStorageKey(key);
      if (datePart && datePart < cutoff) {
        await this.state.storage.delete(key);
      }
    }
    // 设下一个 alarm:今天 0:00 + 24h05m = 次日 0:05
    // 兜底:即使今天没有任何 consume,alarm 链也不会断
    const nextMs = Date.parse(`${today}T00:00:00.000Z`) + 24 * 3600 * 1000 + 5 * 60 * 1000;
    if (Number.isFinite(nextMs)) {
      this.state.storage.setAlarm(nextMs);
    }
  }
}

// MARK: - Helpers

function storageKeyFor(key, date) {
  return `${date}:${key}`;
}

// 以 hour(YYYY-MM-DDTHH)为终点(含)的最近 windowHours 个 UTC 小时桶,
// 顺序为 [当前桶, 前 1h, 前 2h, ...] —— 索引 0 恒为当前桶,
// handleConsumeRolling 依赖这一点把计数落到当前桶。
function hourBucketsEndingAt(hour, windowHours) {
  const hourMs = Date.parse(`${hour}:00:00.000Z`);
  const buckets = [];
  for (let i = 0; i < windowHours; i += 1) {
    buckets.push(new Date(hourMs - i * 3600 * 1000).toISOString().slice(0, 13));
  }
  return buckets;
}

function dateMinusOneDay(date) {
  return new Date(Date.parse(`${date}T00:00:00.000Z`) - 24 * 3600 * 1000).toISOString().slice(0, 10);
}

// storageKey 格式为 `${date}:${key}`,date 是 YYYY-MM-DD(10 字符)或
// YYYY-MM-DDTHH(13 字符小时桶)+冒号。两种格式 slice(0,10) 都得到日期部分。
// 返回空字符串表示格式异常(不做处理)。
function datePartFromStorageKey(storageKey) {
  if (typeof storageKey !== "string" || storageKey.length < 11) return "";
  return storageKey.slice(0, 10);
}

async function readUsed(storage, storageKey) {
  return readUsedValue(await storage.get(storageKey));
}

function readUsedValue(record) {
  if (!record || typeof record !== "object") return 0;
  const used = Number(record.used);
  return Number.isFinite(used) && used > 0 ? used : 0;
}

function isValidDate(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function isValidHour(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}$/.test(value)) return false;
  // 正则只管形状;完全解析不了的字符串(T99 点、13 月)Date.parse 返回 NaN,
  // 若放行,hourBucketsEndingAt 里 new Date(NaN).toISOString() 会抛 RangeError,
  // DO 以未处理异常拒绝而非 400 invalid_hour —— 在入口挡掉,保持错误显式可辨。
  // 注:V8 对「2 月 30 日」这类日溢出是宽松滚动解析(→3 月 2 日),不返回 NaN,
  // 会落成一个错误但隔离的桶 key,计数语义仍自洽,不做拒绝。
  return Number.isFinite(Date.parse(`${value}:00:00.000Z`));
}

function isValidKey(value) {
  // 256 字符上限是防御性约束:实际 key 都是固定短串(device-quota / ip-daily / global-budget,
  // 加上 date 共 <30 字符)。即使未来加新 subject type 也很难超 —— 这个限制主要是
  // 防止恶意调用方传超长 key 消耗 storage。
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function resolveAmount(raw, fallback) {
  if (raw === undefined) return fallback;
  const num = Number(raw);
  if (!Number.isFinite(num) || num <= 0) return null;
  return Math.floor(num);
}

function validateConsumeInput(body) {
  if (!body || typeof body !== "object") return { error: "invalid_body" };
  if (!isValidKey(body.key)) return { error: "invalid_key" };
  if (!isValidDate(body.date)) return { error: "invalid_date" };
  const limit = Number(body.limit);
  if (!Number.isFinite(limit) || limit <= 0) return { error: "invalid_limit" };
  const amount = resolveAmount(body.amount, 1);
  if (amount === null) return { error: "invalid_amount" };
  return { key: body.key, date: body.date, limit: Math.floor(limit), amount };
}

function validateConsumeRollingInput(body) {
  if (!body || typeof body !== "object") return { error: "invalid_body" };
  if (!isValidKey(body.key)) return { error: "invalid_key" };
  if (!isValidHour(body.hour)) return { error: "invalid_hour" };
  const limit = Number(body.limit);
  if (!Number.isFinite(limit) || limit <= 0) return { error: "invalid_limit" };
  // windowHours 上限 24 与文件头「清理边界」联动:保留两天桶的前提是窗口 ≤ 24h。
  const windowHours = Number(body.windowHours);
  if (!Number.isInteger(windowHours) || windowHours < 1 || windowHours > 24) {
    return { error: "invalid_window_hours" };
  }
  const amount = resolveAmount(body.amount, 1);
  if (amount === null) return { error: "invalid_amount" };
  return { key: body.key, hour: body.hour, limit: Math.floor(limit), windowHours, amount };
}

function validateRefundInput(body) {
  if (!body || typeof body !== "object") return { error: "invalid_body" };
  if (!isValidKey(body.key)) return { error: "invalid_key" };
  if (!isValidDate(body.date)) return { error: "invalid_date" };
  const amount = resolveAmount(body.amount, 1);
  if (amount === null) return { error: "invalid_amount" };
  return { key: body.key, date: body.date, amount };
}

function validateResetInput(body) {
  if (!body || typeof body !== "object") return { error: "invalid_body" };
  if (!isValidKey(body.key)) return { error: "invalid_key" };
  if (!isValidDate(body.date)) return { error: "invalid_date" };
  return { key: body.key, date: body.date };
}

function todayDateString() {
  return new Date().toISOString().slice(0, 10);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

// 测试专用 export:让单元测试可以用 fake storage 直接驱动 DO 类,
// 不需要起 Miniflare。生产代码不依赖这些。
export const _testInternals = {
  storageKeyFor,
  datePartFromStorageKey,
  readUsed,
  todayDateString,
  hourBucketsEndingAt
};
