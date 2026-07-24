import SwiftUI

/// 确认弹窗视图 - 温暖友好风格
/// 语音录入后的确认面板,显示 AI 提取的待办列表。
///
/// 重设计(2026-07):对齐 jul-redesign.html 参考。
/// - Confirm 改珊瑚橙胶囊填充主操作,Cancel 降纯文字
/// - 转录默认 2 行 + 展开按钮(不再挤压卡片)
/// - 卡片按"今天/明天/周三"分组,左侧分类色条,时间胶囊底色
/// - emoji 入场缩放、数字 pop、卡片 spring + haptic
struct ConfirmSheetView: View {
    let transcript: String
    @Binding var todos: [ExtractedTodo]
    let isStreaming: Bool
    let onConfirm: ([ExtractedTodo]) -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showSuccess = false
    @State private var didFinish = false
    @State private var transcriptExpanded = false
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showSuccess {
                    successOverlay
                } else {
                    mainContent
                }
            }
            .navigationTitle(String(localized: "confirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Cancel:纯文字次要操作,对齐 HTML .btn-ghost
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "confirm.cancel")) {
                        cancelAction()
                    }
                    .font(WarmFont.body(15))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .accessibilityIdentifier("CancelButton")
                }
                ToolbarItem(placement: .principal) {
                    calendarTarget
                }
                // Confirm:珊瑚橙胶囊填充主操作,对齐 HTML .btn-primary
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        HStack(spacing: WarmSpacing.xs) {
                            Text(String(localized: "confirm.add_count \(todos.count)"))
                                .font(WarmFont.headline(15))
                            PopCount(count: todos.count)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, WarmSpacing.md)
                        .padding(.vertical, WarmSpacing.xs)
                        .background(
                            Capsule().fill(confirmButtonBackground)
                        )
                    }
                    .disabled(todos.isEmpty || isStreaming || didFinish)
                    .accessibilityIdentifier("ConfirmAddButton")
                }
            }
        }
        // 弹层升起期间可能 todo=0(流式中),始终保留 .medium + .large 不再随 count 切,
        // 避免 iOS detent 硬切造成弹层跳动。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConfirmSheet")
        .onDisappear {
            guard !didFinish else { return }
            didFinish = true
            onCancel()
        }
        .task(id: showSuccess) {
            guard showSuccess else { return }
            // .task 闭包签名是 non-throwing,用 do/catch 显式吞 CancellationError
            // (Task.sleep 只 throw CancellationError),符合「错误显式传播」:
            // 被取消是预期无操作路径,且此处不可能有其他错误。
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch is CancellationError {
                return
            } catch {
                // 不可达:Task.sleep 只 throw CancellationError。但 do/catch 语义上
                // 要求 catch 穷尽,否则闭包整体 throws,与 .task 签名冲突。
                return
            }
            dismiss()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                transcriptSection
                    .padding(.bottom, WarmSpacing.xs)

                if !todos.isEmpty {
                    ConfirmGroupedList(todos: $todos, isStreaming: isStreaming)
                } else if isStreaming {
                    StreamingFooter()
                        .padding(.top, WarmSpacing.md)
                } else {
                    inlineEmptyState
                }
            }
            .padding(.horizontal, WarmSpacing.md)
            .padding(.top, WarmSpacing.sm)
            .padding(.bottom, WarmSpacing.md)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            operationHintFooter
        }
    }

    // MARK: - Transcript Section

    /// 转录原文:默认 2 行 + 展开/收起,对齐 HTML .transcript。
    /// 截断策略破例:用户可点「展开」一键看全,与 feedback memory「文本截断零容忍」精神
    /// (主内容不允许 ...)不冲突——转录是辅助校对内容,主读是 todo 卡片。
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            Text(String(localized: "confirm.transcript"))
                .font(WarmFont.captionFixed(11))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(WarmTheme.textMuted)

            HStack(alignment: .top, spacing: WarmSpacing.xs) {
                transcriptText
                if transcriptNeedsExpandHint {
                    Button(transcriptExpanded
                        ? String(localized: "confirm.transcript.collapse")
                        : String(localized: "confirm.transcript.expand")) {
                        withAnimation(WarmAnimation.springFast) {
                            transcriptExpanded.toggle()
                        }
                    }
                    .font(WarmFont.caption(13))
                    .foregroundStyle(WarmTheme.primary)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TranscriptExpandToggle")
                }
            }
        }
    }

    /// 转录文字本体。展开时全显示;收起时用 ViewThatFits 先试完整(不截断),
    /// 放不下再退到 2 行 + ...。配合 transcriptNeedsExpandHint 的保守阈值,
    /// 确保 AX5 + 长中文下也能看到展开按钮,不会出现「被截断但无展开按钮」的违规态。
    ///
    /// accessibilityIdentifier 挂在外层 Group 上:ViewThatFits 会把候选 view 都加进
    /// accessibility tree,若每个分支都挂同 id 会让 VoiceOver / UI 测试选择器不稳定。
    @ViewBuilder
    private var transcriptText: some View {
        if transcriptExpanded {
            Text(transcript)
                .font(WarmFont.caption(14))
                .foregroundStyle(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("TranscriptArea")
        } else {
            ViewThatFits(in: .vertical) {
                Text(transcript)
                    .font(WarmFont.caption(14))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(transcript)
                    .font(WarmFont.caption(14))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("TranscriptArea")
        }
    }

    /// 启发:transcript 含换行或长度 > 30 时显示「展开」按钮。
    /// 阈值降到 30:AX5 + 中文下 30 个全角字符已接近 2 行满,
    /// 阈值过高会导致「2 行已截断但无展开按钮」的违规态。
    /// ViewThatFits 兜底保证「放得下就不截断」,这里只决定「是否给展开入口」。
    private var transcriptNeedsExpandHint: Bool {
        transcript.count > 30 || transcript.contains("\n")
    }

    // MARK: - Inline Empty State

    /// 流式结束 + 空结果:弹层内 inline 提示 + 「重新输入」按钮,
    /// 取代原来的 ProductEmptyStateView 大块插画(对齐 HTML 紧凑风格)。
    private var inlineEmptyState: some View {
        VStack(spacing: WarmSpacing.sm) {
            Text(String(localized: "empty.confirm.title"))
                .font(WarmFont.headline(15))
                .foregroundStyle(WarmTheme.textSecondary)

            Button {
                cancelAction()
            } label: {
                Label(String(localized: "confirm.retry"), systemImage: "arrow.counterclockwise")
                    .font(WarmFont.body(14))
                    .foregroundStyle(WarmTheme.primary)
                    .padding(.horizontal, WarmSpacing.md)
                    .padding(.vertical, WarmSpacing.xs)
                    .background(
                        Capsule().stroke(WarmTheme.primary.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ConfirmEmptyRetryButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarmSpacing.xl)
        .accessibilityIdentifier("ConfirmEmptyState")
    }

    // MARK: - Operation Hint Footer

    /// 移到底部 safeAreaInset,对齐 HTML .sheet-foot 居中灰小字。
    private var operationHintFooter: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "hand.tap")
                .font(.system(size: 11))
            Text(String(localized: "confirm.hint"))
                .font(WarmFont.caption(12))
        }
        .foregroundColor(WarmTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarmSpacing.xs)
        .padding(.bottom, WarmSpacing.xxs)
        .background(WarmTheme.background)
        .accessibilityIdentifier("OperationHintLabel")
    }

    private var calendarTarget: some View {
        let mode = CalendarWriteMode(rawValue: calendarWriteModeRaw) ?? .appOnly
        return HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: mode == .appAndSystemCalendar ? "calendar.badge.plus" : "calendar")
                .font(.system(size: 11))
            Text(mode == .appAndSystemCalendar
                 ? String(localized: "confirm.calendar_target.app_and_system")
                 : String(localized: "confirm.calendar_target.app_only"))
                .font(WarmFont.caption(12))
        }
        .foregroundColor(WarmTheme.textSecondary)
        .accessibilityIdentifier("CalendarTargetLabel")
    }

    private var confirmButtonBackground: Color {
        let disabled = todos.isEmpty || isStreaming || didFinish
        return disabled ? WarmTheme.textMuted.opacity(0.5) : WarmTheme.primary
    }

    // MARK: - Success Overlay

    private var successOverlay: some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            ZStack {
                Circle()
                    .fill(WarmTheme.success)
                    .frame(width: WarmSize.hero, height: WarmSize.hero)

                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccess ? 1.0 : 0.5)
            .animation(WarmAnimation.springBouncy, value: showSuccess)

            Text(ErrorMessages.addedSuccess)
                .font(WarmFont.headline(18))
                .foregroundColor(WarmTheme.textPrimary)
                .opacity(showSuccess ? 1.0 : 0.0)
                .animation(.easeIn(duration: 0.2).delay(0.2), value: showSuccess)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WarmTheme.background)
        .accessibilityIdentifier("SuccessAnimation")
    }

    // MARK: - Actions

    private func confirmAction() {
        guard !didFinish else { return }
        guard !todos.isEmpty else { return }

        didFinish = true
        let success = onConfirm(todos)

        guard success else {
            didFinish = false
            return
        }

        Telemetry.record(.todoSaved(source: .confirm, count: todos.count))
        withAnimation(WarmAnimation.springBouncy) {
            showSuccess = true
        }
    }

    private func cancelAction() {
        guard !didFinish else { return }
        didFinish = true
        onCancel()
        dismiss()
    }
}
