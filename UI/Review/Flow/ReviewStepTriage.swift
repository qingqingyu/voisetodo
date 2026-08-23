import SwiftUI

/// 第 2 步 · 处理没做完的一次性任务(卡片堆;阶段 3,2026-08-22 交互改版落地)。
///
/// 输入(拍板 4):未完成 && abandonedAt == nil && recurrenceRule == nil——
/// 规律父任务永远 isCompleted == false 会刷屏,右滑「排下周」语义不明,排除。
///
/// 三通道冗余(用户 swipe 目标形态,行业惯例):
/// 1. **拖动 stamp 印章**——越过 24pt 起淡入(24→85 归一化),松手前就确认方向;
///    静止时 opacity 0,零成本。
/// 2. **底部按钮 pad**——✕「不做了」(左圆钮)/ 今天就做·拆小(中)/ →「排下周」
///    (右圆钮),按钮空间位置即手势方向教学,也是没发现手势的人的完整通路。
/// 3. **长按 0.5s** → confirmationDialog 全动作菜单(Gmail 备用入口)。
/// 另:首卡 nudge 教学(每次进入第 2 步一次)、拖拽微旋转(dx×0.03°)、推迟时间轴、
/// 语音原文引号(rawTranscript,无假波形)、双层 ghost 卡堆、「N / M」计数器。
///
/// 文案口径(2026-08-22):「划掉」→「不做了」(账本行同步);abandon 写
/// abandonedAt 不是 delete,仍在完成率分母(拍板 1)。撤销只覆盖「不做了」(拍板 7)。
struct ReviewStepTriage: View {
    @Bindable var state: ReviewFlowState
    let store: any ReviewFlowStore
    let onError: (Error) -> Void
    let onUndoToast: (String) -> Void

    /// 滑动触发阈值:位移 85pt **或**速度 800pt/s 任一达标;stamp 从 24pt 起淡入。
    private static let distanceThreshold: CGFloat = 85
    private static let velocityThreshold: CGFloat = 800
    private static let stampInDistance: CGFloat = 24
    /// 飞出动画:距离与时长(动画 duration 与状态落地的 asyncAfter deadline 必须一致)。
    private static let flyOutDistance: CGFloat = 520
    private static let flyOutDuration: TimeInterval = 0.25
    /// 时间轴推迟节点的显示上限(防 10+ 次推迟挤爆行宽)。
    private static let timelineNodeCap = 8

    /// 拆小 sheet 的两条子任务输入(v1 手动,AI 版阶段 5)。
    @State private var splitTarget: TodoItemData?
    @State private var splitField1 = ""
    @State private var splitField2 = ""
    /// 拖拽跟手偏移(手势进行中)。
    @State private var dragOffset: CGFloat = 0
    /// 飞出动画期间置 0(状态更新在动画结束后进行,提前改会掐断动画)。
    @State private var cardOpacity: CGFloat = 1
    /// 长按备用菜单。
    @State private var showsActionMenu = false
    /// 卡片飞出动画进行中(250ms 窗口):期间 deck 尚未更新,禁用 pad/菜单/二次滑动,
    /// 防止对同一张卡双重落地(abandonedStack 重复入栈、账本虚高)。
    @State private var isFlying = false
    /// 首卡 nudge 教学(每次进入第 2 步一次:步骤切换会重建视图、@State 随之重置;
    /// 不持久化,拍板口径)。
    @State private var nudgeOffset: CGFloat = 0
    @State private var nudgePlayed = false

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            headerRow
            ledeText

            if !state.abandonedStack.isEmpty {
                undoButton
            }

            if state.deck.isEmpty {
                emptyDeck
            } else {
                Spacer(minLength: WarmSpacing.xs)
                deckView
                pad
                Spacer(minLength: WarmSpacing.xs)
            }
        }
        .sheet(item: $splitTarget) { todo in
            splitSheet(todo)
        }
        .confirmationDialog(
            String(localized: "review.flow.triage.menu.title"),
            isPresented: $showsActionMenu,
            titleVisibility: .visible
        ) {
            if let top = state.deck.first {
                Button(String(localized: "review.flow.triage.action.today")) { if !isFlying { doToday(top) } }
                Button(String(localized: "review.flow.triage.action.split")) { if !isFlying { openSplit(top) } }
                Button(String(localized: "review.flow.triage.action.keep")) { if !isFlying { scheduleToNextWeek(top) } }
                Button(String(localized: "review.flow.triage.action.drop"), role: .destructive) { if !isFlying { abandon(top) } }
            }
            Button(String(localized: "review.flow.split.cancel"), role: .cancel) {}
        }
        .onAppear {
            applyFocusReorder()
            playNudgeOnce()
        }
        .onChange(of: state.triageFocusID) { _, _ in applyFocusReorder() }
    }

    // MARK: 头部(标题 + 计数)

    private var headerRow: some View {
        let ledger = state.ledger
        let current = min(ledger.inputCount - ledger.remainingCount + 1, max(ledger.inputCount, 1))
        return HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "review.flow.triage.title"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)

            Spacer(minLength: WarmSpacing.xs)

            // 零输入(deck 本就为空)时不显示计数,避免出现「1 / 0」。
            if ledger.inputCount > 0 {
                Text(verbatim: "\(current) / \(ledger.inputCount)")
                    .font(WarmFont.mono(12))
                    .foregroundColor(WarmTheme.textMuted)
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    private var ledeText: some View {
        Text(String(localized: "review.flow.triage.lede"))
            .font(WarmFont.caption(12))
            .foregroundColor(WarmTheme.textMuted)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: 撤销

    /// 「撤销上一张」:unabandon 最近一次划掉(拍板 7:只覆盖「不做了」)。
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

    /// 首卡 nudge 教学:进场后向右轻推一下,示范滑动方向(每次进入第 2 步一次)。
    private func playNudgeOnce() {
        guard !nudgePlayed, !state.deck.isEmpty else { return }
        nudgePlayed = true
        withAnimation(.easeInOut(duration: 0.35).delay(0.6)) { nudgeOffset = 24 }
        withAnimation(.easeInOut(duration: 0.35).delay(1.05)) { nudgeOffset = 0 }
    }

    private var deckView: some View {
        ZStack {
            // 第三层:纯色卡背,只给厚度感。
            if state.deck.count > 2 {
                RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
                    .padding(.horizontal, WarmSpacing.xl + WarmSpacing.md)
                    .offset(y: WarmSpacing.xl)
                    .opacity(0.38)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // 第二层:露一点边 + 内容,给「还有下一张」的厚度感。
            if state.deck.count > 1 {
                cardContent(state.deck[1])
                    .padding(.horizontal, WarmSpacing.xl)
                    .offset(y: WarmSpacing.md)
                    .opacity(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let top = state.deck.first {
                topCard(top)
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    private func topCard(_ todo: TodoItemData) -> some View {
        cardContent(todo)
            .overlay(alignment: .topLeading) { stamp(isDrop: true) }
            .overlay(alignment: .topTrailing) { stamp(isDrop: false) }
            .opacity(cardOpacity)
            .offset(x: dragOffset + nudgeOffset)
            .rotationEffect(.degrees(Double(dragOffset) * 0.03))
            .allowsHitTesting(!isFlying)
            .gesture(
                SimultaneousDragGesture(
                    minimumDistance: 24,
                    direction: .horizontal,
                    onChanged: { drag in
                        guard !isFlying else { return }
                        nudgeOffset = 0 // 用户开始拖拽即停 nudge,避免两 offset 叠加导致跟手偏移不准
                        HapticFeedback.selection()
                        dragOffset = drag.translation.width
                    },
                    onEnded: { drag in
                        guard !isFlying else { return }
                        handleSwipe(drag, on: todo)
                    },
                    onCancelled: {
                        guard !isFlying else { return }
                        settleBack()
                    }
                )
            )
            .onLongPressGesture(minimumDuration: 0.5) {
                guard !isFlying else { return }
                settleBack()
                showsActionMenu = true
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .scale(scale: 1.05).combined(with: .opacity)
            ))
            .accessibilityIdentifier("ReviewFlowTriageCard")
    }

    // MARK: Stamp 印章

    /// 拖动方向印章:越过 24pt 起淡入,透明度随 24→85 位移归一化;静止时为 0。
    /// 倾斜 ±13°,左「不做了」红 / 右「排下周」橙。装饰性,a11y 隐藏。
    private func stamp(isDrop: Bool) -> some View {
        let progress = min(
            max((abs(dragOffset) - Self.stampInDistance) / (Self.distanceThreshold - Self.stampInDistance), 0),
            1
        )
        let active = isDrop ? dragOffset < -Self.stampInDistance : dragOffset > Self.stampInDistance
        let color = isDrop ? WarmTheme.urgentText : WarmTheme.primaryText
        return Text(String(localized: isDrop ? "review.flow.triage.action.drop" : "review.flow.triage.action.keep"))
            .font(WarmFont.headline(19))
            .tracking(2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(color)
            .padding(.horizontal, WarmSpacing.md - 4)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color, lineWidth: 3)
            )
            .rotationEffect(.degrees(isDrop ? -13 : 13))
            .opacity(active ? progress : 0)
            .accessibilityHidden(true)
            .padding(WarmSpacing.md)
    }

    /// 阈值判定:位移或速度任一达标即触发;否则弹回。
    private func handleSwipe(_ drag: DragTranslation, on todo: TodoItemData) {
        let dx = drag.translation.width
        let speed = abs(drag.velocity.dx)
        let distanceHit = abs(dx) >= Self.distanceThreshold
        let velocityHit = speed >= Self.velocityThreshold

        guard distanceHit || velocityHit else {
            settleBack()
            return
        }
        // 位移方向优先;纯速度触发时用速度方向。
        let rightward = distanceHit ? dx > 0 : drag.velocity.dx > 0
        HapticFeedback.medium()

        // 印章满显 + 沿滑动方向旋转飞出;250ms 后再写 store / 改状态,
        // 提前改会因卡堆重建掐断飞出动画。窗口内 isFlying=true,禁一切二次动作。
        isFlying = true
        withAnimation(.easeIn(duration: Self.flyOutDuration)) {
            dragOffset = rightward ? Self.flyOutDistance : -Self.flyOutDistance
            cardOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flyOutDuration) {
            if rightward {
                scheduleToNextWeek(todo)
            } else {
                abandon(todo)
            }
            dragOffset = 0
            cardOpacity = 1
            isFlying = false
        }
    }

    private func settleBack() {
        withAnimation(WarmAnimation.springStandard) { dragOffset = 0 }
    }

    // MARK: 卡面

    private func cardContent(_ todo: TodoItemData) -> some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                cardHead(todo)

                Text(todo.title)
                    .font(WarmFont.headline(17))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                timeline(todo)

                if let quote = voiceQuote(todo) {
                    quoteRow(quote)
                }
            }
        }
    }

    /// 卡头:分类标签 +「8月3日记下」。
    private func cardHead(_ todo: TodoItemData) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(todo.category.displayName)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                        .fill(WarmTheme.subtleControlBackground)
                )

            Text(bornLabel(todo))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 推迟时间轴:记下日 →(每次推迟一个节点)→ 现在。推迟次数高亮在右端;
    /// 冷启动无推迟数据时右端显示「还没推迟过」。
    private func timeline(_ todo: TodoItemData) -> some View {
        let deferCount = state.insightContextValue?.deferCounts[todo.id] ?? 0
        let nodes = min(deferCount, Self.timelineNodeCap)
        return VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack(spacing: WarmSpacing.xs) {
                Circle()
                    .fill(WarmTheme.textMuted)
                    .frame(width: 6, height: 6)

                ForEach(0..<nodes, id: \.self) { _ in
                    timelineSegment
                    Circle()
                        .fill(WarmTheme.textMuted.opacity(0.45))
                        .frame(width: 6, height: 6)
                }

                timelineSegment

                Circle()
                    .strokeBorder(WarmTheme.primaryText, lineWidth: 2)
                    .background(Circle().fill(WarmTheme.cardBackground))
                    .frame(width: 11, height: 11)
            }

            HStack {
                // 记下日已在卡头展示,此处不重复;时间轴底行只承载右端推迟计数。
                Spacer(minLength: WarmSpacing.xs)

                if deferCount > 0 {
                    Text(String(localized: "review.flow.triage.tl_deferred_\(deferCount)"))
                        .font(WarmFont.headline(11))
                        .foregroundColor(WarmTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(String(localized: "review.flow.triage.tl_nodefer"))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var timelineSegment: some View {
        Rectangle()
            .fill(WarmTheme.rowHairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    /// 语音原文(创建这条任务时说的话)。无转写原文(键盘输入等)时整行隐藏;
    /// 不做假波形/假时长——真实数据只有文字。
    private func voiceQuote(_ todo: TodoItemData) -> String? {
        guard let raw = todo.rawTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    private func quoteRow(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: WarmSpacing.xs) {
            Image(systemName: "quote.opening")
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.primaryText)

            Text(quote)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(.top, WarmSpacing.xxs)
    }

    private func bornLabel(_ todo: TodoItemData) -> String {
        String(localized: "review.flow.triage.born_\(todo.createdAt.formatted(.dateTime.month().day()))")
    }

    // MARK: 底部按钮 pad(位置 = 手势方向)

    private var pad: some View {
        HStack(spacing: WarmSpacing.lg) {
            padRoundButton(
                icon: "xmark",
                label: String(localized: "review.flow.triage.action.drop"),
                color: WarmTheme.urgentText,
                id: "ReviewFlowTriageDrop"
            ) {
                if let top = state.deck.first, !isFlying { abandon(top) }
            }

            HStack(spacing: WarmSpacing.sm) {
                padCapsuleButton(
                    title: String(localized: "review.flow.triage.action.today"),
                    icon: "sun.max"
                ) {
                    if let top = state.deck.first, !isFlying { doToday(top) }
                }

                padCapsuleButton(
                    title: String(localized: "review.flow.triage.action.split"),
                    icon: "scissors"
                ) {
                    if let top = state.deck.first, !isFlying { openSplit(top) }
                }
            }

            padRoundButton(
                icon: "arrow.right",
                label: String(localized: "review.flow.triage.action.keep"),
                color: WarmTheme.primaryText,
                id: "ReviewFlowTriageKeep"
            ) {
                if let top = state.deck.first, !isFlying { scheduleToNextWeek(top) }
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 方向性圆钮(✕/→):56pt 白底圆 + 图标 + 底部小标签。
    private func padRoundButton(icon: String, label: String, color: Color, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(WarmTheme.cardBackground)
                            .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 3)
                    )
                    .flipsForRightToLeftLayoutDirection(true)

                Text(label)
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 中性胶囊小钮(今天就做/拆小)。
    private func padCapsuleButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    Capsule()
                        .fill(WarmTheme.cardBackground)
                        .overlay(
                            Capsule().strokeBorder(WarmTheme.rowHairline, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 决定落地

    /// 右滑/「排下周」:dueDate = 下周一(用户日起点),origin = .review——
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

    /// 左滑/「不做了」:写 abandonedAt,不是 delete;仍在完成率分母(拍板 1)。
    private func abandon(_ todo: TodoItemData) {
        do {
            try store.abandon(todo.id)
            withAnimation(WarmAnimation.springBouncy) { state.markAbandoned(todo) }
        } catch {
            onError(error)
        }
    }

    private func openSplit(_ todo: TodoItemData) {
        splitField1 = ""
        splitField2 = ""
        splitTarget = todo
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
