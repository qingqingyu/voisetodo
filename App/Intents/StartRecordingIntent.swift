import AppIntents

/// Action Button / 快捷指令：打开 App 并立刻开始录音。
///
/// 为什么不复用 `AddTodoIntent`：
/// `AddTodoIntent` 有必填的 `transcript: String` 参数。Siri 会用语音对话追问它，
/// 但 Action Button 不是语音会话，AppIntents 只能退回到通用的「请求参数值」界面 ——
/// 对 String 参数来说就是一个键盘文本框。所以按 Action Button 只会弹输入框，
/// 而且 `AddTodoIntent` 是后台 intent（`openAppWhenRun` 默认 false），压根不会开 App。
///
/// 本 intent 无参数 + `openAppWhenRun = true`，按一下就前台打开 App 起录音。
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.intent.record.title"
    static var description = IntentDescription("siri.intent.record.description")

    /// 必须打开 App：录音要麦克风 + 前台 UI（波形、手动停止），后台 intent 拿不到。
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceTodoLog.intent.info("intent.record.perform")
        // 只投递信号，不在这里起录音：
        // 冷启动时 perform 可能早于 SwiftUI 视图就绪，权限检查与录音由 App 侧统一处理。
        ActionButtonLaunchSignal.shared.requestRecording()
        return .result()
    }
}
