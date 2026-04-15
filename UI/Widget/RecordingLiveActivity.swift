import ActivityKit
import WidgetKit
import SwiftUI

/// 录音状态 Live Activity Widget
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // 锁屏/通知中心显示的视图
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            // Dynamic Island 显示
            DynamicIsland {
                // 展开状态的内容
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        // 红色闪烁圆点
                        Circle()
                            .fill(.red)
                            .frame(width: 12, height: 12)
                            .opacity(context.state.isRecording ? 1.0 : 0.3)
                            .animation(
                                Animation.easeInOut(duration: 0.5)
                                    .repeatForever(autoreverses: true),
                                value: context.state.isRecording
                            )

                        Text(context.state.isRecording ? "录音中" : "已停止")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    // 录音时长
                    Text(RecordingActivityAttributes.formatDuration(context.state.duration))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    // 实时转写文本预览
                    if !context.state.transcript.isEmpty {
                        Text(context.state.transcript)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("正在聆听...")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
            } compactLeading: {
                // 紧凑模式左侧 - 红色圆点
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(context.state.isRecording ? 1.0 : 0.4)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true),
                        value: context.state.isRecording
                    )
            } compactTrailing: {
                // 紧凑模式右侧 - 时长
                Text(RecordingActivityAttributes.formatDuration(context.state.duration))
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.medium)
            } minimal: {
                // 最小化状态 - 红点
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .opacity(context.state.isRecording ? 1.0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true),
                        value: context.state.isRecording
                    )
            }
        }
    }
}

// MARK: - Lock Screen View

/// 锁屏 Live Activity 视图
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            // 录音状态指示器
            ZStack {
                Circle()
                    .stroke(.red.opacity(0.3), lineWidth: 2)
                    .frame(width: 36, height: 36)

                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .opacity(context.state.isRecording ? 1.0 : 0.3)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true),
                        value: context.state.isRecording
                    )
            }

            // 文本内容
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.state.isRecording ? "VoiceTodo 录音中" : "VoiceTodo")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Text(RecordingActivityAttributes.formatDuration(context.state.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if !context.state.transcript.isEmpty {
                    Text(context.state.transcript)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("正在聆听你的声音...")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview("Recording Activity", as: .content, using: RecordingActivityAttributes.previewContext) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(
        isRecording: true,
        transcript: "明天去银行办卡，顺便买菜",
        duration: 15
    )

    RecordingActivityAttributes.ContentState(
        isRecording: true,
        transcript: "",
        duration: 3
    )

    RecordingActivityAttributes.ContentState(
        isRecording: false,
        transcript: "完成周报",
        duration: 45
    )
}
