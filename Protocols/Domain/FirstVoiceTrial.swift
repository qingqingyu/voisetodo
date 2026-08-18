import Foundation

/// 首次语音试用引导的状态。onboarding 结束时 arm，用户完成第一条语音待办后终结。
///
/// 存 UserDefaults（key: `firstVoiceTrialState`），跟随
/// `@AppStorage("hasCompletedOnboarding")` / `@AppStorage("hasShownExpandMonthHint")`
/// 的既有模式，不引入新命名空间。
///
/// `completed` 同时是「wow 后置 paywall」的唯一触发入口
/// （`AppCoordinator.showPaywallAfterFirstWow()`），见
/// docs/onboarding-first-voice-trial.md §3.5。
enum FirstVoiceTrial: String {
    /// 默认值：onboarding 还没走完（或老用户升级上来）。
    case notArmed
    /// 已 arm，等用户完成第一条语音待办。仅此状态显示 hint。
    case pending
    /// 用户点了「知道了」主动关闭。终态。
    case dismissed
    /// 首次语音待办已落库。终态。
    case completed

    static let storageKey = "firstVoiceTrialState"

    /// onboarding 结束时决定初始状态。
    ///
    /// 权限没拿齐时直接给 `.dismissed` 而非 `.pending`：**不叠加两层引导**——
    /// 跳过权限的用户已经由 `UI/Shared/VoicePermissionRepromptSheet.swift` 在点 FAB
    /// 时接管（触发条件见 `HomeView.startRecordingForInputPanel()` 的
    /// `hasSkippedInOnboarding && !allPermissionsGranted` 分支）。两个引导同屏会互相打架。
    static func armedState(allPermissionsGranted: Bool) -> FirstVoiceTrial {
        allPermissionsGranted ? .pending : .dismissed
    }

    /// 是否应该显示 hint。终态和未 arm 都不显示。
    var showsHint: Bool { self == .pending }

    /// 确认了一批待办之后的状态推进。幂等：终态和空批次原样返回。
    static func nextState(current: FirstVoiceTrial, didConfirmTodos: Bool) -> FirstVoiceTrial {
        guard current == .pending, didConfirmTodos else { return current }
        return .completed
    }
}
