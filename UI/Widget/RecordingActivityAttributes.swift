import ActivityKit
import Foundation

/// 录音状态 Live Activity 属性
/// 用于 Dynamic Island 和锁屏显示录音状态
struct RecordingActivityAttributes: ActivityAttributes {
    // MARK: - Content State

    /// 动态状态（会随时间变化）
    public struct ContentState: Codable, Hashable {
        /// 是否正在录音
        var isRecording: Bool

        /// 当前转写文本
        var transcript: String

        /// 录音时长（秒）
        var duration: TimeInterval

        /// 初始化
        init(isRecording: Bool = true, transcript: String = "", duration: TimeInterval = 0) {
            self.isRecording = isRecording
            self.transcript = transcript
            self.duration = duration
        }
    }

    // MARK: - Static Attributes

    /// 活动名称（静态属性）
    var name: String = "VoiceTodo Recording"

}

// MARK: - Helper Extensions

extension RecordingActivityAttributes {
    /// Activity 类型标识符
    static let activityID = "com.voicetodo.recording"

    /// 格式化时长显示
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

