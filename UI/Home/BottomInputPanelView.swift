import SwiftUI

/// 底部输入面板：从底部滑出，根据 isKeyboardMode 切换录音 / 键盘模式。
///
/// 设计稿参考：
/// - 录音模式：wise-todo-variant1.html
/// - 键盘模式：wise-todo-keyboard.html
///
/// 录音模式布局（从上到下）：
///   抓手 → 状态文字（● 正在聆听 · 说出你今天要做的事）→ 波形 → [取消] [发送给 AI]
///
/// 键盘模式布局（fallback 触发时）：
///   抓手 → 警告 banner → 文本框 → [取消] [发送给 AI] → 重新尝试语音
/// 键盘模式布局（手动切换时）：
///   抓手 → 文本框 → [取消] [发送给 AI]
///
/// 共享 actionsRow：
///   - 取消：50pt 圆形 + X 图标，触发 onClose
///   - 发送：56pt 高大块按钮，flex:1 占满剩余宽度，触发 onSendText / onStopRecordingForProcessing
///
/// 键盘弹起时面板整体跟随 HomeView 的 `.padding(.bottom, keyboardHeight)` 推到键盘上方。
struct BottomInputPanelView: View {
    @Binding var isKeyboardMode: Bool
    @Binding var inputText: String
    let isRecording: Bool
    /// 键盘模式是否由录音失败 fallback 触发。true 时显示警告 banner + 「重新尝试语音」按钮；
    /// false（手动切换）时只显示文本框 + 操作行，避免误导用户「麦克风坏了」。
    let isFallbackMode: Bool
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
            // 抓手
            Capsule()
                .fill(WarmTheme.textMuted.opacity(0.5))
                .frame(width: LayoutMetrics.grabHandleWidth, height: LayoutMetrics.grabHandleHeight)
                .padding(.top, LayoutMetrics.grabHandleTopPadding)
                .padding(.bottom, LayoutMetrics.grabHandleBottomPadding)

            if isKeyboardMode {
                keyboardModeContent
            } else {
                recordingModeContent
            }
        }
        .padding(.horizontal, LayoutMetrics.panelHorizontalPadding)
        .padding(.bottom, LayoutMetrics.panelInternalBottomPadding)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.sheet, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.sheet, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 40, x: 0, y: -12)
        .accessibilityIdentifier("BottomInputPanel")
        // 诊断：监听 inputText / isKeyboardMode 变化，记录 binding 是否同步以及 canSend 状态。
        .onChange(of: inputText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🔍 [DIAG] bottom_panel.text_changed length=\(newValue.count) trimmed=\(trimmed.count) canSend=\(isKeyboardMode ? !trimmed.isEmpty : isRecording)")
        }
        .onChange(of: isKeyboardMode) { _, newValue in
            print("🔍 [DIAG] bottom_panel.mode_changed isKeyboardMode=\(newValue)")
        }
    }

    // MARK: - Recording mode

    @ViewBuilder
    private var recordingModeContent: some View {
        // 状态文字：● 正在聆听 · 说出你今天要做的事
        HStack(spacing: LayoutMetrics.statusTextSpacing) {
            Circle()
                .fill(WarmTheme.urgent)
                .frame(width: LayoutMetrics.statusDotSize, height: LayoutMetrics.statusDotSize)
            Text(String(localized: "panel.listening"))
                .font(.system(size: LayoutMetrics.statusFontSize, weight: .semibold))
                .foregroundColor(WarmTheme.urgent)
            Text(String(localized: "panel.listening_hint"))
                .font(.system(size: LayoutMetrics.statusFontSize, weight: .semibold))
                .foregroundColor(WarmTheme.textMuted)
        }
        .padding(.bottom, WarmSpacing.xl)

        // 波形（红色）
        WaveformView(color: WarmTheme.urgent, isActive: isRecording)
            .frame(height: LayoutMetrics.waveformHeight)
            .padding(.bottom, LayoutMetrics.waveformBottomPadding)

        // 操作行
        actionsRow
    }

    // MARK: - Keyboard mode

    @ViewBuilder
    private var keyboardModeContent: some View {
        // 警告 banner：仅 fallback 触发时显示。手动切换不显示，避免「麦克风坏了」误导。
        if isFallbackMode {
            HStack(alignment: .top, spacing: WarmSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: LayoutMetrics.bannerIconFontSize))
                    .foregroundColor(WarmTheme.warning)
                    .padding(.top, 1)
                Text(String(localized: "panel.fallback_banner"))
                    .font(.system(size: LayoutMetrics.bannerTextFontSize))
                    .foregroundColor(WarmTheme.warningText)
                    // 限制 3 行兜底小屏溢出：banner 文案在 zh-Hans / 小宽度（iPhone SE 375pt）下
                    // 可能达 4-5 行，配合 .fixedSize(vertical: true) 在 VStack 内会让面板总高度
                    // 超过屏幕可用区（屏幕高 - 顶部 safe area - 键盘高），导致顶部内容被键盘遮挡。
                    // lineLimit(3) + truncationTail 保证 banner 占用有界。
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, WarmSpacing.sm)
            .padding(.vertical, WarmSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .fill(WarmTheme.warning.opacity(0.1))
            )
            .padding(.bottom, WarmSpacing.xl)
        }

        // 文本框（包在一起：浅灰背景 + 边框）
        FocusableTextView(text: $inputText, fontSize: LayoutMetrics.inputFontSize)
            .frame(minHeight: LayoutMetrics.inputMinHeight)
            .padding(WarmSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.inputCornerRadius)
                    .fill(WarmTheme.inputFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.inputCornerRadius)
                    .stroke(WarmTheme.ink.opacity(0.08), lineWidth: 1)
            )
            .padding(.bottom, WarmSpacing.md)

        // 操作行
        actionsRow
            .padding(.bottom, WarmSpacing.xl)

        // 重新尝试语音（仅 fallback 模式显示，居中小按钮）
        // 死循环防护：用户手动点 retry → onModeChange(false) → switchInputPanelMode 重新启动录音；
        // 若权限仍被拒，coordinator 会再次 fallback，但用户已看到 toast 知道原因，不算无意义循环。
        if isFallbackMode {
            Button {
                print("🔍 [DIAG] bottom_panel.retry_voice_tapped")
                onModeChange(false)
            } label: {
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: LayoutMetrics.retryIconFontSize))
                    Text(String(localized: "panel.retry_voice"))
                        .font(.system(size: LayoutMetrics.retryTextFontSize, weight: .semibold))
                }
                .foregroundColor(WarmTheme.textMuted)
                .padding(.horizontal, WarmSpacing.xs)
                .padding(.vertical, WarmSpacing.xxs)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputRetryVoice")
            .accessibilityLabel(String(localized: "panel.retry_voice"))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Shared actions row

    /// [取消 圆形] [发送给 AI 大块按钮]
    /// 两种模式共享。取消触发 onClose，发送根据模式触发 onSendText / onStopRecordingForProcessing。
    private var actionsRow: some View {
        HStack(spacing: WarmSpacing.md) {
            // 取消按钮：50pt 圆形 + X 图标（设计稿 .cancel 样式）
            Button(action: {
                print("🔍 [DIAG] bottom_panel.close_tapped isKeyboardMode=\(isKeyboardMode) trimmed=\(trimmedInputText.count)")
                onClose()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: LayoutMetrics.cancelIconFontSize, weight: .semibold))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(width: LayoutMetrics.cancelButtonSize, height: LayoutMetrics.cancelButtonSize)
                    .background(
                        Circle().fill(WarmTheme.ink.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputPanelCloseButton")
            .accessibilityLabel(String(localized: "panel.close"))

            // 发送按钮：56pt 高大块按钮，flex:1 占满剩余宽度，飞机图标 + "发送给 AI"
            // （设计稿 .send 样式）。配色保持项目品牌色 WarmTheme.primary，
            // 而非设计稿的紫色 #4f46e5——以项目视觉系统为准。
            Button {
                print("🔍 [DIAG] bottom_panel.send_tapped isKeyboardMode=\(isKeyboardMode) canSend=\(canSend) trimmed=\(trimmedInputText.count)")
                if isKeyboardMode {
                    onSendText(trimmedInputText)
                } else {
                    onStopRecordingForProcessing()
                }
            } label: {
                HStack(spacing: WarmSpacing.xs) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: LayoutMetrics.sendIconFontSize, weight: .semibold))
                    Text(String(localized: "panel.send_to_ai"))
                        .font(.system(size: LayoutMetrics.sendTextFontSize, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: LayoutMetrics.sendButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.sendCornerRadius)
                        .fill(canSend ? WarmTheme.primary : WarmTheme.textMuted.opacity(0.3))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityIdentifier("InputSendButton")
            .accessibilityLabel(isKeyboardMode ? String(localized: "manual_input.generate") : String(localized: "a11y.stop_recording"))
        }
    }
}

// MARK: - Layout constants

private extension BottomInputPanelView {
    enum LayoutMetrics {
        static let grabHandleWidth: CGFloat = 38
        static let grabHandleHeight: CGFloat = 4
        static let grabHandleTopPadding: CGFloat = WarmSpacing.sm
        static let grabHandleBottomPadding: CGFloat = WarmSpacing.md
        // 文本框最小高度（设计稿 min-height: 76px）
        static let inputMinHeight: CGFloat = 76
        // 波形高度（设计稿 .wave height: 56px）
        static let waveformHeight: CGFloat = 56
        // 面板水平/底部 padding：来自设计稿像素值（22px），不归 4 借数系统。
        // 设计稿在此处刻意用非标准间距对齐 HTML 规格，保留以匹配视觉。
        static let panelHorizontalPadding: CGFloat = 22
        // 面板内部底部 padding（固定常量）。注意：HomeView 外部还有一个动态的
        // panelBottomPadding 计算属性（keyboardHeight + safeAreaInset），两者叠加生效。
        static let panelInternalBottomPadding: CGFloat = 22
        // 录音状态文字
        static let statusDotSize: CGFloat = 8
        static let statusTextSpacing: CGFloat = 6
        static let statusFontSize: CGFloat = 13
        static let waveformBottomPadding: CGFloat = 18
        // 键盘模式 banner
        static let bannerIconFontSize: CGFloat = 14
        static let bannerTextFontSize: CGFloat = 12
        // 键盘模式文本框
        static let inputFontSize: CGFloat = 15
        static let inputCornerRadius: CGFloat = 14
        // 操作行
        static let cancelButtonSize: CGFloat = 50
        static let cancelIconFontSize: CGFloat = 18
        static let sendButtonHeight: CGFloat = 56
        static let sendCornerRadius: CGFloat = 18
        static let sendIconFontSize: CGFloat = 16
        static let sendTextFontSize: CGFloat = 16
        // 重新尝试语音
        static let retryIconFontSize: CGFloat = 14
        static let retryTextFontSize: CGFloat = 12
    }
}

#Preview {
    BottomInputPanelView(
        isKeyboardMode: .constant(false),
        inputText: .constant(""),
        isRecording: true,
        isFallbackMode: false,
        onClose: {},
        onModeChange: { _ in },
        onSendText: { _ in },
        onStopRecordingForProcessing: {}
    )
    .padding()
    .background(WarmTheme.background)
}
