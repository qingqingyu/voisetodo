import Foundation

/// 用户可见的错误提示文案
enum ErrorMessages {
    // 权限相关
    static let micDenied = "需要麦克风权限才能录音，请在设置中开启"
    static let speechDenied = "需要语音识别权限，请在设置中开启"    // [v2]
    static let speechUnavailable = "语音识别暂不可用，请稍后重试"
    static let audioSessionInterrupted = "录音被中断，请重试"

    // 网络/AI 相关
    static let networkError = "网络连接失败，请检查网络后重试"
    static let apiTimeout = "请求超时，请稍后重试"
    static let apiError = "理解失败，请稍后重试"
    static let jsonParsingFailed = "解析失败，请稍后重试"

    // 存储相关
    static let storageError = "保存失败，请重试"

    // UI 提示
    static let noTodosFound = "未识别到待办事项"
    static let savedOffline = "已保存原始记录，联网后将自动整理"
    static let pendingProcessed = "有 %d 条待办已整理，点击查看"
    static let addedSuccess = "已添加到待办"
    static let permissionsRequired = "请先授予麦克风和语音识别权限"
}
