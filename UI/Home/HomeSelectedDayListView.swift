import SwiftUI

struct HomeSelectedDayListView: View {
    let state: HomeCalendarState
    let selectedBottomTab: BottomTab
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onDeleteTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    let onMoveUnscheduled: (IndexSet, Int) -> Void

    /// Unscheduled 重排编辑态。激活时行显示原生三横线把手（区别于"拖到月历"的胶囊）。
    /// 由 Unscheduled 分区头的「排序/完成」按钮切换。
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if state.selectedOccurrences.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                        let occurrences = state.indexedUncompletedOccurrences(in: bucket)
                        if !occurrences.isEmpty {
                            timeBucketHeader(bucket)
                            ForEach(occurrences, id: \.1.id) { originalIndex, occurrence in
                                occurrenceRow(occurrence, index: originalIndex)
                            }
                        }
                    }
                }
            } header: {
                daySectionHeader(title: state.selectedDateTitle, count: state.uncompletedOccurrences.count)
            }

            // 「已完成」分区 = 当日 occurrence 的已完成 + 全局无安排任务的已完成。
            // 两者都已完成态、都不应再触发重排/拖月历，统一放进同一分区。
            if !state.completedOccurrences.isEmpty || !state.completedUnscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(occurrence, index: state.uncompletedOccurrences.count + idx)
                    }
                    ForEach(Array(state.completedUnscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        // index 偏移要避开所有已用的范围（时段 occurrence + 已完成 occurrence + 未完成 unscheduled），
                        // 保证 accessibility id / cardAppeared 动画 delay 不撞号。
                        completedTodoRow(todo, index: state.selectedOccurrences.count + state.unscheduledTodos.count + idx)
                    }
                } header: {
                    let totalCount = state.completedOccurrences.count + state.completedUnscheduledTodos.count
                    daySectionHeader(title: String(localized: "home.completed_section_title"), count: totalCount)
                }
            }

            if !state.unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(state.unscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        todoRow(todo, index: state.selectedOccurrences.count + idx)
                    }
                    .onMove(perform: onMoveUnscheduled)
                } header: {
                    unscheduledSectionHeader
                }
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollContent)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollIndicators)
        .accessibilityIdentifier("TodoList")
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

    /// Unscheduled 分区头：复用 daySectionHeader 的标题 + 数字徽章，尾部加「排序/完成」切换。
    /// 排序按钮仅在 ≥2 条时出现（1 条无从重排）；点击进/出编辑态，行显示原生三横线把手。
    private var unscheduledSectionHeader: some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(String(localized: "home.week.unscheduled"))
                .font(WarmFont.headline(15))
            if state.unscheduledTodos.count > 0 {
                Text("\(state.unscheduledTodos.count)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.primaryDark)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
            }

            Spacer()

            if state.unscheduledTodos.count > 1 {
                Button {
                    withAnimation(WarmAnimation.springFast) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                } label: {
                    Text(String(localized: editMode.isEditing
                                ? "home.unscheduled.reorder_done"
                                : "home.unscheduled.reorder"))
                        .font(WarmFont.headline(13))
                        .foregroundColor(WarmTheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ReorderUnscheduledButton")
            }
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: WarmSpacing.sm, leading: WarmSpacing.xl, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
    }

    private func timeBucketHeader(_ bucket: TimeBucket) -> some View {
        Text(bucket.localizedTitle)
            .font(WarmFont.caption(12))
            .foregroundColor(WarmTheme.textMuted)
            .textCase(nil)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: WarmSpacing.sm, leading: WarmSpacing.xl, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("TimeBucketHeader_\(bucket.rawValue)")
    }

    /// 未完成 unscheduled 行。挂 `draggable`（拖到月历）或编辑态三横线把手。
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

        // 编辑态只重排（原生三横线把手）；非编辑态才挂"拖到月历"的胶囊 draggable——
        // 两个操作从起手就区分开，不再共用同一预览。
        if editMode.isEditing {
            base
        } else {
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
        }
    }

    /// 已完成无安排任务的行。与 `todoRow` 的差别：
    /// - 不挂 `.draggable`（已完成的不该再拖月历）
    /// - 不参与编辑态重排（Unscheduled 分区的 `.onMove` 只对未完成行生效，
    ///   completedTodoRow 在「已完成」分区，本来就不在 .onMove 作用域内）
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
    /// 不含 `draggable` / `editMode` 分支，那两个由调用方按完成态自行决定。
    @ViewBuilder
    private func unscheduledTodoCardBase(
        todo: TodoItemData,
        index: Int,
        onToggle: @escaping () -> Void,
        onTap: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: onToggle,
            onTap: onTap
        )
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
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(todo.id) ? 0 : 20)
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
        WarmTodoCard(
            index: index,
            todo: occurrence.todo,
            onToggle: { onToggleOccurrence(occurrence) },
            onTap: { onOpenTodo(occurrence.todo) },
            showsTimeBucketMetadata: false,
            // 已在按天分组的分区里，"Today" 尾标冗余；只保留"过期"红标。
            dueStatusDisplayMode: .overdueOnly
        )
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
        .offset(y: cardAppeared.contains(occurrence.todo.id) ? 0 : 20)
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
