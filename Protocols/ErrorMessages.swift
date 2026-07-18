import Foundation

/// 用户可见的错误提示文案（国际化）
enum ErrorMessages {
    // 权限相关
    static let micDenied = String(localized: "error.mic_denied")
    static let speechDenied = String(localized: "error.speech_denied")
    static let speechUnavailable = String(localized: "error.speech_unavailable")
    static let audioSessionInterrupted = String(localized: "error.audio_interrupted")

    /// 录音失败兜底文案（带 detail 参数）。与 VoiceTodoError.errorDescription 共用 l10n key
    /// `error.recording_failed`，确保单一文案来源。
    static func recordingFailed(_ detail: String) -> String {
        String(localized: "error.recording_failed \(detail)")
    }

    // 网络/AI 相关
    static let networkError = String(localized: "error.network")
    static let apiTimeout = String(localized: "error.api_timeout")
    static let rateLimited = String(localized: "error.rate_limited")
    static let quotaExhausted = String(localized: "error.quota_exhausted")
    static let serviceBusy = String(localized: "error.service_busy")
    static let apiError = String(localized: "error.api_error")
    /// `apiResponseInvalid` 的旧 detail 字符串——保留给 ExtractorTests 断言用(测试代码会把它当 detail 传进去验证 enum 相等)。
    /// UI 不再用这个文案(VoiceTodoError.errorDescription 走 apiResponseInvalidMessage)。
    static let apiResponseInvalidDetail = String(localized: "error.api_response_invalid_detail")
    /// `apiResponseInvalid` 给用户看的文案(无 detail,问题简述 + 重试建议)。
    static let apiResponseInvalidMessage = String(localized: "error.api_response_invalid_message")
    static let jsonParsingFailed = String(localized: "error.json_parsing_failed")
    /// 输入待办过多导致 AI 输出被 max_tokens 截断。用户可解决(分批输入),文案必须给具体建议。
    static let transcriptTooLong = String(localized: "error.transcript_too_long")
    /// 录音失败通用文案(不暴露 AVAudioSession 英文细节)。
    static let recordingFailedMessage = String(localized: "error.recording_failed_message")

    // 存储相关
    static let storageError = String(localized: "error.storage")
    static let sharedStorageUnavailable = String(localized: "error.shared_storage_unavailable")

    // 详情页
    static let todoSaved = String(localized: "detail.saved")
    static let todoDeleted = String(localized: "detail.deleted")
    static let todoDeleteFailed = String(localized: "detail.delete_failed")

    // UI 提示
    static let noTodosFound = String(localized: "ui.no_todos_found")
    static let savedOffline = String(localized: "ui.saved_offline")
    static let addedSuccess = String(localized: "ui.added_success")
    static let systemCalendarSyncFailed = String(localized: "ui.system_calendar_sync_failed")
    static let permissionsRequired = String(localized: "ui.permissions_required")
    static let finishOnboardingFirst = String(localized: "ui.finish_onboarding_first")
    /// 录音模式发送时录音已不在活动状态——给用户明确反馈而不是静默关闭面板。
    static let recordingNotActive = String(localized: "ui.recording_not_active")

    /// 带参数的格式化方法
    static func todoSaveFailedMessage(_ detail: String) -> String {
        String(localized: "detail.save_failed \(detail)")
    }

    static func pendingProcessedMessage(_ count: Int) -> String {
        String(localized: "ui.pending_processed \(count)")
    }

    // Paywall / 订阅相关
    static let paywallPurchaseFailed = String(localized: "paywall.purchase_failed")
    static let paywallRestoring = String(localized: "paywall.restoring")
    static let paywallRestoreFailed = String(localized: "paywall.restore_failed")
    static let paywallRestoreNothing = String(localized: "paywall.restore_nothing")
}
