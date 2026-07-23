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

    var body: some View {
        List {
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if state.selectedOccurrences.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(Array(state.sortedUncompletedOccurrences.enumerated()), id: \.element.id) { index, occurrence in
                        occurrenceRow(occurrence, index: index)
                    }
                }
            }

            // 「未安排」分区:无 dueDate 的任务,排在已完成之前——
            // 用户关注优先级:未完成(有时间) > 未安排(待排期) > 已完成(历史)。
            if !state.unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(state.unscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        todoRow(todo, index: state.selectedOccurrences.count + idx)
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.week.unscheduled"),
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
                        completedTodoRow(todo, index: state.selectedOccurrences.count + state.unscheduledTodos.count + idx)
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
            onTap: onTap,
            onMoveToBucket: { bucket in onMoveToBucket(todo.id, bucket) },
            onMoveToTomorrow: { onMoveToTomorrow(todo.id) }
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
            onMoveToBucket: { bucket in onMoveToBucket(occurrence.todo.id, bucket) },
            onMoveToTomorrow: { onMoveToTomorrow(occurrence.todo.id) },
            showsTimeBucketMetadata: false,
            dueStatusDisplayMode: .overdueOnly,
            showsInlineTimePrefix: true
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
