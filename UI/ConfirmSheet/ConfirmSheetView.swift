import SwiftUI

/// 测量 ConfirmSheet ScrollView 内 VStack 的实际内容高度,
/// 用于驱动 .presentationDetents([.height(h), .large]) 动态长高。
private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// ConfirmSheet 自动滚动锚点 id 集中管理:消除字面量重复,
/// 防止后续嵌入同名 id 子组件时 scrollTo 定位到错误目标。
private enum ConfirmSheetScrollAnchor: String {
    case sheetBottom
}

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
    /// ScrollView 内 VStack 的实际内容高度,由 SheetContentHeightKey 回传,
    /// 驱动 .presentationDetents([.height(clampedSheetHeight), .large])。
    @State private var contentHeight: CGFloat = 0
    /// 底部操作提示 footer 是否可见——sheet 升起后 1.5s 自动淡出消失。
    /// 操作提示看一眼即懂,无需常驻占用底部视觉空间。
    @State private var hintVisible = true
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
                    .font(WarmFont.headline(15))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .accessibilityIdentifier("CancelButton")
                }
                ToolbarItem(placement: .principal) {
                    calendarTarget
                }
                // Confirm:珊瑚橙胶囊填充主操作,对齐 HTML .btn-primary。
                // 数字只走本地化文案 confirm.add_count,不再叠 PopCount 徽章——
                // 避免「胶囊套胶囊」+ 同一 count 显示两遍。
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        Text(String(localized: "confirm.add_count \(todos.count)"))
                            .font(WarmFont.headline(15))
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
        // 动态高度:随内容增长(每识别一条 todo 往上涨),上限 85% 屏高,
        // 超上限走 ScrollView 滚动;保留 .large 让用户可手动拖到全屏。
        // spring 平滑流式期间高度变化,避免硬切跳动。
        .presentationDetents([.height(clampedSheetHeight), .large])
        .presentationDragIndicator(.visible)
        .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: contentHeight)
        // hintVisible 变化时同步驱动 sheet detent 高度变化,与 footer .easeOut(0.4) 淡出
        // 共享同一触发源——避免 detent 瞬时跳变、footer 还在淡出过程中造成的视觉撕裂。
        .animation(.easeOut(duration: 0.4), value: hintVisible)
        .accessibilityIdentifier("ConfirmSheet")
        .task {
            // 升起 1.5s 后淡出底部操作提示 footer。看一眼即懂的操作无需常驻。
            // Task.sleep 只 throw CancellationError(sheet 关闭时 Task 被取消),
            // 显式 catch 符合「错误显式传播」,不掩盖其他错误(sleep 不可能 throw 其他)。
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.4)) {
                hintVisible = false
            }
        }
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
        ScrollViewReader { proxy in
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

                    // 自动滚动锚点:流式新增 todo 时 scrollTo 这里,让最新条目可见。
                    Color.clear
                        .frame(height: 1)
                        .id(ConfirmSheetScrollAnchor.sheetBottom.rawValue)
                }
                .padding(.horizontal, WarmSpacing.md)
                .padding(.top, WarmSpacing.sm)
                .padding(.bottom, WarmSpacing.md)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SheetContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .onChange(of: todos.count) { _, _ in
                // 流式新增条目时滚到底部,让最新解析的 todo 可见。
                // 用 springSlow 跟随 ConfirmGroupedList 的列表插入动画,视觉同步。
                // 内容未超可视区时 scrollTo 是 no-op(没地方滚),所以前几条 sheet 长高时不会乱跳。
                withAnimation(WarmAnimation.springSlow) {
                    proxy.scrollTo(ConfirmSheetScrollAnchor.sheetBottom.rawValue, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hintVisible {
                    operationHintFooter
                        .transition(.opacity)
                }
            }
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

    /// 转录文字本体。展开 = 完整显示(fixedSize);收起 = lineLimit(2) 截断。
    /// 展开/收起按钮始终显示,确保任何 transcript 都有展开入口。
    /// 不用 ViewThatFits——它在 ScrollView 里失效(子视图垂直空间无限,完整分支永远 fits,
    /// 长原文会占满半屏)。lineLimit(2) 是上限,短文本自然高度仍 1-2 行,不会被强拉。
    @ViewBuilder
    private var transcriptText: some View {
        if transcriptExpanded {
            Text(transcript)
                .font(WarmFont.caption(14))
                .foregroundStyle(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("TranscriptArea")
        } else {
            Text(transcript)
                .font(WarmFont.caption(14))
                .foregroundStyle(WarmTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("TranscriptArea")
        }
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(WarmTheme.textSecondary)
        .accessibilityIdentifier("CalendarTargetLabel")
    }

    private var confirmButtonBackground: Color {
        let disabled = todos.isEmpty || isStreaming || didFinish
        return disabled ? WarmTheme.textMuted.opacity(0.5) : WarmTheme.primary
    }

    /// 动态 detent 的实际高度:内容高 + sheet 框架区域(导航栏 + footer + padding),
    /// clamp 到 [下限 280pt, 85% 屏高]。框架估算:导航栏 inline ~44 + VStack padding
    /// ~24 + 余量 ~22 = 90;footer 可见时再加 ~30(hintVisible 控制)。
    /// **footer 淡出时框架同步减 30pt,sheet 高度跟着矮**,避免底部留空白——
    /// 消失就消失,不影响底下 todo 内容区的布局。
    /// 超上限后 ScrollView 自动接管滚动;.large 仍可手动拖到全屏。
    private var clampedSheetHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        let footer: CGFloat = hintVisible ? 30 : 0
        let frame: CGFloat = 90 + footer
        let raw = contentHeight + frame
        let lowerBound: CGFloat = 280
        let upperBound = screenHeight * 0.85
        return min(max(raw, lowerBound), upperBound)
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
