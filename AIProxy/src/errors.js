// Shared HTTP error type used across worker entry, provider layer, and adapters.
// Lives outside worker.js so adapters can throw typed errors without a circular import.

export class ProxyHTTPError extends Error {
  constructor(status, message, options = {}) {
    super(message, options);
    this.name = "ProxyHTTPError";
    this.status = status;
    this.errorType = options.errorType || "";
    // 可选结构化 JSON 响应体。设置后 worker 入口的 catch 用它替代纯文本 message，
    // 用于 429 配额/限流分类等需要稳定机器码的场景。null 时回退纯文本。
    this.body = options.body || null;
    // 可选响应头（随结构化 body 一起返回，如 X-RateLimit-Type / X-Quota-*）。
    this.headers = options.headers || null;
    // 限流类型标记（quota / velocity / ip_daily），仅用于日志，不进响应体。
    this.rateLimitType = options.rateLimitType || null;
  }
}
