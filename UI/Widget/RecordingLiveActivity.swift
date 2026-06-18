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
                    HStack(spacing: WarmSpacing.xs) {
                        // 红色闪烁圆点
                        Circle()
                            .fill(.red)
                            .frame(width: WarmSpacing.sm, height: WarmSpacing.sm)
                            .opacity(context.state.isRecording ? 1.0 : 0.3)
                            .animation(
                                Animation.easeInOut(duration: 0.5)
                                    .repeatForever(autoreverses: true),
                                value: context.state.isRecording
                            )

                        Text(context.state.isRecording ? String(localized: "live_activity.recording") : String(localized: "live_activity.stopped"))
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
                        Text(String(localized: "live_activity.listening"))
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
            } compactLeading: {
                // 紧凑模式左侧 - 红色圆点
                Circle()
                    .fill(.red)
                    .frame(width: WarmSpacing.xs, height: WarmSpacing.xs)
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
                    .frame(width: WarmSpacing.xs, height: WarmSpacing.xs)
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
        HStack(spacing: WarmSpacing.sm) {
            // 录音状态指示器
            ZStack {
                Circle()
                    .stroke(.red.opacity(0.3), lineWidth: 2)
                    .frame(width: 32, height: 32)

                Circle()
                    .fill(.red)
                    .frame(width: WarmSpacing.sm, height: WarmSpacing.sm)
                    .opacity(context.state.isRecording ? 1.0 : 0.3)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true),
                        value: context.state.isRecording
                    )
            }

            // 文本内容
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                HStack {
                    Text(context.state.isRecording ? String(localized: "live_activity.recording_title") : "VoiceTodo")
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
                    Text(String(localized: "live_activity.listening_subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
    }
}

