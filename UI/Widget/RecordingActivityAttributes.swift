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

        /// 录音开始时刻——视图用 Text(timerInterval:countsDown: false) 原生走秒，App 不再每秒推 update
        var startedAt: Date

        /// 初始化
        init(isRecording: Bool = true, transcript: String = "", startedAt: Date = Date()) {
            self.isRecording = isRecording
            self.transcript = transcript
            self.startedAt = startedAt
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
}

