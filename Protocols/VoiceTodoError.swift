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
            return String(localized: "error.recording_failed \(detail)")
        case .networkUnavailable:
            return ErrorMessages.networkError
        case .apiTimeout:
            return ErrorMessages.apiTimeout
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
