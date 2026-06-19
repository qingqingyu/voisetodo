# Logging Conventions

VoiceTodo logs are optimized for tracing one user action across coordinator,
extractor, network, store, widget, intent, and calendar layers.

## Field Order

Use this field order for new structured log messages:

1. `event.name`
2. `id`
3. parent or correlated IDs, for example `extractID`, `todoID`, `pendingID`, `eventID`
4. branch fields, for example `reason`, `attempt`, `status`, `locale`
5. counters and sizes, for example `todoCount`, `responseBytes`, `chars`
6. timing fields
7. `error`

Example:

```swift
VoiceTodoLog.coordinator.info("coordinator.process_transcript.success id=... extractID=... finalTodos=... durationMS=...")
```

## Trace IDs

- `id` identifies the local operation that emitted the log.
- `extractID` links one extraction flow across coordinator, extractor, and network logs.
- For pending item recovery, keep both the batch `id` and per-item `pendingID`.
- Do not replace domain IDs such as `todoID` or `eventID` with trace IDs.

## Time Units

Name time fields with explicit units:

- Durations measured from a start timestamp: `durationMS`
- Timeout values configured in seconds: `timeoutSeconds`
- Retry sleeps configured in seconds: `waitIntervalSeconds`
- Avoid ambiguous names such as `timeout`, `duration`, or `waitSeconds` in logs.

All error logs should include the original error summary via `VoiceTodoLog.errorSummary(error)`.
