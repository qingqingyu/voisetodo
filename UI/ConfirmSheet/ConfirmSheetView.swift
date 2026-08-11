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

/// 底部操作提示 footer 的布局/时序常量集中管理。
/// - estimatedHeight: footer 可见时 clampedSheetHeight 的额外估算高度,
///   约为 caption2 行高 + WarmSpacing.xxs(4pt)bottom padding。
/// - safeAreaInset 自带的 home indicator 区域不计入 detent。
/// - visibleDurationNanos: footer 显示时长,sheet 升起后多久自动淡出。
private enum OperationHintFooter {
    static let estimatedHeight: CGFloat = 16
    static let visibleDurationNanos: UInt64 = 800_000_000
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
    /// 撞车警告:todo.id → 冲突的日历事件列表。空字典表示无冲突或不启用撞车检测。
    /// 第一版本只在 ConfirmSheet 顶部显示汇总 banner,不细化到卡片层。
    let conflictWarnings: [UUID: [ExternalCalendarEvent]]
    let onConfirm: ([ExtractedTodo]) -> Bool
    let onCancel: () -> Void

    /// 显式 init:让 conflictWarnings 有默认值 `[:]` 的同时仍出现在参数列表里
    /// (let + 默认值会让 memberwise init 跳过该参数,导致调用方传不进来)。
    init(
        transcript: String,
        todos: Binding<[ExtractedTodo]>,
        isStreaming: Bool,
        conflictWarnings: [UUID: [ExternalCalendarEvent]] = [:],
        onConfirm: @escaping ([ExtractedTodo]) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.transcript = transcript
        self._todos = todos
        self.isStreaming = isStreaming
        self.conflictWarnings = conflictWarnings
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    @Environment(\.dismiss) private var dismiss

    @State private var didFinish = false
    @State private var transcriptExpanded = false
    /// ScrollView 内 VStack 的实际内容高度,由 SheetContentHeightKey 回传,
    /// 驱动 .presentationDetents([.height(clampedSheetHeight), .large])。
    @State private var contentHeight: CGFloat = 0
    /// 底部操作提示 footer 是否可见——sheet 升起后 0.8s 自动淡出消失。
    /// 操作提示闪现一下即可,无需常驻占用底部视觉空间。
    @State private var hintVisible = true
    /// 当前就地展开编辑面板的 todo id,nil = 无展开。流式期间禁用展开
    /// (TodoItemRow.onTapGesture guard isStreaming),此状态透传到 row。
    @State private var expandedTodoID: UUID?
    /// 流式期间点击卡片的底部 toast 是否可见。
    /// 点卡片 → TodoItemRow.onStreamingTap → 这里置 true → ToastModifier 2s 后自动 false。
    /// 用底部 toast 替代原卡片 overlay:不遮卡片内容,且与列表末尾的 StreamingFooter
    /// (常驻状态指示)职责分开 —— toast 是「响应用户操作的临时反馈」,Footer 是常驻状态。
    @State private var streamingToastVisible: Bool = false
    /// streaming toast 的重展示令牌:每次 handleStreamingTap 递增。
    /// 绕开"isPresented 已 true → true→true 不触发 onChange"的去重,
    /// 让连点不同卡片都能重置 dismiss 计时,后续触发的 toast 享完整 duration。
    @State private var streamingToastToken: Int = 0
    /// 是否展开反馈 sheet。撞到烂 AI 输出当下,用户在 ConfirmSheet 就能反馈,
    /// 比事后到 Settings 找反馈入口转化率高得多(plan.md D7 推荐 B)。
    @State private var showFeedbackSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            mainContent
        }
        // 流式点击反馈:底部 toast(safe area 上方居中,不遮卡片)。
        // 文案带状态 + 下一步("正在解析,完成后可编辑"),不是单说"不能编辑"。
        // 挂 sheet 根层而非 mainContent,让 toast 浮在整个 sheet 之上(包括 header 区下方)。
        // presentationToken 让连点不同卡片都能重置 2s dismiss 计时(见 handleStreamingTap)。
        .toast(
            message: String(localized: "confirm.streaming_cannot_edit"),
            style: .info,
            isPresented: $streamingToastVisible,
            position: .bottom,
            presentationToken: streamingToastToken
        )
        // 动态高度:随内容增长(每识别一条 todo 往上涨),上限 85% 屏高,
        // 超上限走 ScrollView 滚动;保留 .large 让用户可手动拖到全屏。
        // spring 平滑流式期间高度变化,避免硬切跳动。
        .presentationDetents([.height(clampedSheetHeight), .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showFeedbackSheet) {
            // ConfirmSheet 入口预填 type=aiOutput + 附 transcript/title 上下文,
            // 让反馈直接关联到具体待办,无需用户额外描述。
            FeedbackSheet(
                prefillType: .aiOutput,
                transcript: transcript,
                extractedTodoTitle: todos.first?.title
            )
        }
        .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: contentHeight)
        // hintVisible 变化时同步驱动 sheet detent 高度变化,与 footer .easeOut(0.4) 淡出
        // 共享同一触发源——避免 detent 瞬时跳变、footer 还在淡出过程中造成的视觉撕裂。
        .animation(.easeOut(duration: 0.4), value: hintVisible)
        .accessibilityIdentifier("ConfirmSheet")
        .task {
            // 升起 0.8s 后淡出底部操作提示 footer。看一眼即懂的操作无需常驻。
            // Task.sleep 只 throw CancellationError(sheet 关闭时 Task 被取消),
            // 显式 catch 符合「错误显式传播」,不掩盖其他错误(sleep 不可能 throw 其他)。
            do {
                try await Task.sleep(nanoseconds: OperationHintFooter.visibleDurationNanos)
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
    }

    // MARK: - Main Content

    private var sheetHeader: some View {
        HStack(spacing: WarmSpacing.xs) {
            Button(action: cancelAction) {
                Text(String(localized: "confirm.cancel"))
                    .font(WarmFont.headline(15))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: WarmSize.touch, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("CancelButton")

            // 反馈按钮(中间,minWidth):撞到烂 AI 输出当下入口。
            // 对话气泡图标方向敏感,RTL 下需镜像。
            Button {
                showFeedbackSheet = true
            } label: {
                Image(systemName: "exclamationmark.bubble")
                    .font(WarmFont.headline(15))
                    .foregroundStyle(WarmTheme.textSecondary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .frame(minWidth: WarmSize.touch, minHeight: WarmSize.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ConfirmSheetFeedbackButton")

            Button(action: confirmAction) {
                Text(String(localized: "confirm.add_count \(todos.count)"))
                    .font(WarmFont.headline(15))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, WarmSpacing.md)
                    .padding(.vertical, WarmSpacing.xs)
                    .background(
                        Capsule().fill(confirmButtonBackground)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
            .frame(maxWidth: .infinity, minHeight: WarmSize.touch, alignment: .trailing)
            .accessibilityIdentifier("ConfirmAddButton")
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.top, WarmSpacing.sm)
        .accessibilityIdentifier("ConfirmSheetHeader")
    }

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                    transcriptSection
                        .padding(.bottom, WarmSpacing.xs)

                    if !conflictWarnings.isEmpty {
                        conflictWarningsBanner
                            .padding(.bottom, WarmSpacing.sm)
                    }

                    if !todos.isEmpty {
                        ConfirmGroupedList(todos: $todos, expandedTodoID: $expandedTodoID, isStreaming: isStreaming, onStreamingTap: handleStreamingTap)
                            .transition(.opacity)
                    } else if isStreaming {
                        StreamingFooter()
                            .padding(.top, WarmSpacing.md)
                            .transition(.opacity)
                    } else {
                        inlineEmptyState
                            .transition(.opacity)
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
            .onChange(of: expandedTodoID) { _, newValue in
                // 展开卡片时滚到该卡顶部,避免面板撑高后卡片被推出可视区。
                guard let id = newValue else { return }
                withAnimation(WarmAnimation.springStandard) {
                    proxy.scrollTo(id, anchor: .top)
                }
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

    // MARK: - Conflict Warnings Banner

    /// 撞车警告 banner:汇总提示「N 条待办与日历事件时间冲突」。
    /// 第一版本只做汇总提示,不展开每条冲突详情(后续可点击展开)。
    /// 用 WarmTheme.warning 系列色,跟现有主题风格协调(浅色暖米橙 / 深色深棕)。
    @ViewBuilder
    private var conflictWarningsBanner: some View {
        let count = conflictWarnings.count
        HStack(alignment: .top, spacing: WarmSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(WarmTheme.warningText)
                .font(.system(size: 13))
            Text(String(localized: "confirm.conflict.banner \(count)"))
                .font(WarmFont.caption(13))
                .foregroundStyle(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WarmSpacing.sm)
        .background(WarmTheme.warningSurface)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.chip))
        .accessibilityIdentifier("ConflictWarningsBanner")
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
    /// padding 收紧:只留极小底部间距,safeAreaInset 自身会补 home indicator 区域,
    /// 不再上下撑高度——闪现一下即可,不抢垂直空间。
    private var operationHintFooter: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "hand.tap")
                .font(.system(size: 11))
            Text(String(localized: "confirm.hint"))
                .font(WarmFont.caption(12))
        }
        .foregroundColor(WarmTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.bottom, WarmSpacing.xxs)
        .background(WarmTheme.background)
        .accessibilityIdentifier("OperationHintLabel")
    }

    private var canConfirm: Bool {
        !todos.isEmpty && !didFinish
    }

    private var confirmButtonBackground: Color {
        canConfirm ? WarmTheme.primary : WarmTheme.textMuted.opacity(0.5)
    }

    /// 动态 detent 的实际高度:内容高 + sheet 框架区域(导航栏 + footer + padding),
    /// clamp 到 [下限 280pt, 85% 屏高]。框架估算:导航栏 inline ~44 + sheetHeader
    /// top padding 12 + VStack padding ~24 + 余量 ~22 = 102;footer 可见时再加
    /// estimatedHeight(hintVisible 控制,见 OperationHintFooter.estimatedHeight)。
    /// **footer 淡出时框架同步减该高度,sheet 高度跟着矮**,避免底部留空白——
    /// 消失就消失,不影响底下 todo 内容区的布局。
    /// 超上限后 ScrollView 自动接管滚动;.large 仍可手动拖到全屏。
    private var clampedSheetHeight: CGFloat {
        let screenHeight = Self.currentScreenHeight()
        let footer: CGFloat = hintVisible ? OperationHintFooter.estimatedHeight : 0
        let frame: CGFloat = 102 + footer
        let raw = contentHeight + frame
        let lowerBound: CGFloat = 280
        let upperBound = screenHeight * 0.85
        return min(max(raw, lowerBound), upperBound)
    }

    /// iOS 26 起 `UIScreen.main` 被弃用,需通过 context 中的 scene 取屏。
    /// sheet 是独立 window,GeometryReader 拿到的是 sheet 自己的尺寸,
    /// 只能从 `UIApplication.shared.connectedScenes` 拿 foregroundActive 的 windowScene。
    /// 找不到 active scene 属于异常状态(app 启动早期 / scene 被系统回收),
    /// 此时记 error 日志显式暴露,而不是静默 fallback 掩盖问题。
    private static func currentScreenHeight() -> CGFloat {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let height = activeScene?.screen.bounds.height, height > 0 else {
            VoiceTodoLog.ui.error("confirmsheet.screen_height.unavailable scene_not_found, falling back to default")
            return UIConfig.UIScreenFallback.defaultHeight
        }
        return height
    }

    // MARK: - Actions

    /// 流式期间点击卡片:显示底部 toast + 递增 token 强制重置 dismiss 计时。
    /// 不在此处包 withAnimation —— ToastModifier.body 已挂
    /// `.animation(WarmAnimation.springSlow, value: isPresented)`,再包一层会让两个 spring
    /// 叠加插入/移除 transition,产生抖动。
    /// token 递增解决"isPresented 已 true → true→true 被 SwiftUI 同帧合并 → onChange 不发"
    /// 的去重问题:ToastModifier 监听 token,每次递增都重新 scheduleDismiss。
    private func handleStreamingTap() {
        streamingToastToken += 1
        streamingToastVisible = true
    }

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
        // 不再切到成功页:删除 successOverlay + 1.5s 延时 dismiss。成功反馈改为
        // 「sheet 立即收起 → 列表 stagger 弹入 → Today 计数 pop → 触觉」,见 HomeView。
        // 触觉在 dismiss 之前触发:用户点 Add 的瞬间就能感到震动反馈。
        // store.addBatch 已在 onConfirm 内同步完成,dismiss 启动时 HomeView 已有新数据,
        // 待揭晓队列(coordinator.pendingRevealTodoIDs)也已被 confirmTodos 写好。
        HapticFeedback.success()
        dismiss()
    }

    private func cancelAction() {
        guard !didFinish else { return }
        didFinish = true
        onCancel()
        dismiss()
    }
}
