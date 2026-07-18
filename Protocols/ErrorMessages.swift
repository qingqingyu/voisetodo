import Foundation

/// 用户可见的错误提示文案（国际化）
enum ErrorMessages {
    // 权限相关
    static let micDenied = String(localized: "error.mic_denied")
    static let speechDenied = String(localized: "error.speech_denied")
    static let speechUnavailable = String(localized: "error.speech_unavailable")
    static let audioSessionInterrupted = String(localized: "error.audio_interrupted")

    /// 录音失败通用文案(不暴露 AVAudioSession 英文细节)。
    /// 旧 `recordingFailed(_:)` 带参数版本已删除——detail 仅入 log,UI 统一走这条文案。
    static let recordingFailedMessage = String(localized: "error.recording_failed_message")

    // 网络/AI 相关
    static let networkError = String(localized: "error.network")
    static let apiTimeout = String(localized: "error.api_timeout")
    static let rateLimited = String(localized: "error.rate_limited")
    static let quotaExhausted = String(localized: "error.quota_exhausted")
    static let serviceBusy = String(localized: "error.service_busy")
    static let apiError = String(localized: "error.api_error")
    /// `apiResponseInvalid` case 关联值常用的 detail 字符串——被 NetworkClient 8 个失败路径
    /// 用作 enum 关联值(便于测试断言 `== .apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)`)。
    /// UI 不再显示这个文案(VoiceTodoError.errorDescription 走 apiResponseInvalidMessage)。
    static let apiResponseInvalidDetail = String(localized: "error.api_response_invalid_detail")
    /// `apiResponseInvalid` 给用户看的文案(无 detail,问题简述 + 重试建议)。
    static let apiResponseInvalidMessage = String(localized: "error.api_response_invalid_message")
    static let jsonParsingFailed = String(localized: "error.json_parsing_failed")
    /// 输入待办过多导致 AI 输出被 max_tokens 截断。用户可解决(分批输入),文案必须给具体建议。
    static let transcriptTooLong = String(localized: "error.transcript_too_long")

    // 存储相关
    static let storageError = String(localized: "error.storage")
    static let sharedStorageUnavailable = String(localized: "error.shared_storage_unavailable")
    /// 兜底文案——任何**非 VoiceTodoError 类型**的系统错误(URLError / SwiftDataError /
    /// 第三方库原生 NSError 等)统一显示这条,不暴露 `.localizedDescription` 的英文
    /// 技术描述。原始 error 通过 `VoiceTodoLog.errorSummary(_:)` 入日志/telemetry,
    /// 诊断信息不丢。
    /// 触发位置:`AppCoordinator.handleError(_:)` 的 `else` 分支。
    static let unexpectedError = String(localized: "error.unexpected")

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
