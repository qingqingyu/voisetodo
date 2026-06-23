// Shared HTTP error type used across worker entry, provider layer, and adapters.
// Lives outside worker.js so adapters can throw typed errors without a circular import.

export class ProxyHTTPError extends Error {
  constructor(status, message, options = {}) {
    super(message, options);
    this.name = "ProxyHTTPError";
    this.status = status;
    this.errorType = options.errorType || "";
  }
}
