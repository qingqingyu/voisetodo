import SwiftUI

/// 底部输入面板：从底部滑出，默认录音模式（波形动画）。
///
/// 两种模式切换（HTML 规格）：
/// - 录音模式（默认）：显示波形 + "正在录音…说出你的待办"
/// - 键盘模式：波形隐藏 + 文本框 + 自动弹键盘
///
/// 操作按钮（切换 + 发送）放在顶部行——键盘弹起时不会遮挡。
struct BottomInputPanelView: View {
    @Binding var isKeyboardMode: Bool
    @Binding var inputText: String
    let isRecording: Bool
    let onClose: () -> Void
    let onModeChange: (Bool) -> Void
    /// 键盘模式：发送文本。录音模式此回调不会被调用，改触发 onStopRecordingForProcessing。
    let onSendText: (String) -> Void
    /// 录音模式专用：停止录音并进入处理流程。
    let onStopRecordingForProcessing: () -> Void

    private var trimmedInputText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        isKeyboardMode ? !trimmedInputText.isEmpty : isRecording
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部操作行：抓手 + 切换 + 发送 + 关闭
            // 所有操作按钮在顶部，键盘弹起时不遮挡。
            ZStack {
                // 下拉抓手（居中）
                Capsule()
                    .fill(WarmTheme.textMuted.opacity(0.5))
                    .frame(width: LayoutMetrics.grabHandleWidth, height: LayoutMetrics.grabHandleHeight)

                HStack(spacing: WarmSpacing.xs) {
                    // 左：改用键盘 / 改用录音
                    Button {
                        print("🔍 [DIAG] bottom_panel.mode_tapped current_isKeyboardMode=\(isKeyboardMode) trimmed=\(trimmedInputText.count)")
                        onModeChange(!isKeyboardMode)
                    } label: {
                        Image(systemName: isKeyboardMode ? "mic.fill" : "keyboard")
                            .font(.system(size: 14))
                            .foregroundColor(WarmTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(WarmTheme.secondaryBackground))
                            // 扩 hit area 到 44x44（Apple HIG 最小可触控）。
                            // 视觉尺寸保持 28x28 不变，外层 frame 仅用于 hit-test。
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("InputModeSwitch")

                    Spacer()

                    // 右：发送 + 关闭。spacing 用 WarmSpacing.md（16pt）让两个 44pt hit area 不重叠。
                    HStack(spacing: WarmSpacing.md) {
                        // 发送钮
                        Button {
                            print("🔍 [DIAG] bottom_panel.send_tapped isKeyboardMode=\(isKeyboardMode) canSend=\(canSend) trimmed=\(trimmedInputText.count)")
                            if isKeyboardMode {
                                onSendText(trimmedInputText)
                            } else {
                                onStopRecordingForProcessing()
                            }
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(canSend ? (isKeyboardMode ? WarmTheme.deepAction : WarmTheme.primary) : WarmTheme.textMuted.opacity(0.3))
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .accessibilityIdentifier("InputSendButton")
                        .accessibilityLabel(isKeyboardMode ? String(localized: "manual_input.generate") : String(localized: "a11y.stop_recording"))

                        // 关闭钮
                        Button(action: {
                            print("🔍 [DIAG] bottom_panel.close_tapped isKeyboardMode=\(isKeyboardMode) trimmed=\(trimmedInputText.count)")
                            onClose()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(WarmTheme.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(WarmTheme.secondaryBackground))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("InputPanelCloseButton")
                        .accessibilityLabel(String(localized: "panel.close"))
                    }
                }
                .padding(.horizontal, WarmSpacing.sm)
            }
            .frame(height: LayoutMetrics.headerHeight)
            .padding(.top, WarmSpacing.sm)
            .padding(.bottom, WarmSpacing.xs)

            // 录音模式：波形动画
            if !isKeyboardMode {
                WaveformView(color: WarmTheme.primary, isActive: isRecording)
                    .padding(.bottom, WarmSpacing.md)
            }

            // 键盘模式：文本框
            if isKeyboardMode {
                FocusableTextView(text: $inputText, fontSize: 16)
                    .frame(minHeight: LayoutMetrics.inputMinHeight)
                    .padding(WarmSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.card)
                            .stroke(WarmTheme.primary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.bottom, WarmSpacing.md)
            }

            // 状态提示
            Text(isKeyboardMode
                 ? String(localized: "panel.keyboard_hint")
                 : String(localized: "panel.recording_hint"))
                .font(WarmFont.caption(LayoutMetrics.hintFontSize))
                .foregroundColor(WarmTheme.textMuted)
                .padding(.bottom, WarmSpacing.sm)
        }
        .padding(.horizontal, LayoutMetrics.panelHorizontalPadding)
        .padding(.bottom, LayoutMetrics.panelBottomPadding)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.sheet, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.sheet, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 40, x: 0, y: -12)
        .accessibilityIdentifier("BottomInputPanel")
        // 诊断：监听 inputText / isKeyboardMode 变化，记录 binding 是否同步以及 canSend 状态。
        // 用于排查"点发送无反应"——确认 canSend 计算路径是否被正确触发。
        .onChange(of: inputText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🔍 [DIAG] bottom_panel.text_changed length=\(newValue.count) trimmed=\(trimmed.count) canSend=\(isKeyboardMode ? !trimmed.isEmpty : isRecording)")
        }
        .onChange(of: isKeyboardMode) { _, newValue in
            print("🔍 [DIAG] bottom_panel.mode_changed isKeyboardMode=\(newValue)")
        }
    }
}

// MARK: - Layout constants

private extension BottomInputPanelView {
    enum LayoutMetrics {
        static let grabHandleWidth: CGFloat = 38
        static let grabHandleHeight: CGFloat = 4
        // header 容器高度对齐 Apple HIG 最小可触控 44pt，避免 44pt 按钮溢出裁切。
        static let headerHeight: CGFloat = 44
        static let inputMinHeight: CGFloat = 50
        static let hintFontSize: CGFloat = 11.5
        static let panelHorizontalPadding: CGFloat = 18
        static let panelBottomPadding: CGFloat = 26
    }
}

#Preview {
    BottomInputPanelView(
        isKeyboardMode: .constant(false),
        inputText: .constant(""),
        isRecording: true,
        onClose: {},
        onModeChange: { _ in },
        onSendText: { _ in },
        onStopRecordingForProcessing: {}
    )
    .padding()
    .background(WarmTheme.background)
}
