import XCTest
@testable import VoiceTodo

@MainActor
final class ActionButtonLaunchSignalTests: XCTestCase {
    func testNoRequestYieldsNothingToConsume() {
        let signal = ActionButtonLaunchSignal()
        XCTAssertFalse(signal.consumePendingRecordingRequest())
    }

    func testSingleRequestIsConsumedExactlyOnce() {
        let signal = ActionButtonLaunchSignal()
        signal.requestRecording()

        // onAppear 与 onChange 双路消费同一次按键，只能有一路拿到 true。
        XCTAssertTrue(signal.consumePendingRecordingRequest())
        XCTAssertFalse(signal.consumePendingRecordingRequest())
    }

    func testSecondPressAfterConsumptionStartsAnotherRecording() {
        let signal = ActionButtonLaunchSignal()
        signal.requestRecording()
        XCTAssertTrue(signal.consumePendingRecordingRequest())

        // 热启动下连按 Action Button：第二次必须能再次触发（Bool 标志会吞掉这次）。
        signal.requestRecording()
        XCTAssertTrue(signal.consumePendingRecordingRequest())
    }

    func testBurstOfRequestsCollapsesToOneRecording() {
        let signal = ActionButtonLaunchSignal()
        signal.requestRecording()
        signal.requestRecording()
        signal.requestRecording()

        // 未消费前的连续请求合并成一次，避免刚起的录音被立刻重启。
        XCTAssertTrue(signal.consumePendingRecordingRequest())
        XCTAssertFalse(signal.consumePendingRecordingRequest())
    }
}
