import SwiftUI

/// 第 2 步 · 处理没做完的一次性任务(卡片堆,阶段 3)。
///
/// 输入(拍板 4):未完成 && abandonedAt == nil && recurrenceRule == nil——
/// 规律父任务永远 isCompleted == false 会刷屏,右滑「排下周」语义不明,排除。
/// 动作:右滑→排进下周(updateFull origin .review,不计推迟);左滑→划掉
/// (abandon,**不是 delete**);「今天就做」→ dueDate=今天;「拆小」→ sheet。
/// 手势用 `SimultaneousDragGesture`(iOS 26 FB18199844),阈值**位移或速度任一达标**。
/// 撤销只覆盖划掉(拍板 7)。
struct ReviewStepTriage: View {
    @Bindable var state: ReviewFlowState
    let store: any ReviewFlowStore
    let onError: (Error) -> Void
    let onUndoToast: (String) -> Void

    /// 滑动触发阈值:位移 85pt(HTML 原型)**或**速度 800pt/s 任一达标。
    /// 纯位移阈值在小屏上偏难,速度轻扫也该算。
    private static let distanceThreshold: CGFloat = 85
    private static let velocityThreshold: CGFloat = 800

    /// 拆小 sheet 的两条子任务输入(v1 手动,AI 版阶段 5)。
    @State private var splitTarget: TodoItemData?
    @State private var splitField1 = ""
    @State private var splitField2 = ""
    /// 拖拽跟手偏移(手势进行中)。
    @State private var dragOffset: CGFloat = 0

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            Text(String(localized: "review.flow.triage.title"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, WarmSpacing.lg)

            if !state.abandonedStack.isEmpty {
                undoButton
            }

            if state.deck.isEmpty {
                emptyDeck
            } else {
                Spacer(minLength: WarmSpacing.xs)
                deckView
                Spacer(minLength: WarmSpacing.xs)
            }
        }
        .sheet(item: $splitTarget) { todo in
            splitSheet(todo)
        }
        .onAppear { applyFocusReorder() }
        .onChange(of: state.triageFocusID) { _, _ in applyFocusReorder() }
    }

    // MARK: 撤销

    /// 「撤销上一张」:unabandon 最近一次划掉(拍板 7:只覆盖划掉)。
    private var undoButton: some View {
        Button {
            guard let todo = state.popAbandonForUndo() else { return }
            do {
                try store.unabandon(todo.id)
                HapticFeedback.light()
                onUndoToast(String(localized: "review.flow.triage.undo_done"))
            } catch {
                // 写库失败:状态回滚(重新入栈、移出卡堆前端之外的位置保持一致),
                // 错误如实上报,不静默。
                state.markAbandoned(todo)
                onError(error)
            }
        } label: {
            Label(
                String(localized: "review.flow.triage.undo"),
                systemImage: "arrow.uturn.backward"
            )
            .flipsForRightToLeftLayoutDirection(true)
            .font(WarmFont.caption(13))
            .foregroundColor(WarmTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ReviewFlowTriageUndo")
    }

    @ViewBuilder
    private var emptyDeck: some View {
        Spacer()
        EmptyStateView(
            icon: "checkmark.seal",
            message: String(localized: "review.flow.triage.empty"),
            iconSize: 40,
            opacity: 0.6
        )
        Spacer()
    }

    // MARK: 卡片堆

    /// 深链聚焦:洞察腐烂卡跳回时,把对应卡片换到卡堆最前(若仍在卡堆)。
    private func applyFocusReorder() {
        guard let focus = state.triageFocusID else { return }
        state.triageFocusID = nil
        state.bringToFrontOfDeck(focus)
    }

    private var deckView: some View {
        ZStack {
            // 底层卡(第二张):只露一点边,给「还有下一张」的厚度感。
            if state.deck.count > 1 {
                triageCard(state.deck[1])
                    .padding(.horizontal, WarmSpacing.xl)
                    .offset(y: WarmSpacing.md)
                    .opacity(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let top = state.deck.first {
                triageCard(top)
                    .offset(x: dragOffset)
                    .gesture(
                        SimultaneousDragGesture(
                            minimumDistance: 24,
                            direction: .horizontal,
                            onChanged: { drag in
                                HapticFeedback.selection()
                                dragOffset = drag.translation.width
                            },
                            onEnded: { drag in
                                handleSwipe(drag, on: top)
                            },
                            onCancelled: {
                                withAnimation(WarmAnimation.springStandard) { dragOffset = 0 }
                            }
                        )
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .scale(scale: 1.05).combined(with: .opacity)
                    ))
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 阈值判定:位移或速度任一达标即触发(§阶段 3)。
    private func handleSwipe(_ drag: DragTranslation, on todo: TodoItemData) {
        let dx = drag.translation.width
        let speed = abs(drag.velocity.dx)
        let distanceHit = abs(dx) >= Self.distanceThreshold
        let velocityHit = speed >= Self.velocityThreshold

        withAnimation(WarmAnimation.springBouncy) { dragOffset = 0 }

        guard distanceHit || velocityHit else { return }
        // 位移方向优先;纯速度触发时用速度方向。
        let rightward = distanceHit ? dx > 0 : drag.velocity.dx > 0
        HapticFeedback.medium()
        if rightward {
            scheduleToNextWeek(todo)
        } else {
            abandon(todo)
        }
    }

    // MARK: 决定落地

    /// 右滑 → 排进下周:dueDate = 下周一(用户日起点),origin = .review——
    /// `insightContext` 的推迟计数排除 review origin,复盘排期不算推迟(§1.3)。
    private func scheduleToNextWeek(_ todo: TodoItemData) {
        let nextMonday = nextMondayStart()
        do {
            try store.updateFull(
                todo.id,
                update: detailUpdate(for: todo, dueDate: nextMonday),
                origin: .review
            )
            withAnimation(WarmAnimation.springBouncy) { state.markScheduled(todo) }
        } catch {
            onError(error)
        }
    }

    /// 「今天就做」:dueDate = 今天(用户日起点)。不提供 undo(拍板 7)。
    private func doToday(_ todo: TodoItemData) {
        let today = DayClock.startOfUserDay(for: Date(), calendar: calendar)
        do {
            try store.updateFull(
                todo.id,
                update: detailUpdate(for: todo, dueDate: today),
                origin: .review
            )
            withAnimation(WarmAnimation.springBouncy) { state.markToday(todo) }
            HapticFeedback.light()
        } catch {
            onError(error)
        }
    }

    /// 左滑 → 划掉(写 abandonedAt,不是 delete;仍在完成率分母里,拍板 1)。
    private func abandon(_ todo: TodoItemData) {
        do {
            try store.abandon(todo.id)
            withAnimation(WarmAnimation.springBouncy) { state.markAbandoned(todo) }
        } catch {
            onError(error)
        }
    }

    /// 拆小提交:建两条 TodoItem(parentTodoId 指向原任务)+ 原任务 abandon +
    /// 记 split 事件——三步在 `TodoStore.splitTodo` 同事务落地。
    private func submitSplit(_ todo: TodoItemData) {
        let titles = [splitField1, splitField2]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return }
        do {
            let children = titles.map { title in
                TodoItemData(
                    title: title,
                    dueDate: todo.dueDate,
                    hasDueTime: todo.hasDueTime,
                    timeBucket: todo.timeBucket,
                    priority: todo.priority,
                    category: todo.category,
                    localeIdentifier: todo.localeIdentifier,
                    parentTodoId: todo.id
                )
            }
            try store.splitTodo(todo.id, children: children)
            withAnimation(WarmAnimation.springBouncy) { state.markSplit(todo) }
            HapticFeedback.success()
            splitTarget = nil
            splitField1 = ""
            splitField2 = ""
        } catch {
            // sheet 不关:输入保留,用户可重试或手动取消;错误如实呈现。
            onError(error)
        }
    }

    // MARK: 工具

    /// 从现有 todo 拼 full update(仅改 dueDate,其余字段原样回写)。
    private func detailUpdate(for todo: TodoItemData, dueDate: Date) -> TodoDetailUpdate {
        TodoDetailUpdate(
            title: todo.title,
            detail: todo.detail,
            category: todo.category,
            priority: todo.priority,
            dueDate: dueDate,
            hasDueTime: false,
            timeBucket: todo.timeBucket,
            dueHint: todo.dueHint,
            recurrenceRule: todo.recurrenceRule
        )
    }

    /// 下一个周一的用户日起点(「排进下周」的落点)。
    private func nextMondayStart() -> Date {
        var components = DateComponents()
        components.weekday = 2 // 周一(gregorian)
        let next = calendar.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime
        ) ?? Date()
        return DayClock.startOfUserDay(for: next, calendar: calendar)
    }

    // MARK: 卡片

    private func triageCard(_ todo: TodoItemData) -> some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(todo.title)
                    .font(WarmFont.headline(17))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                cardMeta(todo)

                HStack(spacing: WarmSpacing.sm) {
                    smallButton(
                        title: String(localized: "review.flow.triage.action.today"),
                        icon: "sun.max"
                    ) { doToday(todo) }

                    smallButton(
                        title: String(localized: "review.flow.triage.action.split"),
                        icon: "scissors"
                    ) {
                        splitField1 = ""
                        splitField2 = ""
                        splitTarget = todo
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityIdentifier("ReviewFlowTriageCard")
    }

    /// 卡上元信息:推迟次数的一排斜杠(冷启动无推迟数据时换「记下 N 天了」)。
    @ViewBuilder
    private func cardMeta(_ todo: TodoItemData) -> some View {
        let deferCount = state.insightContextValue?.deferCounts[todo.id] ?? 0
        HStack(spacing: WarmSpacing.xs) {
            if deferCount > 0 {
                // 一道一次的斜杠——比「已推迟 4 次」更刺眼(§阶段 3)。
                Text(verbatim: String(repeating: "∕∕ ", count: min(deferCount, 6)))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.urgentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(String(localized: "review.flow.triage.deferred_a11y_\(deferCount)"))
            } else {
                let ageDays = calendar.dateComponents(
                    [.day],
                    from: DayClock.startOfUserDay(for: todo.createdAt, calendar: calendar),
                    to: DayClock.startOfUserDay(for: Date(), calendar: calendar)
                ).day ?? 0
                Text(String(localized: "review.flow.triage.age_\(ageDays)"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            Text(String(localized: "review.flow.triage.swipe_hint"))
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.textMuted.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func smallButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    Capsule().fill(WarmTheme.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 拆小 sheet

    /// 拆小 v1 手动:预填两条空的子任务输入框,两条都填才能提交。
    private func splitSheet(_ todo: TodoItemData) -> some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(spacing: WarmSpacing.lg) {
                    Text(todo.title)
                        .font(WarmFont.headline(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, WarmSpacing.lg)

                    VStack(spacing: WarmSpacing.md) {
                        splitTextField(
                            title: String(localized: "review.flow.split.field_1"),
                            text: $splitField1
                        )
                        splitTextField(
                            title: String(localized: "review.flow.split.field_2"),
                            text: $splitField2
                        )
                    }
                    .padding(.horizontal, WarmSpacing.lg)

                    Button {
                        submitSplit(todo)
                    } label: {
                        Text(String(localized: "review.flow.split.submit"))
                            .font(WarmFont.headline(15))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: WarmSize.touch)
                            .background(
                                Capsule().fill(canSubmitSplit ? WarmTheme.primary : WarmTheme.divider)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmitSplit)
                    .padding(.horizontal, WarmSpacing.lg)

                    Spacer()
                }
                .padding(.top, WarmSpacing.xl)
            }
            .navigationTitle(String(localized: "review.flow.split.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "review.flow.split.cancel")) {
                        splitTarget = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("ReviewFlowSplitSheet")
    }

    private var canSubmitSplit: Bool {
        ![splitField1, splitField2]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .contains(true)
    }

    private func splitTextField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Text(title)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            TextField("", text: text, axis: .vertical)
                .font(WarmFont.body(15))
                .lineLimit(1...2)
                .padding(WarmSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                        .fill(WarmTheme.inputFieldBackground)
                )
        }
    }
}
