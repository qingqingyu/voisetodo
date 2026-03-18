import Foundation

/// VoiceTodo 统一错误类型
enum VoiceTodoError: LocalizedError, Equatable {
    // Voice 模块
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied    // [v2] 新增
    case speechRecognitionUnavailable
    case audioSessionInterrupted
    case recordingFailed(String)              // [v2] 新增

    // Network / AI 模块
    case networkUnavailable
    case apiTimeout
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
            return "录音失败: \(detail)"
        case .networkUnavailable:
            return ErrorMessages.networkError
        case .apiTimeout:
            return ErrorMessages.apiTimeout
        case .apiResponseInvalid(let detail):
            return ErrorMessages.apiError + " (\(detail))"
        case .jsonParsingFailed(let detail):
            return ErrorMessages.jsonParsingFailed + " (\(detail))"
        case .storageReadFailed(let detail):
            return ErrorMessages.storageError + " (读取: \(detail))"
        case .storageWriteFailed(let detail):
            return ErrorMessages.storageError + " (写入: \(detail))"
        }
    }
}
