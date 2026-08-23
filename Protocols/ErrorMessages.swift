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
    /// 熔断器开启：服务近期不稳定，客户端冷却中。文案强调"稍后重试"而非"网络问题"。
    static let circuitOpen = String(localized: "error.circuit_open")
    static let rateLimited = String(localized: "error.rate_limited")
    /// 出口 IP 当日配额耗尽。与 rateLimited（velocity 短时）区分：当天不会恢复，
    /// 文案不暗示"用户额度用完"或"网络故障"，只说事实 + 行动建议。
    static let ipRateLimited = String(localized: "error.ip_rate_limited")
    static let quotaExhausted = String(localized: "error.quota_exhausted")
    /// 已订阅用户撞当日额度上限：不弹升级墙（已无法再升级），改为告知额度耗尽事实。
    /// 触发条件：quotaExhausted 时 `EntitlementManager.isPro == true`。
    /// 与 quotaExhausted 的区别：不含「免费」字样（订阅用户看到会困惑），并说明转写已保留。
    static let quotaExhaustedPro = String(localized: "error.quota_exhausted_pro")
    static let serviceBusy = String(localized: "error.service_busy")
    static let apiError = String(localized: "error.api_error")
    /// `apiResponseInvalid` case 关联值常用的 detail 字符串——被 NetworkClient 8 个失败路径
    /// 用作 enum 关联值。UI 不再显示这个文案(VoiceTodoError.errorDescription 走 apiResponseInvalidMessage)。
    static let apiResponseInvalidDetail = String(localized: "error.api_response_invalid_detail")
    /// `apiResponseInvalid` 给用户看的文案(无 detail,问题简述 + 重试建议)。
    static let apiResponseInvalidMessage = String(localized: "error.api_response_invalid_message")
    static let jsonParsingFailed = String(localized: "error.json_parsing_failed")
    /// 输入待办过多导致 AI 输出被 max_tokens 截断。用户可解决(分批输入),文案必须给具体建议。
    static let transcriptTooLong = String(localized: "error.transcript_too_long")

    // 「永不丢话」兜底提示:确定性解析失败后原文存为手动卡片
    /// 确定性解析失败(超长/响应异常等)后,追加在错误文案后的原文去向提示。
    static let manualCardSaved = String(localized: "error.manual_card_saved")
    /// AI 看过原文但没识别出待办(noTodos)时的原文去向提示。
    static let noTodosCardSaved = String(localized: "error.no_todos_card_saved")
    /// 录音阶段错误(中断/识别失败)已保存部分转写后,追加在错误文案后的提示。
    static let partialTranscriptSaved = String(localized: "error.partial_transcript_saved")

    // 存储相关
    static let storageError = String(localized: "error.storage")
    static let sharedStorageUnavailable = String(localized: "error.shared_storage_unavailable")
    /// 日期计算意外失败(Calendar.date(byAdding:...) 返回 nil)。
    /// 理论上不会触发(只有 invalid calendar + 单位组合才 nil),但若触发
    /// 需给用户比"存储错误"更准确的反馈——不是 SwiftData 写失败。
    static let dateCalcFailed = String(localized: "error.date_calc_failed")
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

    /// 「没能识别」分组「重新解析」后 AI 仍解析不出结构。提示用户原文片段保留、可继续手动处理。
    static let reextractStillEmpty = String(localized: "error.reextract.empty")

    /// 带参数的格式化方法
    static func todoSaveFailedMessage(_ detail: String) -> String {
        String(localized: "detail.save_failed \(detail)")
    }

    static func pendingProcessedMessage(_ count: Int) -> String {
        String(localized: "ui.pending_processed \(count)")
    }

    // Feedback 相关
    /// 反馈提交失败通用文案。worker.js 收到反馈后 Telegram 推送若失败,
    /// 仍返 200(已落 D1),所以这条文案触发的频率应该不高(仅客户端 → Worker 这一段网络故障)。
    static let feedbackFailed = String(localized: "error.feedback_failed")

    // Paywall / 订阅相关
    static let paywallPurchaseFailed = String(localized: "paywall.purchase_failed")
    /// 购买成功 toast:购买成功信号(EntitlementManager.purchaseSuccessCount)驱动
    /// paywall 收起时同时弹出 —— 收起不再只依赖 isPro 跳变,反馈也不能缺。
    static let paywallPurchaseSucceeded = String(localized: "paywall.purchase_success")
    /// 购买返回 unverified(端侧 StoreKit 验签失败):不能授信,提示重试或恢复购买。
    static let paywallPurchaseUnverified = String(localized: "paywall.purchase_unverified")
    /// 加载订阅方案失败(未发生购买,与 `paywallPurchaseFailed` 区分,避免误导用户)。
    /// `EntitlementManager.loadProducts()` catch + `PaywallView` `.error` 分支都用这条。
    static let paywallProductsLoadFailed = String(localized: "paywall.products_load_failed")
    static let paywallRestoring = String(localized: "paywall.restoring")
    static let paywallRestoreFailed = String(localized: "paywall.restore_failed")
    static let paywallRestoreNothing = String(localized: "paywall.restore_nothing")
}
