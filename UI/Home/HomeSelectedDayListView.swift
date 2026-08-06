import SwiftUI

struct HomeSelectedDayListView: View {
    let state: HomeCalendarState
    let selectedBottomTab: BottomTab
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onDeleteTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    /// 长按 context menu:卡片移到某 bucket。
    let onMoveToBucket: (UUID, TimeBucket) -> Void
    /// 长按 context menu:卡片移到明天。
    let onMoveToTomorrow: (UUID) -> Void
    /// 时间 chip 点击后的改时间入口。`Date` 由 `TimeEditPopover` 提交时填好,本回调负责写库。
    /// 改时间 popover 只用于「今日 Section」的 occurrence,待定日期组走自己的「选日期」按钮(Commit 6)。
    let onChangeTime: (UUID, Date) -> Void
    /// 「待定日期」分组「选日期」按钮提交后写库。参数是用户选定的 startOfDay,
    /// 调用方按 hasDueTime=false + timeBucket=nil 写入(剥离时段,只保留日期)。
    let onPickDate: (UUID, Date) -> Void
    /// 「没能识别」分组「重新解析」按钮入口。把 rawTranscript 再喂一遍 extractor,
    /// 成功 → 替换原 todo 为 .parsed;失败 → 保留原 todo + toast。
    let onReextract: (UUID) -> Void
    /// 「稍后」section 拖拽排序回调。参数为用户拖完后该 section 的新顺序 todo id 数组,
    /// 调用方走 store.reorder 做局部重排(只动这组 sortOrder,不影响其他 section)。
    let onReorder: ([UUID]) -> Void
    /// 正在重新解析的 todo id 集合(来自 AppCoordinator.reextractingTodoIDs)。
    /// 用于驱动 UnparsedTodoCard 的按钮 disabled + ProgressView,防连点。
    var reextractingTodoIDs: Set<UUID> = []
    /// 待揭晓的新增条目 id(来自 AppCoordinator.pendingRevealTodoIDs)。
    /// 这些条目已写库但还没在 UI 上播过入场动画——`onAppear` 必须跳过自动 insert,
    /// 等 HomeView 在 ConfirmSheet `onDismiss` 后按 rank 依次放动画。否则动画会在
    /// sheet 背后播完,用户看到一堆静止的行。详见 docs/confirm-sheet-success-feedback-to-list-entrance.md。
    var pendingRevealIDs: Set<UUID> = []

    /// 选中日是否完全无 todo 数据(未完成 + 已完成 + 待处理 bucket 全空)。
    /// 用于决定 Today Section body 是否走 `emptySelectedDayRow` 空态分支。
    private var isSelectedDayCompletelyEmpty: Bool {
        state.selectedOccurrences.isEmpty
            && state.pendingDateTodos.isEmpty
            && state.unparsedTodos.isEmpty
            && state.unscheduledTodos.isEmpty
    }

    var body: some View {
        List {
            // Today Section 无 header —— 顶部 headerView 的大标题已经标明当前是「Today」tab,
            // list 里再挂 "Today · N" 会与顶部标题重复(用户 2026-07-25 真机反馈)。
            // 其他 section(稍后 / 待定日期 / 没能识别 / 已完成)保留 daySectionHeader,
            // 因为它们的标题信息(分组名 + 数量)无法从顶部推导。
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if isSelectedDayCompletelyEmpty {
                    emptySelectedDayRow
                } else {
                    todaySectionBody
                }
            }

            // 「稍后」分区(原「未定时间」):完全无时间信号的待排期货(原「未安排」,语义收紧后改名)。
            // 排在 Today 之后——用户主动暂存的待办(类 Inbox 性质),需要快速访问;
            // 与海外主流 todo app(Things 3 / TickTick 等)把 Inbox 提前的模式一致。
            // 本分区启用 `.onMove`:长按 row 进入拖拽模式,松手后回调 onReorder 走 store.reorder。
            // 对应 s17/s20 用户反馈(未设时任务想自由排序,不想为排序逐项设时间)。
            if !state.unscheduledTodos.isEmpty {
                Section {
                    // 不用 enumerated —— `.onMove` 要求 ForEach 直接对 Identifiable 集合迭代,
                    // 元组数组会破坏 List 内置 reorder 手势识别。
                    // index 改用 firstIndex 取(列表通常 < 20 项,O(n²) 可接受),
                    // 数值与原 enumerated 一致,WarmTodoCard staggered 动画不变。
                    ForEach(state.unscheduledTodos) { todo in
                        let idx = state.unscheduledTodos.firstIndex(where: { $0.id == todo.id }) ?? 0
                        todoRow(todo, index: state.selectedOccurrences.count + idx)
                    }
                    .onMove { offsets, target in
                        var arr = state.unscheduledTodos
                        arr.move(fromOffsets: offsets, toOffset: target)
                        onReorder(arr.map(\.id))
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.undated.section"),
                        count: state.unscheduledTodos.count,
                        subtitle: String(localized: "home.undated.section.hint")
                    )
                }
            }

            // 「待定日期」分区:有时间信号(timeBucket 或 dueHint)但没具体日期。
            // 用 PendingDateTodoRow:橙描边「选日期」按钮 + .loose chip 显示时段 / dueHint。
            // 半完成态——用户已表达意向但需手动选日期,中段优先级。
            if !state.pendingDateTodos.isEmpty {
                Section {
                    ForEach(Array(state.pendingDateTodos.enumerated()), id: \.element.id) { idx, todo in
                        PendingDateTodoRow(
                            todo: todo,
                            index: state.unscheduledTodos.count + idx,
                            onToggle: { onToggleTodo(todo.id) },
                            onOpen: { onOpenTodo(todo) },
                            onDelete: { onDeleteTodo(todo.id) },
                            onPickDate: { date in onPickDate(todo.id, date) }
                        )
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.pending_date.section"),
                        count: state.pendingDateTodos.count
                    )
                }
            }

            // 「没能识别」分区:outcome != .parsed 的原文兜底条目。
            // 用 UnparsedTodoCard:斜纹背景 + dashed border + 「重新解析 / 删除」按钮。
            // 系统失败态——靠后,避免干扰主线;对应海外 app 隐藏/角落化失败条目的模式。
            if !state.unparsedTodos.isEmpty {
                Section {
                    ForEach(Array(state.unparsedTodos.enumerated()), id: \.element.id) { idx, todo in
                        UnparsedTodoCard(
                            todo: todo,
                            index: idx,
                            onReextract: { onReextract(todo.id) },
                            onDelete: { onDeleteTodo(todo.id) },
                            isReextracting: reextractingTodoIDs.contains(todo.id)
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDeleteTodo(todo.id)
                            } label: {
                                Label(String(localized: "home.delete"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.unparsed.section"),
                        count: state.unparsedTodos.count
                    )
                }
            }

            // 「已完成」分区 = 当日 occurrence 的已完成 + 全局无安排任务的已完成。
            // 放最后:已完成是历史信息,优先级最低。
            if !state.completedOccurrences.isEmpty || !state.completedUnscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(occurrence, index: state.uncompletedOccurrences.count + idx)
                    }
                    ForEach(Array(state.completedUnscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        // index 延续「已完成 occurrence」之后,跨过 today / unscheduled / pendingDate / unparsed
                        // 各 section 的行数(按当前 section 顺序),避免 a11y identifier 与前面 section 的行号撞号。
                        completedTodoRow(todo, index: state.selectedOccurrences.count
                                        + state.unscheduledTodos.count
                                        + state.pendingDateTodos.count
                                        + state.unparsedTodos.count + idx)
                    }
                } header: {
                    let totalCount = state.completedOccurrences.count + state.completedUnscheduledTodos.count
                    daySectionHeader(title: String(localized: "home.completed_section_title"), count: totalCount)
                }
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollContent)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollIndicators)
        .accessibilityIdentifier("TodoList")
    }

    /// 今天 Section 的内部 body:按时间确定度递增渲染三层 tier。
    /// 每个 tier 先吐一行 tierLabelRow(细分隔线 + 小标签),再吐该 tier 的 occurrence。
    /// tierLabelRow 不挂 `.swipeActions` —— 与 card 行互不干扰,与 iOS Reminders 分组同模式。
    @ViewBuilder
    private var todaySectionBody: some View {
        let tiered = state.tieredUncompletedOccurrences
        let occurrenceCountSoFar = occurrenceRunningCounter(within: tiered)
        ForEach(Array(tiered.enumerated()), id: \.offset) { tierIndex, group in
            tierLabelRow(group.tier)
                .listRowSeparator(.hidden)
                // 留白分组(苹果 Reminders / Calendar 模式):
                // - tierIndex==0:第一个 tier,上面紧贴 Today Section 顶,留 xs(8) 不挤压
                // - 后续 tier:加大顶距到 lg(20),靠呼吸感把上一个 tier 的卡片群与下一个 tier 标题切开
                // - bottom 永远 xxs(4):标签和它管的第一张卡片贴近,让「标题—卡片群」是一个视觉块
                // 用户 2026-07-25 真机反馈:之前用 1px 横线切割,在毛玻璃 + 圆角卡片语言里违和;
                // 去线后靠「上空白大 / 下空白小」的非对称留白做层级,更贴合系统视觉。
                .listRowInsets(EdgeInsets(top: tierIndex == 0 ? WarmSpacing.xs : WarmSpacing.lg,
                                          leading: WarmSpacing.lg,
                                          bottom: WarmSpacing.xxs,
                                          trailing: WarmSpacing.lg))
                .listRowBackground(Color.clear)

            ForEach(Array(group.items.enumerated()), id: \.element.id) { inTierIndex, occurrence in
                occurrenceRow(occurrence, index: occurrenceCountSoFar(tierIndex) + inTierIndex)
            }
        }
    }

    /// tier-label 行:纯灰小字标题(整天 / 上午 / 下午 / 晚上 / 按时间)。
    /// 字号 11pt + 0.8 tracking + textMuted,对齐 iOS Reminders 分组标题做法。
    /// 不挂分隔线 —— 卡片已经毛玻璃 + 圆角 + 阴影自成层级,再加 1px 实线会显得「切割」而非「呼吸」。
    /// 用户 2026-07-25 真机反馈:横线在柔和视觉语言里违和,改靠留白分组。
    /// 不挂 swipeActions / listRowSeparator 都隐藏 —— 与 card 行视觉解耦,
    /// 不让 List 把它当数据 row 渲染。
    @ViewBuilder
    private func tierLabelRow(_ tier: TodayTier) -> some View {
        Text(tier.localizedLabel)
            .font(WarmFont.caption(11))
            .tracking(0.8)
            .foregroundColor(WarmTheme.textMuted)
            .accessibilityHidden(true)
    }

    /// 计算 tier 内 occurrence 的全局 running index,用于 warmTodoCard 的 `index` 参数
    /// (a11y identifier `TodoCheckbox_\(index)` 需要全局稳定)。
    /// 返回 closure: (tierIndex) -> 起始 index
    private func occurrenceRunningCounter(
        within tiered: [(tier: TodayTier, items: [TodoOccurrenceData])]
    ) -> (Int) -> Int {
        var runningSums = [Int]()
        var accumulator = 0
        for group in tiered {
            runningSums.append(accumulator)
            accumulator += group.items.count
        }
        return { tierIndex in tierIndex < runningSums.count ? runningSums[tierIndex] : 0 }
    }

    private var homeGlobalEmptyRow: some View {
        // 空状态：去卡片容器，内容直接坐背景上；加向下箭头引导视线到 FAB；
        // top inset 加大让内容接近屏幕视觉中心（~40-45% 高度）。
        VStack(spacing: WarmSpacing.lg) {
            ProductEmptyStateView(
                icon: "sparkles",
                title: String(localized: "empty.home.title"),
                message: String(localized: "empty.home.message"),
                cardless: true
            )
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(WarmTheme.primary.opacity(0.35))
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: HomeLayoutMetrics.emptyStateTopInset, leading: WarmSpacing.lg, bottom: WarmSpacing.sm, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    /// 选中日空状态:cardless + 大细线图标 + 引导文案 + 向下箭头。
    /// 对齐 `homeGlobalEmptyRow` 的视觉模式(用户反馈:原版白底卡片像内容、无引导、
    /// 浪费整屏空间)。两个 Text 都加 lineLimit + minimumScaleFactor,
    /// 遵守 CLAUDE.md「文本布局规则」——AX5 字号下允许缩到 0.7 倍避免换行溢出。
    private var emptySelectedDayRow: some View {
        VStack(spacing: WarmSpacing.lg) {
            VStack(spacing: WarmSpacing.xs) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(WarmTheme.primary.opacity(0.7))

                Text(String(localized: selectedBottomTab == .today
                             ? "empty.day.today" : "empty.day.title"))
                    .font(WarmFont.body(15))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)

                Text(String(localized: "empty.day.hint"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(WarmTheme.primary.opacity(0.35))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: HomeLayoutMetrics.emptyStateTopInset,
                                  leading: WarmSpacing.lg,
                                  bottom: WarmSpacing.sm,
                                  trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    /// section header。可选 `subtitle` 给副标题(如「稍后」分区下方的说明),
    /// 副标题用小字 muted 色,紧跟在标题/count 行下方。其他分区不传 subtitle 即不渲染。
    private func daySectionHeader(title: String, count: Int, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack(spacing: WarmSpacing.xs) {
                Text(title)
                    .font(WarmFont.headline(15))
                // count=0 时不显示数字徽章——空状态已有引导文案，"0"是冗余信息且看着像错误状态
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.primaryDark)
                        .padding(.horizontal, WarmSpacing.xs)
                        .padding(.vertical, WarmSpacing.xxs)
                        .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: WarmSpacing.sm, leading: WarmSpacing.xl, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
    }

    /// 未完成 unscheduled 行。Calendar tab 挂 `draggable`——长按拖到月历某天/时间线排程；
    /// Today tab 无月历可落点，不挂。
    /// 完成态样式（绿勾/删除线）由 WarmTodoCard 根据 `todo.isCompleted` 自行渲染。
    @ViewBuilder
    private func todoRow(_ todo: TodoItemData, index: Int) -> some View {
        let base = unscheduledTodoCardBase(
            todo: todo,
            index: index,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) },
            onDelete: { onDeleteTodo(todo.id) }
        )

        if selectedBottomTab == .calendar {
            base.draggable(todo.id.uuidString) {
                HStack(spacing: WarmSpacing.xxs) {
                    Text(todo.category.emoji)
                    Text(todo.title).lineLimit(1)
                }
                .font(WarmFont.caption(13))
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(Capsule().fill(WarmTheme.secondaryBackground))
            }
        } else {
            base
        }
    }

    /// 已完成无安排任务的行。与 `todoRow` 的差别：
    /// - 不挂 `.draggable`（已完成的不该再拖月历）
    /// 完成态样式（绿勾/删除线）由 WarmTodoCard 根据 `todo.isCompleted` 自行渲染。
    /// 取消完成时 onToggle 会把 isCompleted 翻回 false → 下次重渲染时该行离开「已完成」、
    /// 回到「未安排」分区（unscheduledTodos 重新含它）。
    @ViewBuilder
    private func completedTodoRow(_ todo: TodoItemData, index: Int) -> some View {
        unscheduledTodoCardBase(
            todo: todo,
            index: index,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) },
            onDelete: { onDeleteTodo(todo.id) }
        )
    }

    /// Unscheduled 系卡片（todoRow / completedTodoRow）共用样式：
    /// WarmTodoCard + inset/背景/删除 swipe/入场动画/transition。
    /// 抽出来避免两处复制粘贴——后续改卡片样式只改一处。
    /// 不含 `draggable` 分支——draggable 由调用方按完成态与 tab 自行决定。
    ///
    /// Row tap 用 `Button(action: onTap).buttonStyle(.plain)` 包装而不是 WarmTodoCard 内的
    /// `.onTapGesture`：iOS 26 FB18199844 下顶层 onTapGesture 会吞掉 swipeActions delete 按钮
    /// 的 tap。Button 是显式控件，与 swipeActions 容器级手势天然共存（Apple Reminders 风格），
    /// 内嵌 checkbox Button 由 SwiftUI 分派给最内层 Button，点 checkbox 只触发 toggle。
    @ViewBuilder
    private func unscheduledTodoCardBase(
        todo: TodoItemData,
        index: Int,
        onToggle: @escaping () -> Void,
        onTap: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            WarmTodoCard(
                index: index,
                todo: todo,
                onToggle: onToggle,
                onMoveToBucket: { bucket in onMoveToBucket(todo.id, bucket) },
                onMoveToTomorrow: { onMoveToTomorrow(todo.id) }
            )
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xxs, leading: WarmSpacing.lg, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        // 入场动画:仅淡入,不用 .offset。
        // .offset 会让 row frame 在动画期间持续偏移,List 内部 swipe 追踪与
        // 命中测试会跟着偏移过的 frame 走,出现「刚出现就滑不动 / 滑到一半跳」。
        // 纯 .opacity 不移动 frame,命中区恒定 → swipeActions 稳定。
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .onAppear {
            // 待揭晓的新增条目交给 HomeView 在 sheet dismiss 后统一放动画,
            // 否则动画会在 ConfirmSheet 背后播完(见 plan「根因 3」)。
            guard !pendingRevealIDs.contains(todo.id) else { return }
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    private func occurrenceRow(_ occurrence: TodoOccurrenceData, index: Int) -> some View {
        Button(action: { onOpenTodo(occurrence.todo) }) {
            WarmTodoCard(
                index: index,
                todo: occurrence.todo,
                onToggle: { onToggleOccurrence(occurrence) },
                onMoveToBucket: { bucket in onMoveToBucket(occurrence.todo.id, bucket) },
                onMoveToTomorrow: { onMoveToTomorrow(occurrence.todo.id) },
                onChangeTime: { date in
                    onChangeTime(occurrence.todo.id, date)
                },
                showsTimeBucketMetadata: false,
                dueStatusDisplayMode: .overdueOnly,
                showsInlineTimePrefix: true
            )
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xxs, leading: WarmSpacing.lg, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(occurrence.todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(occurrence.todo.id) ? 1 : 0)
        .onAppear {
            // 待揭晓的新增条目交给 HomeView 在 sheet dismiss 后统一放动画,
            // 否则动画会在 ConfirmSheet 背后播完(见 plan「根因 3」)。
            guard !pendingRevealIDs.contains(occurrence.todo.id) else { return }
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(occurrence.todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }
}

struct HomeCalendarLoadingView: View {
    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                .scaleEffect(1.2)

            Text(String(localized: "home.calendar.loading"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("HomeCalendarLoadingState")
    }
}

struct HomeCalendarErrorView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: WarmSpacing.md) {
                ProductEmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "home.calendar.error.title"),
                    message: String(localized: "home.calendar.error.message")
                )

                Button(action: onRetry) {
                    Label(String(localized: "common.retry"), systemImage: "arrow.clockwise")
                        .font(WarmFont.headline(15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: WarmSize.touch)
                        .background(
                            Capsule()
                                .fill(WarmTheme.primary)
                                .shadow(color: WarmTheme.shadowMedium, radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HomeCalendarRetryButton")
            }
            .padding(.horizontal, WarmSpacing.xl)
            .accessibilityIdentifier("HomeCalendarErrorState")

            Spacer()
        }
    }
}

/// 主页视图 - 温暖手账风格
/// 纸张纹理背景 + 手写展示字体 + 分类色带卡片
