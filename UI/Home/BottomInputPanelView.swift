import SwiftUI

/// 底部输入面板：从底部滑出，默认录音模式（波形动画）。
///
/// 两种模式切换（HTML 规格）：
/// - 录音模式（默认）：显示波形 + "正在录音…说出你的待办"
/// - 键盘模式：波形隐藏 + 文本框 + 自动弹键盘
///
/// 左下角「改用键盘 / 改用录音」切换，右下角发送钮（录音红 / 键盘深色）。
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
            ZStack {
                // 下拉抓手
                Capsule()
                    .fill(WarmTheme.textMuted.opacity(0.5))
                    .frame(width: LayoutMetrics.grabHandleWidth, height: LayoutMetrics.grabHandleHeight)

                HStack {
                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(WarmTheme.textSecondary)
                            // 内容 32×32，触控热区扩展到 44×44（HIG 最小目标）
                            .frame(width: LayoutMetrics.closeIconSize, height: LayoutMetrics.closeIconSize)
                            .contentShape(Rectangle())
                            .frame(width: WarmSize.touch, height: WarmSize.touch)
                            .background(Circle().fill(WarmTheme.secondaryBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("InputPanelCloseButton")
                    .accessibilityLabel(String(localized: "panel.close"))
                }
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

            // 底部控制行：左下角切换 + 右下角发送
            HStack {
                // 左下角：改用键盘 / 改用录音
                Button {
                    onModeChange(!isKeyboardMode)
                } label: {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: isKeyboardMode ? "mic.fill" : "keyboard")
                            .font(.system(size: 16))
                        Text(isKeyboardMode
                             ? String(localized: "panel.switch_to_voice")
                             : String(localized: "panel.switch_to_keyboard"))
                            .font(WarmFont.caption(12))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                    .padding(.horizontal, WarmSpacing.sm)
                    .padding(.vertical, WarmSpacing.xs)
                    .background(
                        Capsule()
                            .fill(WarmTheme.secondaryBackground)
                            .overlay(
                                Capsule()
                                    .stroke(WarmTheme.primary.opacity(0.1), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("InputModeSwitch")

                Spacer()

                // 右下角：发送
                Button {
                    if isKeyboardMode {
                        guard !trimmedInputText.isEmpty else { return }
                        onSendText(trimmedInputText)
                    } else {
                        // 录音模式：发送 = 停止录音 + 进入处理
                        onStopRecordingForProcessing()
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: WarmSize.sendButton, height: WarmSize.sendButton)
                        .background(
                            Circle()
                                .fill(isKeyboardMode ? WarmTheme.deepAction : WarmTheme.primary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.5)
                .accessibilityIdentifier("InputSendButton")
                .accessibilityLabel(isKeyboardMode ? String(localized: "manual_input.generate") : String(localized: "a11y.stop_recording"))
                .accessibilityHint(isKeyboardMode ? String(localized: "manual_input.hint") : String(localized: "a11y.stop_hint"))
            }

            // 状态提示
            Text(isKeyboardMode
                 ? String(localized: "panel.keyboard_hint")
                 : String(localized: "panel.recording_hint"))
                .font(WarmFont.caption(LayoutMetrics.hintFontSize))
                .foregroundColor(WarmTheme.textMuted)
                .padding(.top, WarmSpacing.sm)
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
    }
}

// MARK: - Layout constants

private extension BottomInputPanelView {
    enum LayoutMetrics {
        static let grabHandleWidth: CGFloat = 38
        static let grabHandleHeight: CGFloat = 4
        static let closeIconSize: CGFloat = 32
        static let headerHeight: CGFloat = 32
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
