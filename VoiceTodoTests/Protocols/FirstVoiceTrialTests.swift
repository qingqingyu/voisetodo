import XCTest
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `FirstVoiceTrial` 状态机纯函数的单测(方案 §3.8b)。
final class FirstVoiceTrialTests: XCTestCase {

    // MARK: - armedState

    func testArmedStatePermissionsGrantedIsPending() {
        XCTAssertEqual(FirstVoiceTrial.armedState(allPermissionsGranted: true), .pending)
    }

    func testArmedStatePermissionsMissingIsDismissed() {
        // 权限没拿齐直接 dismissed:reprompt sheet 接管,不叠加两层引导
        XCTAssertEqual(FirstVoiceTrial.armedState(allPermissionsGranted: false), .dismissed)
    }

    // MARK: - nextState

    func testNextStatePendingWithConfirmedTodosBecomesCompleted() {
        XCTAssertEqual(
            FirstVoiceTrial.nextState(current: .pending, didConfirmTodos: true),
            .completed
        )
    }

    func testNextStatePendingWithEmptyBatchStaysPending() {
        // 空批次(ConfirmSheet 取消)不推进
        XCTAssertEqual(
            FirstVoiceTrial.nextState(current: .pending, didConfirmTodos: false),
            .pending
        )
    }

    func testNextStateTerminalStatesAreIdempotent() {
        // 终态幂等:再确认也不变回
        XCTAssertEqual(FirstVoiceTrial.nextState(current: .completed, didConfirmTodos: true), .completed)
        XCTAssertEqual(FirstVoiceTrial.nextState(current: .dismissed, didConfirmTodos: true), .dismissed)
    }

    func testNextStateNotArmedStaysNotArmed() {
        // 老用户升级(notArmed)确认待办不触发引导终结
        XCTAssertEqual(FirstVoiceTrial.nextState(current: .notArmed, didConfirmTodos: true), .notArmed)
    }

    // MARK: - showsHint

    func testShowsHintOnlyInPending() {
        XCTAssertTrue(FirstVoiceTrial.pending.showsHint)
        XCTAssertFalse(FirstVoiceTrial.notArmed.showsHint)
        XCTAssertFalse(FirstVoiceTrial.dismissed.showsHint)
        XCTAssertFalse(FirstVoiceTrial.completed.showsHint)
    }
}
