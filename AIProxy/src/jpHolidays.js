// 日本节假日与营业日(任务书 docs/eval-ja-batch2-holidays-task.md §3,2026-11-27)。
// 纯函数、零依赖:worker(buildSystemPrompt 注入)与 eval runner(日期规则 tag 重算)
// 共用,**只此一份数据源**——两边各自实现必然漂移。
//
// 口径(现行《国民の祝日に関する法律》+ 任务书 §1 拍板):
// - 固定日期祝日 + Happy Monday(成人の日 1 月第 2 周一 / 海の日 7 月第 3 周一 /
//   敬老の日 9 月第 3 周一 / スポーツの日 10 月第 2 周一;1998/2000/2003 改法后现行)
// - 春分の日 / 秋分の日:天文近似公式,保证 2000–2099 与《暦要項》一致
//   (见 vernalEquinoxDay / autumnalEquinoxDay 注释;官方每年二月发表次年确切值,
//   公式在 2000–2099 内无偏差——单测对照内閣府 CSV 2026/2027 全量钉住)
// - 振替休日:祝日落在日曜 → 其后第一个「非祝日」的日子(2007 年现行条文)
// - 国民の休日:非日曜的平日被两个祝日夹住 → 也是休日
// - **年末年始(12/29–1/3)、お盆不是法定假日,不算**(任务书 §1:商务上也不是
//   「祝日、振替休日、国民の休日」的成员)
// - 特別法临时调整走 JP_HOLIDAY_OVERRIDES(现为空;未来有临时调整时在此登记,
//   不要改公式)
//
// 支持年份 2000–2099(春分/秋分公式适用域)。超界一律返回 null / 不抛错:
// 注入侧(today 年份超界)按「算不出 → 不注入 + warn 日志」兜底,与月份事实
// 的降级口径一致;eval runner 的 tag 重算只在钉住的锚上用,超界即显式 null。
// 日期一律 YYYY-MM-DD,UTC 日历运算(与 buildSystemPrompt 的月份事实同口径,
// 不涉时区)。

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const SUPPORTED_YEAR_MIN = 2000;
const SUPPORTED_YEAR_MAX = 2099;

/// 特别法增删(任务书 §3:现在为空)。add: { "YYYY-MM-DD": 名称 } / remove: ["YYYY-MM-DD"]。
export const JP_HOLIDAY_OVERRIDES = { add: {}, remove: [] };

function parseISO(iso) {
  if (!ISO_DATE_RE.test(String(iso ?? ""))) return null;
  const ms = Date.parse(`${iso}T00:00:00.000Z`);
  return Number.isFinite(ms) ? ms : null;
}

function toISO(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function ymd(ms) {
  const d = new Date(ms);
  return [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()];
}

function ymdIso(y, m, d) {
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function utcMs(y, m, d) {
  return Date.UTC(y, m - 1, d);
}

/// 某年某月第 n 个周一的日号(Happy Monday)。
function nthMondayDay(year, month, nth) {
  const firstWday = new Date(utcMs(year, month, 1)).getUTCDay(); // 0=Sun…6=Sat
  const firstMonday = 1 + ((8 - firstWday) % 7); // 1..7
  return firstMonday + (nth - 1) * 7;
}

/// 春分の日(3 月日号)。常用近似(1980 基准):2000–2099 与天文历一致。
/// 2026→20、2027→21(与内閣府 CSV 对齐,单测钉住)。
function vernalEquinoxDay(year) {
  const t = year - 1980;
  return Math.floor(20.8431 + 0.242194 * t - Math.floor(t / 4));
}

/// 秋分の日(9 月日号)。2026→23、2027→23(同上)。
function autumnalEquinoxDay(year) {
  const t = year - 1980;
  return Math.floor(23.2488 + 0.242194 * t - Math.floor(t / 4));
}

/// 固定/计算出的祝日(未含振替与国民の休日)。
function baseHolidaysOf(year) {
  const entries = [
    [1, 1, "元日"],
    [1, nthMondayDay(year, 1, 2), "成人の日"],
    [2, 11, "建国記念の日"],
    [2, 23, "天皇誕生日"],
    [3, vernalEquinoxDay(year), "春分の日"],
    [4, 29, "昭和の日"],
    [5, 3, "憲法記念日"],
    [5, 4, "みどりの日"],
    [5, 5, "こどもの日"],
    [7, nthMondayDay(year, 7, 3), "海の日"],
    [8, 11, "山の日"],
    [9, nthMondayDay(year, 9, 3), "敬老の日"],
    [9, autumnalEquinoxDay(year), "秋分の日"],
    [10, nthMondayDay(year, 10, 2), "スポーツの日"],
    [11, 3, "文化の日"],
    [11, 23, "勤労感謝の日"],
  ];
  const map = new Map();
  for (const [m, d, name] of entries) map.set(ymdIso(year, m, d), name);
  return map;
}

// 年份缓存(纯函数结果,worker isolate 存活期内复用;最多缓存少量年份,
// 2000–2099 全缓存也就 100 个小 Map,不设淘汰)。
const yearCache = new Map();

/// 某年完整节假日表(祝日 + 振替休日 + 国民の休日 + overrides)。
/// 年份超界(非 2000–2099)返回 null —— 调用方按「算不出」兜底。
/// Map<iso, name>(name: 祝日名 / "振替休日" / "国民の休日")。
function holidaysOfYear(year) {
  if (!Number.isInteger(year) || year < SUPPORTED_YEAR_MIN || year > SUPPORTED_YEAR_MAX) return null;
  const cached = yearCache.get(year);
  if (cached) return cached;

  const base = baseHolidaysOf(year);
  const full = new Map(base);

  // 振替休日:日曜的祝日 → 其后第一个非祝日的日子。扫到 12/31 为止
  // (理论上最多前进 4 天:圣诞连休级别的排布;2000–2099 内实际 ≤3)。
  for (const [iso] of base) {
    const wday = new Date(parseISO(iso)).getUTCDay();
    if (wday !== 0) continue;
    let cursor = parseISO(iso) + 24 * 3600 * 1000;
    for (let i = 0; i < 7; i++) {
      const [y, m, d] = ymd(cursor);
      if (y !== year) break; // 跨年振替不存在(12 月最后祝日 12/23,余量充足)
      const cursorIso = ymdIso(y, m, d);
      if (!full.has(cursorIso)) {
        full.set(cursorIso, "振替休日");
        break;
      }
      cursor += 24 * 3600 * 1000;
    }
  }

  // 国民の休日:非日曜的平日,前一天与后一天**都是祝日**(即两祝日恰好隔一天)。
  // 判定用 base(祝日本体)——振替休日不是「国民の祝日」,条文按祝日本体算。
  const sortedBase = [...base.keys()].sort();
  for (let i = 0; i + 1 < sortedBase.length; i++) {
    const prevMs = parseISO(sortedBase[i]);
    const after2Ms = prevMs + 2 * 24 * 3600 * 1000;
    if (toISO(after2Ms) !== sortedBase[i + 1]) continue; // 间隔不是恰好 1 天,没有夹日
    const betweenIso = toISO(prevMs + 24 * 3600 * 1000);
    if (full.has(betweenIso)) continue; // 防御:夹日本身是祝日/振替(理论不可能,base 相邻日不构成 gap 2)
    const wday = new Date(parseISO(betweenIso)).getUTCDay();
    if (wday === 0) continue; // 周日本来就休,不产生国民の休日
    full.set(betweenIso, "国民の休日");
  }

  // overrides:增(同名日额外)与删(临时调整)。
  for (const key of JP_HOLIDAY_OVERRIDES.remove) {
    if (key.startsWith(`${year}-`)) full.delete(key);
  }
  for (const [key, name] of Object.entries(JP_HOLIDAY_OVERRIDES.add)) {
    if (key.startsWith(`${year}-`)) full.set(key, name);
  }

  yearCache.set(year, full);
  return full;
}

/// 校验入参是真实 ISO 日历日,返回其 UTC 毫秒;否则 null。
function requireISO(iso, what = "日期") {
  const ms = parseISO(iso);
  if (ms === null) {
    throw new Error(`${what} 非法(需 YYYY-MM-DD): ${String(iso)}`);
  }
  return ms;
}

// ---------- 导出(签名见任务书 §3) ----------

/// [startISO, endISO] 闭区间内的全部节假日,升序。
/// 年份超界 → null(算不出,不静默给部分数据)。
export function jpHolidaysBetween(startISO, endISO) {
  const startMs = requireISO(startISO, "startISO");
  const endMs = requireISO(endISO, "endISO");
  if (endMs < startMs) return [];
  const [sy] = ymd(startMs);
  const [ey] = ymd(endMs);
  const out = [];
  for (let y = sy; y <= ey; y++) {
    const yearMap = holidaysOfYear(y);
    if (yearMap === null) return null;
    for (const [iso, name] of yearMap) {
      const ms = parseISO(iso);
      if (ms >= startMs && ms <= endMs) out.push({ iso, name });
    }
  }
  out.sort((a, b) => (a.iso < b.iso ? -1 : 1));
  return out;
}

/// 是否日本节假日;是则返回名称(祝日名 / 振替休日 / 国民の休日),否返回 null。
/// 年份超界 → null(与「不是节假日」同返回值,调用方需要区分时先查年份)。
export function jpHolidayName(iso) {
  const ms = requireISO(iso, "iso");
  const [y] = ymd(ms);
  const yearMap = holidaysOfYear(y);
  return yearMap ? yearMap.get(iso) ?? null : null;
}

/// 是否营业日:周一到周五且非节假日(年末年始/お盆不算节假日,任务书 §1)。
/// 年份超界 → null(算不出;注入侧按不注入兜底)。
export function isJpBusinessDay(iso) {
  const ms = requireISO(iso, "iso");
  const [y] = ymd(ms);
  const yearMap = holidaysOfYear(y);
  if (yearMap === null) return null;
  const wday = new Date(ms).getUTCDay();
  return wday >= 1 && wday <= 5 && !yearMap.has(iso);
}

/// iso 之后第 n 个营业日(n ≥ 1,当天不算——「翌営業日」= n=1,商务惯例从明天数)。
/// 跨年依赖次年数据,超界 → null。n 非法(≤0 / 非整数)抛错(调用方契约违反)。
export function nthJpBusinessDayAfter(iso, n) {
  if (!Number.isInteger(n) || n < 1) {
    throw new Error(`n 非法(需 ≥1 的整数): ${String(n)}`);
  }
  let cursor = requireISO(iso, "iso") + 24 * 3600 * 1000;
  let remaining = n;
  // 上限:每 7 天至少 5 个营业日 → n 个营业日最多 n*7/5 + 2 个日历日,放宽到 n*7。
  const limit = parseISO(iso) + n * 7 * 24 * 3600 * 1000;
  while (cursor <= limit) {
    if (holidaysOfYear(ymd(cursor)[0]) === null) return null;
    const isoCursor = toISO(cursor);
    if (isJpBusinessDay(isoCursor) === true) {
      remaining--;
      if (remaining === 0) return isoCursor;
    }
    cursor += 24 * 3600 * 1000;
  }
  return null; // 理论不可达(n*7 上限内必出 n 个营业日);防御返回
}

/// 週明け:iso 之后第一个周一;那天不是营业日就顺延到下一个营业日。
/// (任务书 §1:2026-11-18 说「週明け」→ 11/23 勤労感謝の日 → 11/24。)
export function jpWeekStartBusinessDay(iso) {
  const startMs = requireISO(iso, "iso");
  let cursor = startMs + 24 * 3600 * 1000;
  const wday0 = new Date(cursor).getUTCDay();
  cursor += ((8 - wday0) % 7) * 24 * 3600 * 1000; // 到下一个周一(1..7 天后)
  // 顺延:周一撞节假日 → 下一个营业日
  let isoCursor = toISO(cursor);
  if (isJpBusinessDay(isoCursor) === true) return isoCursor;
  return nthJpBusinessDayAfter(isoCursor, 1);
}

/// 今週中(拍板口径):周日起始的本周的周五。今天是周六 → 今天;
/// 周五是节假日也仍算周五(不顺延,任务书 §1)。
export function thisWeekFriday(iso) {
  const ms = requireISO(iso, "iso");
  const wday = new Date(ms).getUTCDay(); // 0=Sun…6=Sat
  if (wday === 6) return toISO(ms); // 周六 → 今天
  // 周日(0)= 本周第 1 天 → 周五是 +5;周一=+4 … 周五=+0
  const offsetToFriday = (5 - wday + 7) % 7;
  return toISO(ms + offsetToFriday * 24 * 3600 * 1000);
}

/// 今天或之后最近的同名节假日(「勤労感謝の日に」类说法;含今天)。
/// 找不到(名字不认识 / 400 天内没有)→ null。400 天窗口覆盖所有每年一次的
/// 法定节假日(含振替导致最多 ±1 天漂移)。
export function nextJpHoliday(iso, name) {
  if (!name || typeof name !== "string") {
    throw new Error(`name 非法: ${String(name)}`);
  }
  const startMs = requireISO(iso, "iso");
  const endMs = startMs + 400 * 24 * 3600 * 1000;
  let cursor = startMs;
  while (cursor <= endMs) {
    if (holidaysOfYear(ymd(cursor)[0]) === null) return null;
    if (jpHolidayName(toISO(cursor)) === name) return toISO(cursor);
    cursor += 24 * 3600 * 1000;
  }
  return null;
}
