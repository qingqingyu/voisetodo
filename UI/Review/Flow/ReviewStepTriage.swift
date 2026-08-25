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

    /// 拆小 sheet 依赖(2026-08-23 改版:AI 候选 + 说一句 + 动态加条)。
    /// splitter nil(测试/preview 未注入)→ sheet 直接降级为手写路径。
    let splitter: (any TodoSplitterProtocol)?
    /// 复盘内麦克风(与首页共用同一实例——复盘全屏时首页录音不可能并发,无会话冲突)。
    /// nil 时「说一句」行隐藏。
    let voiceInput: (any VoiceInputProtocol)?

    @State private var splitTarget: TodoItemData?
    /// 候选加载状态机:idle(未打开)→ loading → ready / failed(AI 失败 → 降级手写)。
    @State private var splitPhase: SplitPhase = .idle
    /// 候选来源(决定标题文案):ai = 打开/换一批;voice = 「说一句」切条。
    @State private var splitSource: SplitSource = .ai
    @State private var splitCandidates: [SplitCandidate] = []
    @State private var splitTask: Task<Void, Never>?
    @State private var customFieldText = ""
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

    /// 卡头:分类标签 +「上次重点」标记(上次复盘置顶、还没做完的)+「8月3日记下」。
    /// 卡头挤时压 bornLabel 的优先级,不压标记——「这是你上次自己定的重点」比
    /// 记下日重要(plan-do-review 闭环,2026-08-25)。
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

            if state.lastPinnedIDs.contains(todo.id) {
                Label(String(localized: "review.flow.triage.last_pinned"), systemImage: "pin.fill")
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, WarmSpacing.sm)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                            .fill(WarmTheme.subtleControlBackground)
                    )
            }

            Text(bornLabel(todo))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(-1)
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
        splitTarget = todo
        splitCandidates = []
        customFieldText = ""
        splitSource = .ai
        startSplitLoad(
            input: todo.title,
            locale: Locale(identifier: todo.localeIdentifier ?? Locale.current.identifier),
            wantsAlternative: false
        )
    }

    /// 发起候选加载。成功替换 AI 候选、保留手写行;失败置 failed(降级为手写路径,
    /// 拍板口径:AI 失败不弹错,「自己写一条」始终可用;失败明细在 service 层日志)。
    private func startSplitLoad(input: String, locale: Locale, wantsAlternative: Bool) {
        splitTask?.cancel()
        guard let splitter else {
            splitPhase = .failed
            return
        }
        // loading 期间麦克风行会隐藏——若正在录音(如 ready 态下边录音边点「换一批」),
        // 先按用户取消收掉,否则录音失去 UI 挂在后台,只能等关 sheet 才停。
        if voiceInput?.isRecording == true {
            voiceInput?.cancelRecordingByUser()
        }
        splitPhase = .loading
        splitTask = Task { @MainActor in
            do {
                let steps = try await splitter.splitSteps(
                    for: input,
                    locale: locale,
                    wantsAlternative: wantsAlternative
                )
                guard !Task.isCancelled else { return }
                let customs = splitCandidates.filter(\.custom)
                splitCandidates = steps.map { SplitCandidate(text: $0, checked: true, custom: false) } + customs
                splitPhase = .ready
            } catch is CancellationError {
                return // 换目标/关 sheet/再次发起:新流程已接管,状态不动
            } catch {
                guard !Task.isCancelled else { return }
                splitPhase = .failed
            }
        }
    }

    /// 「说一句」完成:转写文本作为 split 输入按内容切条,替换 AI 候选(手写行保留)。
    private func adoptVoiceTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = splitTarget else { return }
        splitSource = .voice
        let locale = voiceInput?.currentLocale ?? Locale(identifier: target.localeIdentifier ?? Locale.current.identifier)
        startSplitLoad(input: trimmed, locale: locale, wantsAlternative: false)
    }

    private func addCustomCandidate() {
        let text = customFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        splitCandidates.append(SplitCandidate(text: text, checked: true, custom: true))
        customFieldText = ""
    }

    /// 已勾选且非空的候选标题(提交与按钮文案共用)。
    private var selectedSplitTitles: [String] {
        splitCandidates.compactMap { candidate in
            guard candidate.checked else { return nil }
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// 拆小提交:建 N 条 TodoItem(parentTodoId 指向原任务)+ 原任务 abandon +
    /// 记 split 事件——三步在 `TodoStore.splitTodo` 同事务落地。
    /// 2026-08-23 改版:条数动态(≥1 即可,旧版两条必填的闸门废除)。
    private func submitSplit(_ todo: TodoItemData) {
        let titles = selectedSplitTitles
        guard !titles.isEmpty else { return }
        splitTask?.cancel()
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

    // MARK: 拆小 sheet(2026-08-23 改版)

    /// 三通道冗余:① AI 候选(点选/可改/换一批) ② 说一句(转写自动切条)
    /// ③ 自己写一条(动态数量,可删)。至少选 1 条即可提交;AI 失败 → ②③ 兜底。
    private func splitSheet(_ todo: TodoItemData) -> some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(spacing: WarmSpacing.md) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WarmSpacing.lg) {
                            splitOrigRow(todo)

                            switch splitPhase {
                            case .idle, .loading:
                                splitLoadingSection
                            case .ready:
                                splitCandidatesHeader
                            case .failed:
                                splitFailedNote
                            }

                            if !splitCandidates.isEmpty {
                                splitRows
                            }

                            if let voiceInput, splitPhase != .loading {
                                SplitMicRow(
                                    voiceInput: voiceInput,
                                    onError: onError,
                                    onAdopt: { adoptVoiceTranscript($0) }
                                )
                            }

                            splitCustomSection
                        }
                        .padding(.horizontal, WarmSpacing.lg)
                        .padding(.top, WarmSpacing.sm)
                        .padding(.bottom, WarmSpacing.lg)
                    }

                    splitSubmitRow(todo)
                }
            }
            .navigationTitle(String(localized: "review.flow.split.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "review.flow.split.cancel")) {
                        stopSplitSession()
                    }
                }
            }
            .onDisappear {
                stopSplitSession()
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("ReviewFlowSplitSheet")
    }

    /// 取消/关闭 sheet 时收尾:取消在途 AI 请求、停掉可能还在跑的录音。
    /// splitTarget 同步清空——SplitMicRow 的延迟采纳(onDisappear 后才跑的
    /// adoptVoiceTranscript)靠它拦截,否则会对已关闭的 sheet 多发一次拆小请求。
    private func stopSplitSession() {
        splitTask?.cancel()
        if voiceInput?.isRecording == true {
            voiceInput?.cancelRecordingByUser()
        }
        splitTarget = nil
    }

    /// 原任务行(引号 + 标题)。
    private func splitOrigRow(_ todo: TodoItemData) -> some View {
        HStack(alignment: .top, spacing: WarmSpacing.xs) {
            Image(systemName: "quote.opening")
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.primaryText)
                .flipsForRightToLeftLayoutDirection(true)

            Text(todo.title)
                .font(WarmFont.headline(15))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private var splitLoadingSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            Text(String(localized: "review.flow.split.loading"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                    .fill(WarmTheme.inputFieldBackground)
                    .frame(height: 44)
            }
        }
    }

    /// 候选区头:标题随来源变化(AI 候选 vs 按你说的切条)+ 换一批。
    private var splitCandidatesHeader: some View {
        HStack {
            Text(String(localized: splitSource == .ai
                ? "review.flow.split.candidates.title"
                : "review.flow.split.candidates.voice_title"))
                .font(WarmFont.headline(14))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)

            Spacer(minLength: WarmSpacing.xs)

            Button(String(localized: "review.flow.split.regen")) {
                guard let target = splitTarget else { return }
                splitSource = .ai
                startSplitLoad(
                    input: target.title,
                    locale: Locale(identifier: target.localeIdentifier ?? Locale.current.identifier),
                    wantsAlternative: true
                )
            }
            .font(WarmFont.caption(13))
            .foregroundColor(WarmTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .buttonStyle(.plain)
        }
    }

    private var splitFailedNote: some View {
        Text(String(localized: "review.flow.split.failed"))
            .font(WarmFont.caption(13))
            .foregroundColor(WarmTheme.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 候选行列表(AI 候选 + 手写行混排;手写行带删除)。
    private var splitRows: some View {
        VStack(spacing: WarmSpacing.sm) {
            ForEach($splitCandidates) { $candidate in
                splitCandidateRow($candidate)
            }
        }
    }

    private func splitCandidateRow(_ candidate: Binding<SplitCandidate>) -> some View {
        HStack(spacing: WarmSpacing.sm) {
            Button {
                candidate.wrappedValue.checked.toggle()
                HapticFeedback.selection()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            candidate.wrappedValue.checked ? WarmTheme.primary : WarmTheme.divider,
                            lineWidth: 2
                        )
                        .background(
                            Circle().fill(candidate.wrappedValue.checked ? WarmTheme.primary : .clear)
                        )
                    if candidate.wrappedValue.checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 22, height: 22)
                .animation(WarmAnimation.springStandard, value: candidate.wrappedValue.checked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: candidate.wrappedValue.checked
                ? "review.flow.split.a11y.deselect"
                : "review.flow.split.a11y.select"))

            TextField("", text: candidate.text, axis: .vertical)
                .font(WarmFont.body(15))
                .foregroundColor(candidate.wrappedValue.checked ? WarmTheme.textPrimary : WarmTheme.textMuted)
                .lineLimit(1...2)
                .padding(WarmSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                        .fill(WarmTheme.inputFieldBackground)
                )

            if candidate.wrappedValue.custom {
                Button {
                    splitCandidates.removeAll { $0.id == candidate.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WarmTheme.textMuted)
                        .padding(WarmSpacing.xs)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "review.flow.split.a11y.delete"))
            }
        }
    }

    private var splitCustomSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            Text(String(localized: "review.flow.split.custom.title"))
                .font(WarmFont.headline(14))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: WarmSpacing.sm) {
                TextField(
                    String(localized: "review.flow.split.custom.placeholder"),
                    text: $customFieldText
                )
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .padding(WarmSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                        .fill(WarmTheme.inputFieldBackground)
                )
                .onSubmit { addCustomCandidate() }

                Button {
                    addCustomCandidate()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.primaryText)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                                .fill(WarmTheme.subtleControlBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(customFieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(String(localized: "review.flow.split.custom.add"))
            }
        }
    }

    /// 提交行:实时报数「拆成 N 条」;0 条时禁用并说明「至少选一条」。
    private func splitSubmitRow(_ todo: TodoItemData) -> some View {
        let count = selectedSplitTitles.count
        return Button {
            submitSplit(todo)
        } label: {
            Text(String(localized: count > 0
                ? "review.flow.split.submit_\(count)"
                : "review.flow.split.submit_disabled"))
                .font(WarmFont.headline(15))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: WarmSize.touch)
                .background(
                    Capsule().fill(count > 0 ? WarmTheme.primary : WarmTheme.divider)
                )
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .padding(.horizontal, WarmSpacing.lg)
    }
}

// MARK: - 拆小 sheet 数据类型

/// 候选加载状态。failed = AI/网络失败 → 降级为「自己写一条」路径(拍板:失败降级手写)。
enum SplitPhase {
    case idle
    case loading
    case ready
    case failed
}

/// 候选来源:ai = 打开/换一批;voice = 「说一句」切条(候选区标题文案不同)。
enum SplitSource {
    case ai
    case voice
}

/// 一条候选步骤。custom = 用户手写(带删除按钮;换候选/语音切条时保留)。
struct SplitCandidate: Identifiable {
    let id = UUID()
    var text: String
    var checked: Bool
    let custom: Bool
}

/// sheet 内「说一句」行(2026-08-23 拆小改版):复用全局 `VoiceInputProtocol` 实例。
/// 说完(手动停 / 静音自动停)把本次转写交给 `onAdopt` 切条;取消不留痕。
/// 转写走本地 SFSpeechRecognizer,不经代理、不耗 AI 额度(与首页录音同一成本结构)。
///
/// 观察方式:手写订阅三个 Publisher 镜像进 @State——`any VoiceInputProtocol`
/// 存在类型满足不了 `@ObservedObject` 的泛型约束(Swift 限制),协议已把状态
/// 全部暴露为 Publisher,镜像订阅是等价且唯一干净的路。
/// 注意:录音只能在真机验证(CLAUDE.md 模拟器限制)。
private struct SplitMicRow: View {
    let voiceInput: any VoiceInputProtocol
    let onError: (Error) -> Void
    let onAdopt: (String) -> Void

    /// isRecording 的本地镜像(onAppear 播种 + publisher 同步)。
    @State private var isRecording = false
    /// 本次监听期间累积的转写。不直接读 `voiceInput.transcript`——那里可能留着
    /// 首页上一次录音的旧文本,只有监听开始后的 publisher 事件才是本次的。
    @State private var liveText = ""
    @State private var wasListening = false
    /// 录音停止后的待采纳转写(error 事件在下一个 runloop 前可将其清空作废)。
    @State private var pendingAdoptText: String?

    var body: some View {
        Group {
            if isRecording {
                listeningRow
            } else {
                idleRow
            }
        }
        .onAppear {
            // 行可能出现在录音已开始之后(如候选加载完成时):播种当前态
            isRecording = voiceInput.isRecording
        }
        .onReceive(voiceInput.isRecordingPublisher) { recording in
            isRecording = recording
            if recording {
                wasListening = true
                liveText = ""
                pendingAdoptText = nil
            } else if wasListening {
                // 结束(手动停/静音自动停):进入待采纳态。VoiceInputManager 的错误路径
                // (中断/watchdog)是先置 isRecording=false 再设 error——同一个调用栈里
                // error 事件会紧跟着到,这里延后一个 runloop 再决定采纳还是报错,
                // 避免把不完整转写当结果、又把错误吞掉。
                wasListening = false
                let final = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                liveText = ""
                guard !final.isEmpty else { return }
                pendingAdoptText = final
                DispatchQueue.main.async {
                    guard let text = pendingAdoptText else { return } // error 路径已清空
                    pendingAdoptText = nil
                    onAdopt(text)
                }
            }
        }
        .onReceive(voiceInput.transcriptPublisher) { text in
            guard wasListening else { return }
            liveText = text
        }
        .onReceive(voiceInput.errorPublisher) { error in
            // 录音出错(含停止后紧跟的错误事件):不采纳、如实上报(错误显式传播,不静默)
            guard let error, wasListening || pendingAdoptText != nil else { return }
            wasListening = false
            liveText = ""
            pendingAdoptText = nil
            onError(error)
        }
    }

    private var idleRow: some View {
        Button {
            Task { @MainActor in
                do {
                    try await voiceInput.startRecording()
                } catch {
                    onError(error)
                }
            }
        } label: {
            HStack(spacing: WarmSpacing.sm) {
                Label(String(localized: "review.flow.split.mic.say"), systemImage: "mic.fill")
                    .font(WarmFont.headline(13))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: WarmSpacing.xs)

                Text(String(localized: "review.flow.split.mic.hint"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            .padding(WarmSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                    .fill(WarmTheme.cardBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var listeningRow: some View {
        HStack(spacing: WarmSpacing.sm) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16))
                .foregroundColor(WarmTheme.urgentText)

            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(verbatim: liveText.isEmpty
                    ? String(localized: "review.flow.split.mic.listening")
                    : liveText)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                HStack(spacing: WarmSpacing.md) {
                    // 手动「说完了」:等 isFinal 最终转写后自动停止 → 采纳
                    Button(String(localized: "review.flow.split.mic.done")) {
                        voiceInput.finishRecording()
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .buttonStyle(.plain)

                    Button(String(localized: "review.flow.split.mic.cancel")) {
                        voiceInput.cancelRecordingByUser()
                        wasListening = false
                        liveText = ""
                        pendingAdoptText = nil
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .buttonStyle(.plain)
                }
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .buttonStyle(.plain)
            }
        }
        .padding(WarmSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
    }
}
