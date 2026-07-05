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
    let onSend: (String) -> Void

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
                    .fill(Color(white: 0.85))
                    .frame(width: 38, height: 4)

                HStack {
                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(WarmTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(white: 0.95)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("InputPanelCloseButton")
                    .accessibilityLabel(String(localized: "panel.close"))
                }
            }
            .frame(height: 32)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // 录音模式：波形动画
            if !isKeyboardMode {
                WaveformView(color: WarmTheme.primary)
                    .padding(.bottom, 16)
            }

            // 键盘模式：文本框
            if isKeyboardMode {
                FocusableTextView(text: $inputText, fontSize: 16)
                    .frame(minHeight: 50)
                    .padding(13)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(WarmTheme.primary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.bottom, 16)
            }

            // 底部控制行：左下角切换 + 右下角发送
            HStack {
                // 左下角：改用键盘 / 改用录音
                Button {
                    onModeChange(!isKeyboardMode)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isKeyboardMode ? "mic.fill" : "keyboard")
                            .font(.system(size: 16))
                        Text(isKeyboardMode
                             ? String(localized: "panel.switch_to_voice")
                             : String(localized: "panel.switch_to_keyboard"))
                            .font(.system(size: 12))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.95))
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
                        onSend(trimmedInputText)
                    } else {
                        // 录音模式：发送 = 停止录音 + 处理
                        onSend("")
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(isKeyboardMode ? Color(red: 0x2F/255, green: 0x2A/255, blue: 0x26/255) : WarmTheme.primary)
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
                .font(.system(size: 11.5))
                .foregroundColor(WarmTheme.textMuted)
                .padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 26)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 40, x: 0, y: -12)
        .accessibilityIdentifier("BottomInputPanel")
    }
}

#Preview {
    BottomInputPanelView(
        isKeyboardMode: .constant(false),
        inputText: .constant(""),
        isRecording: true,
        onClose: {},
        onModeChange: { _ in },
        onSend: { _ in }
    )
    .padding()
    .background(WarmTheme.background)
}
