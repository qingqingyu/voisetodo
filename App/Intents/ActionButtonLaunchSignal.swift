import Foundation

/// Action Button / 快捷指令 → App 主界面的一次性信号中转。
///
/// `StartRecordingIntent` 设了 `openAppWhenRun = true`，它的 `perform()` 在 App 进程里执行，
/// 但拿不到 `VoiceTodoApp` 的 `@StateObject`（那是 SwiftUI 私有存储），所以用这个单例传递意图。
///
/// 冷启动时 `perform()` 和 SwiftUI 视图 `onAppear` 的先后顺序**没有保证**，因此设计成
/// 「请求计数 + 消费水位」而不是简单的 Bool：
/// - `perform()` 先跑 → token 已 +1，视图 `onAppear` 时消费掉；
/// - 视图先出现 → `onChange(of: recordingRequestToken)` 捕获后续 +1。
/// 两条路都调 `consumePendingRecordingRequest()`，水位保证同一次按键只会起一次录音。
///
/// 用计数而非 Bool 还有一个原因：热启动下用户连按两次 Action Button，Bool 从 true 置 true
/// 不会触发 `onChange`，第二次按键会被静默吞掉。
@MainActor
final class ActionButtonLaunchSignal: ObservableObject {
    static let shared = ActionButtonLaunchSignal()

    /// 累计收到的录音请求次数。视图侧 observe 这个值。
    @Published private(set) var recordingRequestToken = 0

    /// 已被消费到的水位。
    private var consumedToken = 0

    init() {}

    /// 记录一次「开始录音」请求（由 intent 的 perform 调用）。
    func requestRecording() {
        recordingRequestToken += 1
        VoiceTodoLog.intent.info("intent.signal.record_requested token=\(self.recordingRequestToken)")
    }

    /// 消费未处理的录音请求。
    /// - Returns: `true` 表示确有一次待处理请求；重复调用只会返回一次 `true`。
    func consumePendingRecordingRequest() -> Bool {
        guard recordingRequestToken > consumedToken else { return false }
        consumedToken = recordingRequestToken
        VoiceTodoLog.intent.info("intent.signal.record_consumed token=\(self.consumedToken)")
        return true
    }
}
