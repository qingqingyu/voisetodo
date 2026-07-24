import Foundation

/// VoiceTodo 统一错误类型
///
/// ## UI 文案规范
/// 所有 case 的 `errorDescription` 走"**问题简述。+ 解决建议。**"两段式,不拼底层 detail。
/// 底层技术细节(DecodingError.localizedDescription / SwiftData error 等)只留在 case 关联值里,
/// 供 `VoiceTodoLog.errorSummary(_:)` 写日志/telemetry——用户看到的文案必须是普通用户能理解
/// 且能据此行动的。
enum VoiceTodoError: LocalizedError, Equatable, Sendable {
    // Voice 模块
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied    // [v2] 新增
    case speechRecognitionUnavailable
    case audioSessionInterrupted
    /// 录音失败(音频引擎启动失败 / 识别过程其他错误等)。detail 仅入日志(UI 走通用文案)。
    case recordingFailed(String)              // [v2] 新增

    // Network / AI 模块
    case networkUnavailable
    case apiTimeout
    /// 被限流（HTTP 429 velocity / IP 维度）。稍后重试即可恢复，retryAfter 可能缺失。
    case rateLimited(retryAfter: TimeInterval?)
    /// 配额耗尽（HTTP 429 quota_exceeded）。当日免费额度用尽，重试无意义：
    /// 走离线兜底 + 引导付费。tier 为 "free" / "pro"，resetAt 为本地日期边界（YYYY-MM-DD）。
    case quotaExhausted(tier: String, resetAt: String)
    /// 服务不可用（HTTP 503，如全局预算熔断 / 无可用 provider）。稍后重试。
    case serviceUnavailable
    /// 服务端错误（HTTP 5xx，非 503）。属可重试的服务类故障，计入熔断。
    case apiServerError(statusCode: Int)
    /// AI 返回的响应不是预期格式(非 JSON / 字段缺失 / 类型不匹配等)。detail 仅入日志。
    case apiResponseInvalid(String)
    /// JSON 解析失败但**非截断类**(模型返回了完整 JSON 但 schema 不匹配等)。detail 仅入日志。
    case jsonParsingFailed(String)
    /// 输入待办条数太多/字符太长,导致 AI 输出超过 max_tokens 被强制截断,JSON 不完整。
    /// UI 提示用户分批输入——这是**用户可解决**的错误,跟 jsonParsingFailed(服务端问题,重试)语义不同。
    case transcriptTooLong

    // Storage 模块
    /// SwiftData 读失败。detail 仅入日志(UI 走 storageError 通用文案)。
    case storageReadFailed(String)            // [v2] 优化
    /// SwiftData 写失败。detail 仅入日志(UI 走 storageError 通用文案)。
    case storageWriteFailed(String)           // [v2] 优化
    /// 待办 id 在 store 中查不到。UI 调用前已读过 todos,正常情况不应触发;
    /// 触发即说明数据竞争(并发删除/换库),用专门 case 让测试与日志能精准断言,
    /// 不再藏在 storageReadFailed("todo not found: ...") 字符串里。
    case todoNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return ErrorMessages.micDenied
        case .speechRecognitionPermissionDenied:
            return ErrorMessages.speechDenied
        case .speechRecognitionUnavailable:
            return ErrorMessages.speechUnavailable
        case .audioSessionInterrupted:
            return ErrorMessages.audioSessionInterrupted
        case .recordingFailed:
            // detail 通常是 AVAudioSession 的英文错误描述,对用户无意义——只显示通用文案。
            // detail 仍保留在关联值里供 VoiceTodoLog 打日志。
            return ErrorMessages.recordingFailedMessage
        case .networkUnavailable:
            return ErrorMessages.networkError
        case .apiTimeout:
            return ErrorMessages.apiTimeout
        case .rateLimited:
            return ErrorMessages.rateLimited
        case .quotaExhausted:
            return ErrorMessages.quotaExhausted
        case .serviceUnavailable:
            return ErrorMessages.serviceBusy
        case .apiServerError:
            return ErrorMessages.apiError
        case .apiResponseInvalid:
            // 不拼 detail——"AI 响应格式异常。请稍后重试。" 是用户能理解的版本。
            return ErrorMessages.apiResponseInvalidMessage
        case .jsonParsingFailed:
            // 不拼 detail——"JSON 不完整" / "Unexpected end of file" 这种底层文案对普通用户无意义。
            return ErrorMessages.jsonParsingFailed
        case .transcriptTooLong:
            return ErrorMessages.transcriptTooLong
        case .storageReadFailed, .storageWriteFailed:
            // SwiftData 错误描述也是程序员向的——只显示通用保存失败文案。
            return ErrorMessages.storageError
        case .todoNotFound:
            // 用户层不应见到这条(改时间 popover 失败时调用方会 fallback 到通用 toast)。
            // 仍提供文案以备测试 / 调试。
            return ErrorMessages.storageError
        }
    }
}

// MARK: - 错误归一化

extension VoiceTodoError {
    /// 把 raw SwiftData / Foundation 错误归一化为 `VoiceTodoError`。
    /// - 已经是 `VoiceTodoError` 的原样返回，避免双层包装。
    /// - 其他错误按读/写场景包成 `storageReadFailed` / `storageWriteFailed`。
    /// 用法：所有从 SwiftData 拿到 raw error 的 catch 块都应通过此函数归一化后再 throw。
    static func wrapStorage(_ error: Error, for operation: StorageOperation) -> VoiceTodoError {
        if let voiceError = error as? VoiceTodoError {
            return voiceError
        }
        switch operation {
        case .read:
            return .storageReadFailed(error.localizedDescription)
        case .write:
            return .storageWriteFailed(error.localizedDescription)
        }
    }

    enum StorageOperation: Sendable {
        case read
        case write
    }
}
