import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// 分段计时(任务书 §5):4 个时间点的差值、缺失语义、path 取值。
final class ExtractTimingTests: XCTestCase {
    private let clock = ContinuousClock()

    // MARK: - 差值计算

    func testResolveComputesAllThreeDeltas() {
        let t0 = clock.now
        let t1 = t0 + .milliseconds(120)
        let t2 = t0 + .milliseconds(2_400)
        let t3 = t0 + .milliseconds(3_500)

        let info = ExtractTimingInfo.resolve(speechEnd: t0, requestSent: t1, firstTodo: t2, done: t3, path: ExtractPath.liveVoice)

        XCTAssertEqual(info.speechToRequestMS, 120)
        XCTAssertEqual(info.speechToFirstTodoMS, 2_400)
        XCTAssertEqual(info.speechToDoneMS, 3_500)
        XCTAssertEqual(info.path, "live_voice")
    }

    /// 差值用 Duration 分量整数换算,不经浮点——大值不丢精度。
    func testResolveHandlesSubMillisecondAndLargeDeltas() {
        let t0 = clock.now
        let info = ExtractTimingInfo.resolve(
            speechEnd: t0,
            requestSent: t0 + .seconds(61_000),
            firstTodo: nil,
            done: nil,
            path: ExtractPath.liveVoice
        )
        XCTAssertEqual(info.speechToRequestMS, 61_000_000)
        XCTAssertNil(info.speechToFirstTodoMS)
        XCTAssertNil(info.speechToDoneMS)
    }

    // MARK: - 缺失语义

    /// 缺 T0(补解析/Siri/键盘):三个差值全不带,但 path 必带。
    func testResolveWithoutSpeechEndOmitsAllDeltasButKeepsPath() {
        let t1 = clock.now
        let t3 = t1 + .milliseconds(900)

        let info = ExtractTimingInfo.resolve(speechEnd: nil, requestSent: t1, firstTodo: t1, done: t3, path: ExtractPath.siri)

        XCTAssertNil(info.speechToRequestMS)
        XCTAssertNil(info.speechToFirstTodoMS)
        XCTAssertNil(info.speechToDoneMS)
        XCTAssertEqual(info.path, "siri")
    }

    /// 缺 T2(没有出现任何待办 / 非流式):speechToFirstTodoMS 不带,其余照常。
    func testResolveWithoutFirstTodoOmitsOnlyFirstTodoDelta() {
        let t0 = clock.now
        let info = ExtractTimingInfo.resolve(
            speechEnd: t0,
            requestSent: t0 + .milliseconds(100),
            firstTodo: nil,
            done: t0 + .milliseconds(1_800),
            path: ExtractPath.liveVoice
        )
        XCTAssertEqual(info.speechToRequestMS, 100)
        XCTAssertNil(info.speechToFirstTodoMS)
        XCTAssertEqual(info.speechToDoneMS, 1_800)
    }

    /// 取消路径:done 传 nil → 不带 speechToDoneMS(取消不是完成)。
    func testResolveWithCancelledDoneNil() {
        let t0 = clock.now
        let info = ExtractTimingInfo.resolve(
            speechEnd: t0,
            requestSent: t0 + .milliseconds(100),
            firstTodo: t0 + .milliseconds(1_000),
            done: nil,
            path: ExtractPath.liveVoice
        )
        XCTAssertEqual(info.speechToRequestMS, 100)
        XCTAssertEqual(info.speechToFirstTodoMS, 1_000)
        XCTAssertNil(info.speechToDoneMS)
    }

    // MARK: - path 取值

    func testPathMappingFromRequestPath() {
        XCTAssertEqual(ExtractPath.fromRequestPath("pending_batch"), "pending_recovery")
        XCTAssertEqual(ExtractPath.fromRequestPath("siri"), "siri")
        XCTAssertEqual(ExtractPath.fromRequestPath("reextract"), "reextract")
        XCTAssertEqual(ExtractPath.fromRequestPath("edit_reextract"), "reextract")
        XCTAssertEqual(ExtractPath.fromRequestPath("main"), "main")
        XCTAssertEqual(ExtractPath.fromRequestPath("anything-else"), "main")
    }

    // MARK: - tracker 的 first-write-wins

    func testTrackerKeepsFirstRequestSentAndFirstTodo() {
        let tracker = ExtractTimingTracker(speechEnd: clock.now, path: ExtractPath.liveVoice)
        let first = clock.now
        let second = first + .milliseconds(5_000)

        tracker.markRequestSent(first)
        tracker.markRequestSent(second)
        tracker.markFirstTodo(first)
        XCTAssertFalse(tracker.markFirstTodo(second), "第二次 markFirstTodo 应返回 false")

        let snapshots = tracker.snapshots()
        XCTAssertEqual(snapshots.requestSent, first, "重试不覆盖首请求时刻")
        XCTAssertEqual(snapshots.firstTodo, first, "只有第一条待办算 T2")
    }

    /// 无 T0 的 tracker(键盘路径):path 标记生效,差值全 nil。
    func testTrackerWithoutSpeechEndProducesPathOnly() {
        let tracker = ExtractTimingTracker(speechEnd: nil, path: ExtractPath.keyboard)
        tracker.markRequestSent(clock.now)

        let info = ExtractTimingInfo.resolve(
            speechEnd: tracker.speechEnd,
            requestSent: tracker.snapshots().requestSent,
            firstTodo: tracker.snapshots().firstTodo,
            done: clock.now,
            path: tracker.path
        )
        XCTAssertEqual(info.path, "keyboard")
        XCTAssertNil(info.speechToRequestMS)
        XCTAssertNil(info.speechToDoneMS)
    }

    // MARK: - 任务域解析(resolveCurrentOutcomeTiming)

    /// 绑定 tracker 的任务域:解出完整参数(live_voice 主路径)。
    func testResolveCurrentOutcomeTimingReadsBoundTracker() async {
        let tracker = ExtractTimingTracker(speechEnd: clock.now, path: ExtractPath.liveVoice)
        tracker.markRequestSent(clock.now)
        tracker.markFirstTodo(clock.now)

        let info = await VoiceTodoLog.$extractTiming.withValue(tracker) {
            ExtractTimingInfo.resolveCurrentOutcomeTiming(doneAt: clock.now)
        }
        XCTAssertEqual(info.path, "live_voice")
        XCTAssertNotNil(info.speechToRequestMS)
        XCTAssertNotNil(info.speechToFirstTodoMS)
        XCTAssertNotNil(info.speechToDoneMS)
    }

    /// 未绑定 tracker 的任务域:path 从 requestPath 映射(补解析/Siri/重新解析)。
    func testResolveCurrentOutcomeTimingFallsBackToRequestPath() async {
        let pendingInfo = await VoiceTodoLog.$extractTiming.withValue(nil) {
            VoiceTodoLog.$requestPath.withValue("pending_batch") {
                ExtractTimingInfo.resolveCurrentOutcomeTiming(doneAt: nil)
            }
        }
        XCTAssertEqual(pendingInfo.path, "pending_recovery")
        XCTAssertNil(pendingInfo.speechToRequestMS)

        let siriInfo = await VoiceTodoLog.$requestPath.withValue("siri") {
            ExtractTimingInfo.resolveCurrentOutcomeTiming(doneAt: nil)
        }
        XCTAssertEqual(siriInfo.path, "siri")
    }
}
