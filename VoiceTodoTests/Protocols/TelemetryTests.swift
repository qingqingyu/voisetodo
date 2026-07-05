import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class TelemetryTests: XCTestCase {
    // MARK: - TelemetryPayload Codable

    func testPayloadCodableRoundTrip() throws {
        let payload = TelemetryPayload(
            name: "test_event",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sessionID: "session-abc",
            deviceID: "sha256:deadbeef",
            appVersion: "1.2.3",
            iosVersion: "17.0",
            params: ["count": "42", "label": "hello"]
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TelemetryPayload.self, from: data)

        XCTAssertEqual(payload, decoded)
    }

    // MARK: - TelemetryEvent.name

    func testEventNamesMatchSpec() {
        XCTAssertEqual(TelemetryEvent.appLaunch(coldLaunch: true, hasCompletedOnboarding: false).name, "app_launch")
        XCTAssertEqual(TelemetryEvent.recordingStarted(source: .button).name, "recording_started")
        XCTAssertEqual(TelemetryEvent.recordingOutcome(outcome: .success, durationMS: 100, transcript: "").name, "recording_outcome")
        XCTAssertEqual(TelemetryEvent.extractOutcome(outcome: .success, todosCount: 1, durationMS: 200, attempts: 1).name, "extract_outcome")
        XCTAssertEqual(TelemetryEvent.todoSaved(source: .confirm, count: 3).name, "todo_saved")
        XCTAssertEqual(TelemetryEvent.recordingFailed(reason: "x", errorCode: nil).name, "recording_failed")
        XCTAssertEqual(TelemetryEvent.extractFailed(reason: "network", attempt: 2).name, "extract_failed")
        XCTAssertEqual(TelemetryEvent.widgetLoadFailed(reason: "container").name, "widget_load_failed")
        XCTAssertEqual(TelemetryEvent.intentFailed(operation: "toggle", stage: "save").name, "intent_failed")
    }

    // MARK: - TelemetryEvent.params（脱敏正确性）

    func testAppLaunchParams() {
        let params = TelemetryEvent.appLaunch(coldLaunch: true, hasCompletedOnboarding: false).params
        XCTAssertEqual(params["coldLaunch"], "true")
        XCTAssertEqual(params["hasCompletedOnboarding"], "false")
    }

    func testRecordingOutcomeTranscriptIsRedacted() throws {
        let transcript = "明天去银行办卡，顺便买菜，晚上给老妈打电话"
        let params = TelemetryEvent.recordingOutcome(outcome: .success, durationMS: 5000, transcript: transcript).params

        // 不允许直接出现 transcript 原文
        XCTAssertFalse(params.values.contains { $0.contains("银行") || $0.contains("给老妈") },
                       "transcript 原文不得直接出现在遥测参数中")
        // 应记录 textSummary 形态
        let summary = try XCTUnwrap(params["transcript"])
        XCTAssertTrue(summary.contains("chars="))
        XCTAssertTrue(summary.contains("lines="))
        XCTAssertEqual(params["durationMS"], "5000")
        XCTAssertEqual(params["outcome"], "success")
    }

    func testRecordingOutcomeParamsForAllOutcomes() {
        for outcome in [RecordingOutcome.success, .interrupted, .userCancelled, .silenceTimeout, .maxDurationReached, .watchdogExpired, .error] {
            let params = TelemetryEvent.recordingOutcome(outcome: outcome, durationMS: 0, transcript: "").params
            XCTAssertEqual(params["outcome"], outcome.rawValue)
        }
    }

    func testExtractOutcomeParams() {
        let params = TelemetryEvent.extractOutcome(
            outcome: .offlineFallback, todosCount: 0, durationMS: 1200, attempts: 2
        ).params
        XCTAssertEqual(params["outcome"], "offline_fallback")
        XCTAssertEqual(params["todosCount"], "0")
        XCTAssertEqual(params["durationMS"], "1200")
        XCTAssertEqual(params["attempts"], "2")
    }

    func testTodoSavedParams() {
        for source in [SaveSource.confirm, .siriAdd, .widgetToggle] {
            let params = TelemetryEvent.todoSaved(source: source, count: 5).params
            XCTAssertEqual(params["source"], source.rawValue)
            XCTAssertEqual(params["count"], "5")
        }
    }

    func testRecordingFailedParamsWithAndWithoutErrorCode() {
        let withCode = TelemetryEvent.recordingFailed(reason: "audio_session", errorCode: 42).params
        XCTAssertEqual(withCode["reason"], "audio_session")
        XCTAssertEqual(withCode["errorCode"], "42")

        let withoutCode = TelemetryEvent.recordingFailed(reason: "permission", errorCode: nil).params
        XCTAssertEqual(withoutCode["reason"], "permission")
        XCTAssertNil(withoutCode["errorCode"])
    }

    func testIntentFailedParams() {
        let params = TelemetryEvent.intentFailed(operation: "toggle", stage: "save").params
        XCTAssertEqual(params["operation"], "toggle")
        XCTAssertEqual(params["stage"], "save")
    }

    // MARK: - TelemetryQueue 基本操作

    func testQueueEnqueueAndDrain() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        XCTAssertTrue(TelemetryQueue.peek(defaults: defaults).isEmpty)

        let now = Date()
        let payload = makePayload(name: "test", timestamp: now)
        TelemetryQueue.enqueue(payload, defaults: defaults, now: now)

        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 1)
        let drained = TelemetryQueue.drain(defaults: defaults, now: now)
        XCTAssertEqual(drained, [payload])
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 0)
    }

    func testQueueDrainClearsQueue() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        let now = Date()
        TelemetryQueue.enqueue(makePayload(name: "a", timestamp: now), defaults: defaults, now: now)
        TelemetryQueue.enqueue(makePayload(name: "b", timestamp: now), defaults: defaults, now: now)

        let drained = TelemetryQueue.drain(defaults: defaults, now: now)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 0)
    }

    func testQueueRestorePutsItemsBack() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        let now = Date()
        let payload1 = makePayload(name: "a", timestamp: now)
        let payload2 = makePayload(name: "b", timestamp: now)

        TelemetryQueue.enqueue(payload1, defaults: defaults, now: now)
        let drained = TelemetryQueue.drain(defaults: defaults, now: now)
        XCTAssertEqual(drained, [payload1])

        // 模拟上报失败，回滚
        TelemetryQueue.restore(drained, defaults: defaults, now: now)
        XCTAssertEqual(TelemetryQueue.peek(defaults: defaults), [payload1])

        // 队列继续工作
        TelemetryQueue.enqueue(payload2, defaults: defaults, now: now)
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 2)
    }

    func testQueueRestoreEmptyIsNoop() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        TelemetryQueue.restore([], defaults: defaults)
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 0)
    }

    // MARK: - 容量与 GC

    func testQueueTrimsToMaxSize() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        let now = Date()
        let count = TelemetryQueue.maxQueueSize + 50
        for i in 0..<count {
            TelemetryQueue.enqueue(makePayload(name: "n\(i)", timestamp: now), defaults: defaults, now: now)
        }

        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), TelemetryQueue.maxQueueSize)
        // 老的被丢弃，新的保留
        let items = TelemetryQueue.peek(defaults: defaults)
        XCTAssertEqual(items.first?.name, "n50")  // 前 50 个被丢
        XCTAssertEqual(items.last?.name, "n\(count - 1)")
    }

    func testQueueGCDropsExpiredEvents() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        let now = Date()
        let freshTimestamp = now
        let staleTimestamp = now.addingTimeInterval(-(TelemetryQueue.maxAge + 60))  // 7 天 + 1 分钟前

        TelemetryQueue.enqueue(makePayload(name: "fresh", timestamp: freshTimestamp), defaults: defaults, now: now)
        TelemetryQueue.enqueue(makePayload(name: "stale", timestamp: staleTimestamp), defaults: defaults, now: now)

        // 入队时 staleTimestamp 的事件立即被 GC（因为 trim 在 enqueue 内调用）
        let items = TelemetryQueue.peek(defaults: defaults)
        XCTAssertEqual(items.map(\.name), ["fresh"])
    }

    func testQueueGCManualCleanup() throws {
        let defaults = try makeTemporaryDefaults()
        defer { TelemetryQueue.clear(defaults: defaults) }

        // 用「未来」时间入队，绕过 enqueue 内的 trim
        let staleTimestamp = Date().addingTimeInterval(-(TelemetryQueue.maxAge + 60))
        let veryOldPayload = makePayload(name: "very_old", timestamp: staleTimestamp)

        // 直接调用测试专用 API，绕过 enqueue 的 trim
        // 这里用 enqueue 但传 now 比 stale 还早，确保 trim 不删
        let earlier = staleTimestamp.addingTimeInterval(-1)
        TelemetryQueue.enqueue(veryOldPayload, defaults: defaults, now: earlier)
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 1)

        // 手动 GC，应该清理掉
        TelemetryQueue.gc(defaults: defaults, now: Date())
        XCTAssertEqual(TelemetryQueue.count(defaults: defaults), 0)
    }

    // MARK: - 跨 defaults 隔离

    func testQueueIsolationBetweenSuites() throws {
        let defaultsA = try makeTemporaryDefaults()
        let defaultsB = try makeTemporaryDefaults()
        defer {
            TelemetryQueue.clear(defaults: defaultsA)
            TelemetryQueue.clear(defaults: defaultsB)
        }

        let now = Date()
        TelemetryQueue.enqueue(makePayload(name: "in_a", timestamp: now), defaults: defaultsA, now: now)

        XCTAssertEqual(TelemetryQueue.count(defaults: defaultsA), 1)
        XCTAssertEqual(TelemetryQueue.count(defaults: defaultsB), 0)
    }

    // MARK: - Helpers

    private func makePayload(name: String, timestamp: Date) -> TelemetryPayload {
        TelemetryPayload(
            name: name,
            timestamp: timestamp,
            sessionID: "test-session",
            deviceID: "test-device",
            appVersion: "0.0.0",
            iosVersion: "0",
            params: [:]
        )
    }

    private func makeTemporaryDefaults() throws -> UserDefaults {
        let suiteName = "VoiceTodoTests.Telemetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
