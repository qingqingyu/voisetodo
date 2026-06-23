// Structured JSON line logger shared across worker entry and provider layer.
// Lives outside worker.js so src/*.js modules can log without a circular import.
//
// PII rules enforced here:
//   - callers MUST NOT pass transcript or upstream response bodies
//   - callers that log provider errors MUST pass known secret values to errorFields()
//     so exception messages/stacks cannot leak URL-embedded credentials

export function logInfo(event, fields = {}) {
  log("info", event, fields);
}

export function logWarn(event, fields = {}) {
  log("warn", event, fields);
}

export function logError(event, fields = {}) {
  log("error", event, fields);
}

export function log(level, event, fields = {}) {
  const payload = {
    ts: new Date().toISOString(),
    level,
    event,
    ...fields
  };
  const line = JSON.stringify(payload);
  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

export function redactText(value, redactions = []) {
  let text = String(value ?? "");
  for (const item of redactions) {
    const secret = String(item || "");
    if (!secret) continue;
    text = text.split(secret).join("[REDACTED]");
  }
  return text;
}

export function errorFields(error, { redactions = [] } = {}) {
  const fields = {
    errorName: error?.name || "Error",
    errorMessage: redactText(error?.message || String(error), redactions),
    errorStack: redactText(error?.stack || "", redactions)
  };
  if (error?.cause) {
    fields.causeName = error.cause?.name || "Error";
    fields.causeMessage = redactText(error.cause?.message || String(error.cause), redactions);
    fields.causeStack = redactText(error.cause?.stack || "", redactions);
  }
  return fields;
}
