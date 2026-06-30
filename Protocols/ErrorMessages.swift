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
    static let rateLimited = String(localized: "error.rate_limited")
    static let quotaExhausted = String(localized: "error.quota_exhausted")
    static let serviceBusy = String(localized: "error.service_busy")
    static let apiError = String(localized: "error.api_error")
    static let apiResponseInvalidDetail = String(localized: "error.api_response_invalid_detail")
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
    static let historyCopied = String(localized: "history.copy_success")
    static let historyCreateFailed = String(localized: "history.create_failed")
    static let historyUpdateFailed = String(localized: "history.update_failed")
    static let historyDeleteFailed = String(localized: "history.delete_failed")
    static let historyCleanupFailed = String(localized: "history.cleanup_failed")
    static let historyReprocessBlocked = String(localized: "history.reprocess_blocked")
    static let historyReprocessFailed = String(localized: "history.reprocess_failed")

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
