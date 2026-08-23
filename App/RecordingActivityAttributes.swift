import ActivityKit
import Foundation

/// 主 App 侧的录音 Live Activity 属性定义。
/// Widget Extension 会在自己的 target 中编译同名类型，两边保持结构一致即可。
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var transcript: String
        /// 录音开始时刻——LA 视图用 Text(timerInterval:countsDown: false) 原生走秒，App 不再每秒推 update
        var startedAt: Date

        init(isRecording: Bool = true, transcript: String = "", startedAt: Date = Date()) {
            self.isRecording = isRecording
            self.transcript = transcript
            self.startedAt = startedAt
        }
    }

    var name: String = "VoiceTodo Recording"
}

extension RecordingActivityAttributes {
    static let activityID = "com.voicetodo.recording"
}
