import SwiftUI

/// 确认弹窗视图 - 温暖友好风格
/// 语音录入后的确认面板， 显示 AI 提取的待办列表
struct ConfirmSheetView: View {
    let transcript: String
    @Binding var todos: [ExtractedTodo]
    let isStreaming: Bool
    let onConfirm: ([ExtractedTodo]) -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showSuccess = false
    @State private var didFinish = false
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 成功动画覆盖层
                if showSuccess {
                    successOverlay
                } else {
                    mainContent
                }
            }
            // 标题改为更显标题感的"确认待办事项"——避免与"取消/确认添加"按钮视觉混淆。
            .navigationTitle(String(localized: "confirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "confirm.cancel")) {
                        cancelAction()
                    }
                    .accessibilityIdentifier("CancelButton")
                }
                // 日历写入目标移到顶部 toolbar 中央——用户确认前最该看到的元信息。
                // 用 secondary 色让它不抢按钮焦点，但比原来居中胶囊更不挡待办条目。
                ToolbarItem(placement: .principal) {
                    calendarTarget
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        Text(String(localized: "confirm.add \(todos.count)"))
                            .bold()
                    }
                    // didFinish 也 disabled:防止用户快速双击或 SwiftUI Button 在 iOS 26/27
                    // 触发 action 两次(已知回归)导致同一批 todos 被 confirmTodos 保存两次,
                    // 产生 id 相同的重复 TodoItem(SwiftData @Attribute(.unique) 在 insert 时不查重)。
                    .disabled(todos.isEmpty || isStreaming || didFinish)
                    .accessibilityIdentifier("ConfirmAddButton")
                }
            }
        }
        // 单条目时只给 .medium（半高），避免下半截空感；2+ 条目解锁 .large。
        // 流式期间 (isStreaming=true) 即使只有 0-1 条也走 .medium+.large，等数据到位再收敛。
        // 注意：用户从 2+ 条删除到 1 条时，detents 会从 [.medium,.large] 收到 [.medium]——
        // 这是有意的 UX（单条目就该紧凑），iOS 会动画过渡。
        .presentationDetents(todos.count <= 1 && !isStreaming ? [.medium] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConfirmSheet")
        .onDisappear {
            guard !didFinish else { return }
            didFinish = true
            onCancel()
        }
        .task(id: showSuccess) {
            guard showSuccess else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.sm) {
                transcriptSection

                if !todos.isEmpty {
                    todosSection

                    // 操作提示：从前几次的显眼胶囊改成 todosSection 下方的一行浅灰小字。
                    // 用户主要看条目，提示降级为辅助信息。
                    operationHint
                        .padding(.top, WarmSpacing.xs)
                } else if isStreaming {
                    todosSection
                } else {
                    noResultEmptyState
                }
            }
            .padding()
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            Text(String(localized: "confirm.transcript"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)

            Text(transcript)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textSecondary)
                .padding(WarmSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.chip)
                        .fill(WarmTheme.secondaryBackground)
                )
                .accessibilityIdentifier("TranscriptArea")
        }
    }

    // MARK: - Todos Section

    private var todosSection: some View {
        VStack(spacing: WarmSpacing.sm) {
            ForEach(Array($todos.enumerated()), id: \.element.id) { index, $todo in
                TodoItemRowWithDelete(
                    index: index,
                    todo: $todo,
                    todos: $todos
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isStreaming {
                HStack(spacing: WarmSpacing.xs) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                        .scaleEffect(0.8)
                    Text(String(localized: "confirm.streaming"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                }
                .padding(.vertical, WarmSpacing.xs)
                .transition(.opacity)
            }
        }
        .animation(WarmAnimation.springSlow, value: todos.count)
        .accessibilityIdentifier("ExtractedTodoList")
    }

    private var noResultEmptyState: some View {
        ProductEmptyStateView(
            icon: "sparkles",
            title: String(localized: "empty.confirm.title"),
            message: String(localized: "empty.confirm.message"),
            primaryAction: ProductEmptyStateAction(
                title: String(localized: "empty.confirm.primary"),
                systemImage: "arrow.counterclockwise",
                action: cancelAction
            )
        )
        .accessibilityIdentifier("ConfirmEmptyState")
    }

    // MARK: - Operation Hint

    /// todosSection 下方的轻量操作提示——一行浅灰小字，不带胶囊背景。
    /// P2 修复：从原来的居中胶囊降级，避免压过待办条目本身的视觉权重。
    private var operationHint: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "hand.tap")
                .font(.system(size: 11))
            Text(String(localized: "confirm.hint"))
                .font(WarmFont.caption(12))
        }
        .foregroundColor(WarmTheme.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("OperationHintLabel")
    }

    /// 移到 toolbar principal 的日历写入目标——更紧凑的标签样式。
    /// P2 修复：原来居中胶囊占了核心视觉位置，移到顶部 nav bar 让出待办条目空间。
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

    // MARK: - Success Overlay

    private var successOverlay: some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            // 成功图标
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

            // 成功文字
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
        // 防重入:cancelAction 已有同样 guard,confirmAction 缺失导致同一批 todos 可能被保存两次。
        // 触发场景:用户快速双击 / SwiftUI Button 在 iOS 26/27 触发 action 两次。
        // 后果:两次 confirmTodos 调用传入同一批 ExtractedTodo(同 UUID),
        //      SwiftData @Attribute(.unique) 在 modelContext.insert 时不查重,save 也不报错,
        //      数据库里出现 2 条 id 相同的 TodoItem,导致 toggleComplete(id) 只命中第一条、
        //      ForEach id 冲突 UI 错位(用户看到「勾 A 影响 B」)。
        //
        // 双重防线:① 入口 guard + didFinish 立即置 true(set-before-call)
        //          ② 按钮 .disabled(didFinish)(UI 层拦截)
        // didFinish=true 放在 onConfirm 之前而非 success 分支:即使未来 onConfirm 改成 async,
        // guard 在 await 期间依然成立。失败时复位为 false,保留编辑上下文重试。
        guard !didFinish else { return }
        guard !todos.isEmpty else { return }

        didFinish = true
        let success = onConfirm(todos)

        guard success else {
            didFinish = false
            // 失败时不 dismiss：保留编辑上下文；Coordinator 已通过 Toast 等方式反馈错误。
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

// MARK: - Helper View

/// 辅助视图：处理待办删除逻辑
struct TodoItemRowWithDelete: View {
    let index: Int
    @Binding var todo: ExtractedTodo
    @Binding var todos: [ExtractedTodo]

    var body: some View {
        TodoItemRow(
            index: index,
            todo: $todo,
            onDelete: {
                withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                    todos.removeAll { $0.id == todo.id }
                }
            }
        )
    }
}
