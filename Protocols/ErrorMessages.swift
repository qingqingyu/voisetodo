import Foundation

/// 用户可见的错误提示文案（国际化）
enum ErrorMessages {
    // 权限相关
    static let micDenied = String(localized: "error.mic_denied")
    static let speechDenied = String(localized: "error.speech_denied")
    static let speechUnavailable = String(localized: "error.speech_unavailable")
    static let audioSessionInterrupted = String(localized: "error.audio_interrupted")

    // 网络/AI 相关
    static let networkError = String(localized: "error.network")
    static let apiTimeout = String(localized: "error.api_timeout")
    static let apiRateLimited = String(localized: "error.api_rate_limited")
    static let apiError = String(localized: "error.api_error")
    static let jsonParsingFailed = String(localized: "error.json_parsing_failed")

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

    /// 带参数的格式化方法
    static func todoSaveFailedMessage(_ detail: String) -> String {
        String(localized: "detail.save_failed \(detail)")
    }

    static func pendingProcessedMessage(_ count: Int) -> String {
        String(localized: "ui.pending_processed \(count)")
    }
}
