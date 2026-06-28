import Foundation

/// VoiceTodo 统一错误类型
enum VoiceTodoError: LocalizedError, Equatable, Sendable {
    // Voice 模块
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied    // [v2] 新增
    case speechRecognitionUnavailable
    case audioSessionInterrupted
    case recordingFailed(String)              // [v2] 新增

    // Network / AI 模块
    case networkUnavailable
    case apiTimeout
    /// 被限流（HTTP 429）。retryAfter 来自响应的 Retry-After 头（秒），可能缺失。
    case apiRateLimited(retryAfter: TimeInterval?)
    case apiResponseInvalid(String)
    case jsonParsingFailed(String)

    // Storage 模块
    case storageReadFailed(String)            // [v2] 优化
    case storageWriteFailed(String)           // [v2] 优化

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
        case .recordingFailed(let detail):
            return String(localized: "error.recording_failed \(detail)")
        case .networkUnavailable:
            return ErrorMessages.networkError
        case .apiTimeout:
            return ErrorMessages.apiTimeout
        case .apiRateLimited:
            return ErrorMessages.apiRateLimited
        case .apiResponseInvalid(let detail):
            return String(localized: "error.api_response_invalid \(detail)")
        case .jsonParsingFailed(let detail):
            return String(localized: "error.json_parsing_detail \(detail)")
        case .storageReadFailed(let detail):
            return String(localized: "error.storage_read_failed \(detail)")
        case .storageWriteFailed(let detail):
            return String(localized: "error.storage_write_failed \(detail)")
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
