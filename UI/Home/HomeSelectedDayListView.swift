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
    /// 时间 chip 点击后的改时间入口。(hasDueTime, dueDate, timeBucket) 由 `TimeEditPopover`
    /// 提交时填好,本回调负责写库。改时间 popover 只用于「今日 Section」的 occurrence,
    /// 待定日期组走自己的「选日期」按钮(Commit 6)。
    let onChangeTime: (UUID, Bool, Date?, TimeBucket?) -> Void
    /// 「待定日期」分组「选日期」按钮提交后写库。参数是用户选定的 startOfDay,
    /// 调用方按 hasDueTime=false + timeBucket=nil 写入(剥离时段,只保留日期)。
    let onPickDate: (UUID, Date) -> Void
    /// 「没能识别」分组「重新解析」按钮入口。把 rawTranscript 再喂一遍 extractor,
    /// 成功 → 替换原 todo 为 .parsed;失败 → 保留原 todo + toast。
    let onReextract: (UUID) -> Void
    /// 正在重新解析的 todo id 集合(来自 AppCoordinator.reextractingTodoIDs)。
    /// 用于驱动 UnparsedTodoCard 的按钮 disabled + ProgressView,防连点。
    var reextractingTodoIDs: Set<UUID> = []

    var body: some View {
        List {
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if state.selectedOccurrences.isEmpty
                            && state.pendingDateTodos.isEmpty
                            && state.unparsedTodos.isEmpty
                            && state.unscheduledTodos.isEmpty {
                    emptySelectedDayRow
                } else {
                    todaySectionBody
                }
            }

            // 「待定日期」分区:有时间信号(timeBucket 或 dueHint)但没具体日期。
            // 用 PendingDateTodoRow:右侧珊瑚色「选日期」按钮 + .loose chip 显示「时段 · 未定哪天」。
            if !state.pendingDateTodos.isEmpty {
                Section {
                    ForEach(Array(state.pendingDateTodos.enumerated()), id: \.element.id) { idx, todo in
                        PendingDateTodoRow(
                            todo: todo,
                            index: state.pendingDateTodos.startIndex + idx,
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

            // 「未定时间」分区:完全无时间信号的待排期货(原「未安排」,语义收紧后改名)。
            // 排在已完成之前——用户关注优先级:未完成(有时间) > 待定日期 > 没能识别 > 未定时间 > 已完成(历史)。
            if !state.unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(state.unscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        todoRow(todo, index: state.selectedOccurrences.count + state.pendingDateTodos.count + state.unparsedTodos.count + idx)
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.undated.section"),
                        count: state.unscheduledTodos.count
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
                        // index 延续「已完成 occurrence」之后,跨过 today / pendingDate / unparsed / unscheduled
                        // 各 section 的行数,避免 a11y identifier 与前面 section 的行号撞号。
                        completedTodoRow(todo, index: state.selectedOccurrences.count
                                        + state.pendingDateTodos.count
                                        + state.unparsedTodos.count
                                        + state.unscheduledTodos.count + idx)
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
                .listRowInsets(EdgeInsets(top: tierIndex == 0 ? WarmSpacing.xxs : WarmSpacing.sm,
                                          leading: WarmSpacing.lg,
                                          bottom: WarmSpacing.xxs,
                                          trailing: WarmSpacing.lg))
                .listRowBackground(Color.clear)

            ForEach(Array(group.items.enumerated()), id: \.element.id) { inTierIndex, occurrence in
                occurrenceRow(occurrence, index: occurrenceCountSoFar(tierIndex) + inTierIndex)
            }
        }
    }

    /// tier-label 行:细分隔线 + 小标签(整天 / 上午 / 下午 / 晚上 / 按时间)。
    /// 字号 11.5pt + 字重 750 + 0.8 tracking,颜色 textMuted,与 HTML 设计稿 line 178-186 对齐。
    /// 不挂 swipeActions / listRowSeparator 都隐藏 —— 与 card 行视觉解耦,
    /// 不让 List 把它当数据 row 渲染。
    @ViewBuilder
    private func tierLabelRow(_ tier: TodayTier) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(tier.localizedLabel)
                .font(WarmFont.caption(11.5))
                .tracking(0.8)
                .foregroundColor(WarmTheme.textMuted)
            Rectangle()
                .fill(WarmTheme.sketch.opacity(0.6))
                .frame(height: 1)
        }
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

    private var emptySelectedDayRow: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: selectedBottomTab == .today ? "empty.day.today" : "empty.day.title"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(Color.white.opacity(0.86))
                .shadow(color: WarmTheme.shadowLight, radius: 5, x: 0, y: 2)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("EmptyState")
    }

    private func daySectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(title)
                .font(WarmFont.headline(15))
            // count=0 时不显示数字徽章——空状态已有引导文案，"0"是冗余信息且看着像错误状态
            if count > 0 {
                Text("\(count)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.primaryDark)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
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
                onChangeTime: { hasDueTime, dueDate, bucket in
                    onChangeTime(occurrence.todo.id, hasDueTime, dueDate, bucket)
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
