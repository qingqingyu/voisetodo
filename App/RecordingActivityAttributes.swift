import ActivityKit
import Foundation

/// 主 App 侧的录音 Live Activity 属性定义。
/// Widget Extension 会在自己的 target 中编译同名类型，两边保持结构一致即可。
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var transcript: String
        var duration: TimeInterval

        init(isRecording: Bool = true, transcript: String = "", duration: TimeInterval = 0) {
            self.isRecording = isRecording
            self.transcript = transcript
            self.duration = duration
        }
    }

    var name: String = "VoiceTodo Recording"
}

extension RecordingActivityAttributes {
    static let activityID = "com.voicetodo.recording"
}
