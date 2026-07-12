import SwiftUI

/// 底部输入面板：从底部滑出，根据 isKeyboardMode 切换录音 / 键盘模式。
///
/// 设计稿参考：
/// - 录音模式：wise-todo-variant1.html
/// - 键盘模式：wise-todo-keyboard.html
///
/// 录音模式布局（从上到下）：
///   抓手 → 状态文字（● 正在聆听 · 说出你今天要做的事）→ 波形 → 录音时长 → [取消] [发送给 AI]
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
/// 字体策略：Text 全部用 SwiftUI 语义化字体（.footnote / .caption / .callout / .title3），
/// 跟随 Dynamic Type 视障缩放。Image 图标保留 .system(size:)——图标不需要
/// Dynamic Type，SF Symbols 有自己的缩放语义。`.title3` 仅用于录音计时器，
/// 因为计时器是录音模式的视觉焦点，需要比正文更重的存在感。
///
/// 键盘弹起时面板整体跟随 HomeView 的 `.padding(.bottom, keyboardHeight)` 推到键盘上方。
struct BottomInputPanelView: View {
    @Binding var isKeyboardMode: Bool
    @Binding var inputText: String
    let isRecording: Bool
    /// 录音模式的实时转写文本（来自 SFSpeechRecognizer partial results）。
    /// 空字符串时不显示，有内容时在波形上方展示，让用户确认"它有没有听对"。
    let transcript: String
    /// 当前音频电平 (0...1)，驱动波形动画
    let audioLevel: Float
    /// 键盘模式是否由录音失败 fallback 触发。true 时显示警告 banner + 「重新尝试语音」按钮；
    /// false（手动切换）时只显示文本框 + 操作行，避免误导用户「麦克风坏了」。
    let isFallbackMode: Bool
    let onClose: () -> Void
    let onModeChange: (Bool) -> Void
    /// 键盘模式：发送文本。录音模式此回调不会被调用，改触发 onStopRecordingForProcessing。
    let onSendText: (String) -> Void
    /// 录音模式专用：停止录音并进入处理流程。
    let onStopRecordingForProcessing: () -> Void

    /// 录音时长（秒），由 ticker Task 每秒刷新（用 Date() 差值计算，非累加）。
    /// ticker 跟随 isRecording 生命周期——isRecording=true 时启动，false 时自动取消，
    /// 无空转，无内存泄漏（比 Timer + onDisappear 更可靠）。
    @State private var recordingElapsed: TimeInterval = 0

    private var trimmedInputText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        isKeyboardMode ? !trimmedInputText.isEmpty : isRecording
    }

    /// 把秒数格式化为 "MM:SS"，>=1 小时切到 "H:MM:SS"。
    /// 负数（类型允许但实际不会出现）按 0 处理，避免负数取整乱码。
    /// NaN/Infinity（调试器暂停后恢复等极端场景）也按 0 处理，
    /// 否则 Int(Infinity) 会触发 runtime trap 导致 UI 崩溃。
    /// 可视化文本不本地化（ASCII 冒号是国际通用格式，iOS Clock app 同样用 MM:SS）；
    /// 但无障碍标签 `a11y.recording_duration` 走本地化——视障用户需听完整描述。
    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
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
        // P1: ticker Task 跟随 isRecording 生命周期——isRecording=true 时启动并捕获开始时间，
        // false 时自动取消。elapsed 用 Date() 计算（非累加），即使 Task 重启也不丢精度。
        // startedAt 在 Task 内部捕获，单一来源，无外部状态参与。
        //
        // 已知取舍：isRecording 快速翻转（如权限重试）时，新 Task 入口归零 + sleep 1s
        // 才更新，用户会看到计时器从旧值跳回 "00:00" 再 1 秒后到 "00:01"。这是为了精度
        // （Date 差值 vs 累加 drift）和简洁性（不维护跨 Task 的 startedAt）做的取舍。
        // 若录音 session 实际是连续的，应在外层避免翻转 isRecording，而非在此处补偿。
        .task(id: isRecording) {
            guard isRecording else {
                recordingElapsed = 0
                return
            }
            let startedAt = Date()
            // 防御性归零：覆盖「view 初次出现时 isRecording 已为 true」场景
            // （task 首次启动时 UI 可能还显示上次遗留值）。guard false 分支已处理停止清零。
            recordingElapsed = 0
            // Task.sleep 抛 CancellationError 即「Task 被取消」，正常退出路径。
            // 只捕获取消错误——其它错误路径（系统休眠唤醒等）不应静默退出计时器。
            while true {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch is CancellationError { break }
                catch { continue }
                recordingElapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    // MARK: - Recording mode

    @ViewBuilder
    private var recordingModeContent: some View {
        // 状态文字：第一行 ● 正在聆听，第二行提示语。
        // 拆两层避免一行挤三个元素导致基线不齐 + 提示语折行带孤立"·"。
        // 提示语在转写出现后淡出——它的使命在用户开口前完成。
        VStack(spacing: WarmSpacing.xs) {
            HStack(spacing: LayoutMetrics.statusTextSpacing) {
                // P1: 红点脉动——用 PhaseAnimator（iOS 17+）替代 repeatForever，
                // 避免 repeatForever 在 value 切换时无法可靠停止的 SwiftUI 已知问题。
                // isRecording=false 时只渲染 .idle 单帧，不进入心跳循环。
                Circle()
                    .fill(WarmTheme.urgent)
                    .frame(width: LayoutMetrics.statusDotSize, height: LayoutMetrics.statusDotSize)
                    .phaseAnimator(
                        isRecording ? PulsePhase.pulsePhases : [.idle]
                    ) { content, phase in
                        content
                            .scaleEffect(phase.scale)
                            .opacity(phase.opacity)
                    } animation: { phase in
                        switch phase {
                        case .idle: return .default
                        default: return .easeInOut(duration: 0.8)
                        }
                    }
                Text(String(localized: "panel.listening"))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(WarmTheme.urgent)
            }
            if transcript.isEmpty {
                Text(String(localized: "panel.listening_hint"))
                    .font(.footnote)
                    .foregroundColor(WarmTheme.textMuted)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, WarmSpacing.xl)
        .animation(.easeOut(duration: 0.2), value: transcript.isEmpty)

        // 实时转写——SFSpeechRecognizer partial results，让用户确认"它有没有听对"。
        // 空时不显示（波形填补空白）；有内容时成为面板主视觉，波形降为配角。
        if !transcript.isEmpty {
            Text(transcript)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.bottom, WarmSpacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.easeOut(duration: 0.2), value: transcript)
        }

        // 波形 + 计时器：波形接真实音量驱动，计时器缩成配角（小灰字挪到波形右边）
        HStack(spacing: WarmSpacing.sm) {
            WaveformView(color: WarmTheme.urgent, isActive: isRecording, audioLevel: audioLevel)
            Text(formatDuration(recordingElapsed))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundColor(WarmTheme.textMuted)
                .accessibilityLabel(
                    String(format: String(localized: "a11y.recording_duration"), Int(recordingElapsed))
                )
        }
        .padding(.bottom, WarmSpacing.sm)

        // 操作行
        actionsRow

        // 手动切换到键盘输入（非 fallback 触发，不显示警告 banner）
        Button {
            print("🔍 [DIAG] bottom_panel.switch_to_keyboard_tapped")
            onModeChange(true)
        } label: {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: LayoutMetrics.retryIconFontSize))
                Text(String(localized: "panel.switch_to_keyboard"))
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(WarmTheme.textMuted)
            .padding(.horizontal, WarmSpacing.xs)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("InputSwitchToKeyboard")
        .accessibilityLabel(String(localized: "panel.switch_to_keyboard"))
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .font(.caption)
                    .foregroundColor(WarmTheme.warningText)
                    // iPhone SE 375pt 适配:zh-Hans banner 原文可达 4-5 行,配合
                    // fixedSize(vertical: true) 会撑高面板导致顶部被键盘遮挡。
                    // lineLimit(3) + truncationTail 保证 banner 高度有界。
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
        // P2: 扩 hit area 到 44pt（Apple HIG 最小可触控），padding 不变但 frame 强制最小高度。
        if isFallbackMode {
            Button {
                print("🔍 [DIAG] bottom_panel.retry_voice_tapped")
                onModeChange(false)
            } label: {
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: LayoutMetrics.retryIconFontSize))
                    Text(String(localized: "panel.retry_voice"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(WarmTheme.textMuted)
                .padding(.horizontal, WarmSpacing.xs)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputRetryVoice")
            .accessibilityLabel(String(localized: "panel.retry_voice"))
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // 手动切回语音输入（本次是用户主动切到键盘，提供切回入口）
            Button {
                print("🔍 [DIAG] bottom_panel.switch_to_voice_tapped")
                onModeChange(false)
            } label: {
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: LayoutMetrics.retryIconFontSize))
                    Text(String(localized: "panel.switch_to_voice"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(WarmTheme.textMuted)
                .padding(.horizontal, WarmSpacing.xs)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputSwitchToVoice")
            .accessibilityLabel(String(localized: "panel.switch_to_voice"))
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("InputPanelCloseButton")
            .accessibilityLabel(String(localized: "panel.close"))

            // 发送按钮：56pt 高大块按钮，flex:1 占满剩余宽度，飞机图标 + "发送给 AI"
            Button {
                print("🔍 [DIAG] bottom_panel.send_tapped isKeyboardMode=\(isKeyboardMode) canSend=\(canSend) trimmed=\(trimmedInputText.count)")
                if isKeyboardMode {
                    onSendText(trimmedInputText)
                } else {
                    onStopRecordingForProcessing()
                }
            } label: {
                HStack(spacing: WarmSpacing.xs) {
                    Image(systemName: "checkmark")
                        // 图标用语义字体对齐文字缩放，避免 Dynamic Type XXL 下文字放大图标不变的比例失衡。
                        .font(.callout.weight(.semibold))
                        .imageScale(.medium)
                    Text(String(localized: "panel.done"))
                        .font(.callout.weight(.bold))
                }
                // disabled 时前景色跟着降为半透明灰，避免白字在灰底上像"空胶囊"。
                .foregroundColor(canSend ? .white : WarmTheme.textMuted.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: LayoutMetrics.sendButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.sendCornerRadius)
                        .fill(canSend ? WarmTheme.primary : WarmTheme.textMuted.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityIdentifier("InputSendButton")
            .accessibilityLabel(isKeyboardMode ? String(localized: "manual_input.generate") : String(localized: "a11y.stop_recording"))
        }
    }
}

// MARK: - Red dot pulse phase

/// 红点脉动动画的相位。`.idle` 用于 isRecording=false 时只渲染一帧不循环；
/// `.expanded`/`.contracted` 在 PhaseAnimator 内 0.8s easeInOut 循环，模拟心跳呼吸。
/// 故意不声明 CaseIterable——动画相位用 `pulsePhases` 静态数组显式列出，
/// 避免未来误用 allCases 把 .idle 混入动画循环产生闪烁。
private enum PulsePhase {
    case idle
    case expanded
    case contracted

    /// 心跳循环相位（不含 idle）。预计算为静态常量，避免在 view body hot path 上 filter。
    static let pulsePhases: [PulsePhase] = [.expanded, .contracted]

    var scale: CGFloat {
        switch self {
        case .idle:       return 0.8
        case .expanded:   return 1.0
        case .contracted: return 0.8
        }
    }

    var opacity: Double {
        switch self {
        case .idle:       return 0.4
        case .expanded:   return 1.0
        case .contracted: return 0.4
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
        // 面板水平/底部 padding：来自设计稿像素值（22px），对齐 HTML 规格，
        // 故意不归 4 借数系统以匹配视觉。
        static let panelHorizontalPadding: CGFloat = 22
        static let panelInternalBottomPadding: CGFloat = 22
        // 录音状态文字
        static let statusDotSize: CGFloat = 8
        static let statusTextSpacing: CGFloat = 6
        // 键盘模式 banner（图标尺寸保留——SF Symbols 不走 Dynamic Type）
        static let bannerIconFontSize: CGFloat = 14
        // 键盘模式文本框
        static let inputFontSize: CGFloat = 15
        static let inputCornerRadius: CGFloat = 14
        // 操作行
        static let cancelButtonSize: CGFloat = 50
        static let cancelIconFontSize: CGFloat = 18
        static let sendButtonHeight: CGFloat = 56
        static let sendCornerRadius: CGFloat = 18
        // 重新尝试语音（图标尺寸保留）
        static let retryIconFontSize: CGFloat = 14
    }
}

#Preview {
    BottomInputPanelView(
        isKeyboardMode: .constant(false),
        inputText: .constant(""),
        isRecording: true,
        transcript: "明天下午三点开会",
        audioLevel: 0.5,
        isFallbackMode: false,
        onClose: {},
        onModeChange: { _ in },
        onSendText: { _ in },
        onStopRecordingForProcessing: {}
    )
    .padding()
    .background(WarmTheme.background)
}
