// 工具页时区下拉表单用。零 JS 站点没法读浏览器时区:下拉默认「Auto」(服务端用
// request.cf.timezone 解析,见 resolveFormTimezone),显式列表用原生 <select> 选;
// 服务端(本文件消费方:Pages Function)只认这个白名单 —— 时区串直接进
// Intl.DateTimeFormat,白名单外的显式值一律 400(防探测/异常输入)。
// 顺序 = 下拉展示顺序:Auto 在最前(默认值),显式值大致按 UTC 偏移自西向东。
export const TIMEZONES = [
  'UTC',
  'Pacific/Honolulu',
  'America/Anchorage',
  'America/Los_Angeles',
  'America/Phoenix',
  'America/Denver',
  'America/Chicago',
  'America/Mexico_City',
  'America/New_York',
  'America/Toronto',
  'America/Bogota',
  'America/Sao_Paulo',
  'America/Argentina/Buenos_Aires',
  'Europe/London',
  'Europe/Dublin',
  'Europe/Lisbon',
  'Europe/Madrid',
  'Europe/Paris',
  'Europe/Brussels',
  'Europe/Amsterdam',
  'Europe/Berlin',
  'Europe/Zurich',
  'Europe/Rome',
  'Europe/Stockholm',
  'Europe/Warsaw',
  'Europe/Athens',
  'Europe/Helsinki',
  'Europe/Istanbul',
  'Europe/Moscow',
  'Asia/Dubai',
  'Asia/Tehran',
  'Asia/Karachi',
  'Asia/Kolkata',
  'Asia/Dhaka',
  'Asia/Bangkok',
  'Asia/Singapore',
  'Asia/Hong_Kong',
  'Asia/Shanghai',
  'Asia/Taipei',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Australia/Perth',
  'Australia/Adelaide',
  'Australia/Sydney',
  'Australia/Brisbane',
  'Pacific/Auckland',
];

export function isKnownTimezone(tz) {
  return TIMEZONES.includes(tz);
}

/// 表单 tz 值归一化(两个工具页共用)。
/// - 'auto'(下拉默认):服务端用 Cloudflare 注入的 `request.cf.timezone` 解析 ——
///   零 JS 站点读不到浏览器时区,此前默认 UTC,美国用户傍晚输入 "tomorrow" 会错一天
///   (UTC 已进第二天)。cf 是边缘注入的受信字段,不是用户输入,不必进白名单,
///   但仍过一次 Intl 合法性校验;拿不到或非法回落 UTC(审计 2026-11-24 的建议口径)。
/// - 显式选项:仍走白名单,白名单外返回 { tz: null } 由调用方 400。
export function resolveFormTimezone(value, request) {
  const raw = String(value || '').trim() || 'auto';
  if (raw === 'auto') {
    const cfTz = request && request.cf && typeof request.cf.timezone === 'string' ? request.cf.timezone : '';
    if (cfTz && isValidIANA(cfTz)) return { tz: cfTz };
    return { tz: 'UTC' };
  }
  if (!isKnownTimezone(raw)) return { tz: null };
  return { tz: raw };
}

function isValidIANA(tz) {
  try {
    new Intl.DateTimeFormat('en-CA', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/// 指定时区的「今天」(YYYY-MM-DD)。供 recurrence 解析的参考日期,也作为
/// X-Local-Date 转发给代理(代理侧 resolveQuotaDate 会做漂移校验,>1 天漂移
/// 自动回落 UTC —— 两端都不信任客户端到无界的程度)。
export function todayInZone(tz, now = Date.now()) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(now));
}
