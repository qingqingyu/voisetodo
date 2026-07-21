import SwiftUI

/// 纵向单天 timeline:Calendar tab 选中日的渲染器。
///
/// 按 TimeBucket(Anytime/Morning/Afternoon/Evening)分 4 个 slot,每个 slot:
/// 左侧 bucket 标签 + 中间节点圆点 + 贯穿垂直线 + 右侧卡片列表。
///
/// **本 MVP 范围**:
/// - 静态渲染(不做 drawer ↔ timeline 拖拽,下阶段加)
/// - slot 用 TimeBucket,不用具体小时(下阶段扩)
/// - 卡片不挂 swipe delete(用 tap 进详情页删除代替)
struct DayTimelineView: View {
    let state: HomeCalendarState
    @Binding var cardAppeared: Set<UUID>
    /// drawer 展开时调用方传入实际高度,Timeline 的 ScrollView 用它补偿 bottom inset,
    /// 避免展开的 drawer 遮挡 Evening/Completed section 的最后一张卡片。
    let unscheduledDrawerExpandedHeight: CGFloat
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onOpenTodo: (TodoItemData) -> Void

    /// 左侧 bucket 标签列宽。caption(12) 默认档位下最长 "Afternoon" ~55pt,留余量到 64。
    /// **Dynamic Type**:`WarmFont.caption` 跟随系统字号缩放,AX 档位会放大到 ~2-3x。
    /// 用 `.frame(maxWidth:, alignment: .trailing)` + `lineLimit(2)` 让 label
    /// 在 AX 档位自动换行到 2 行而非被裁切,符合项目「全档位必须可读」硬约束。
    /// 默认档位下最长 "Afternoon" 单行 ~55pt ≤ 64pt,lineLimit(2) 不影响布局。
    private static let labelColumnWidth: CGFloat = 64
    /// 节点圆点直径(跟参考视觉稿一致,12pt)。
    private static let nodeSize: CGFloat = 12
    /// 节点圆点的描边宽度。
    private static let nodeStrokeWidth: CGFloat = 3
    /// 垂直线宽度。
    private static let lineWidth: CGFloat = 2
    /// 空 slot 占位高度——保证时间线视觉不断,即使 bucket 内无卡片。
    /// 取值对齐 WarmTodoCard 最小高度(单行标题 + padding ≈ 48pt)+ VStack spacing,
    /// 让空 slot 与单卡片 slot 在垂直线长度上视觉一致。
    private static let emptySlotHeight: CGFloat = 56
    /// 节点圆点相对 bucket 标签的额外下移量,跟 `WarmFont.caption` 行高对齐,
    /// 让圆点视觉上与第一张卡片的中线对齐。
    private static let nodeVerticalOffset: CGFloat = 2
    /// 已完成卡片相对 timeline 左侧的 leading inset,与 bucketSlot 右列起点对齐:
    /// labelColumnWidth(标签列) + nodeSize(节点列) + WarmSpacing.xxs(label→node 间距)
    /// + WarmSpacing.xs(node→卡片间距)。抽常量避免 layout 参数变化时手算公式失准。
    private static let completedCardLeadingInset: CGFloat =
        labelColumnWidth + nodeSize + WarmSpacing.xs + WarmSpacing.xxs

    var body: some View {
        if state.selectedOccurrences.isEmpty && state.completedOccurrences.isEmpty {
            // 选中日完全空:显示空状态(跟 HomeSelectedDayListView.emptySelectedDayRow 同文案)
            VStack {
                Spacer()
                emptyStateRow
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                        bucketSlot(bucket)
                    }
                    if !state.completedOccurrences.isEmpty || !state.completedUnscheduledTodos.isEmpty {
                        completedSection
                    }
                }
                .padding(.top, WarmSpacing.sm)
                // 底部 inset 组成:HomeLayoutMetrics.listBottomInset(原 VoiceFAB 渐隐区)
                // + drawer 展开态高度(补偿遮挡)。drawer 折叠时此值为 0。
                .padding(.bottom, HomeLayoutMetrics.listBottomInset + unscheduledDrawerExpandedHeight)
            }
        }
    }

    // MARK: - Bucket slot

    /// 渲染单个 bucket 的 timeline slot:左 label + 中 node/line + 右 cards。
    /// bucket 内无卡片时仍渲染 slot(空占位),垂直线视觉连贯。
    @ViewBuilder
    private func bucketSlot(_ bucket: TimeBucket) -> some View {
        let occurrences = state.indexedUncompletedOccurrences(in: bucket)
        let hasCards = !occurrences.isEmpty

        HStack(alignment: .top, spacing: 0) {
            // 左侧 bucket 标签:右对齐,跟节点留 nodeInset 间距
            VStack {
                Text(bucket.localizedTitle)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .frame(maxWidth: Self.labelColumnWidth, alignment: .trailing)
            .frame(height: hasCards ? nil : Self.emptySlotHeight, alignment: .top)
            .padding(.top, WarmSpacing.sm)
            .padding(.trailing, WarmSpacing.xxs)

            // 中间节点 + 垂直线
            timelineColumn

            // 右侧卡片列表
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                if hasCards {
                    ForEach(occurrences, id: \.1.id) { originalIndex, occurrence in
                        occurrenceCard(occurrence, index: originalIndex)
                    }
                } else {
                    Color.clear
                        .frame(height: Self.emptySlotHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, WarmSpacing.xs)
            .padding(.top, WarmSpacing.sm)
            .padding(.bottom, WarmSpacing.sm)
            .padding(.trailing, WarmSpacing.lg)
        }
    }

    /// 中间列:垂直线 + 顶部节点圆点。
    /// 垂直线用 `Color.clear.frame(maxHeight: .infinity)` 撑到 slot 全高,
    /// 节点圆点对齐到 bucket 标签 + 第一张卡片的视觉中线。
    private var timelineColumn: some View {
        ZStack(alignment: .top) {
            // 垂直线贯穿整 slot
            Rectangle()
                .fill(WarmTheme.sketch.opacity(0.25))
                .frame(width: Self.lineWidth)
                .frame(maxHeight: .infinity)
            // 节点圆点:WarmTheme.background 填充 + sketch 描边
            // (背景填充让圆点视觉上"穿过"垂直线,而不是叠加)
            Circle()
                .fill(WarmTheme.background)
                .frame(width: Self.nodeSize, height: Self.nodeSize)
                .overlay(
                    Circle()
                        .stroke(WarmTheme.sketch.opacity(0.6), lineWidth: Self.nodeStrokeWidth)
                )
                .padding(.top, WarmSpacing.sm + Self.nodeVerticalOffset) // 跟 bucket 标签底部对齐
        }
        .frame(width: Self.nodeSize)
    }

    // MARK: - Cards

    /// 单张 occurrence 卡片。复用 WarmTodoCard,但**不挂 swipeActions / draggable**
    /// (不在 List 容器里 + 本阶段不做拖拽)。删除走详情页。
    /// 入场动画复用 cardAppeared set,跟 HomeSelectedDayListView 一致。
    @ViewBuilder
    private func occurrenceCard(_ occurrence: TodoOccurrenceData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: occurrence.todo,
            onToggle: { onToggleOccurrence(occurrence) },
            onTap: { onOpenTodo(occurrence.todo) },
            showsTimeBucketMetadata: false,
            // 已在 timeline 内,bucket 标签冗余;只保留 overdue 红标。
            dueStatusDisplayMode: .overdueOnly
        )
        .cardEntrance(id: occurrence.todo.id, index: index, cardAppeared: $cardAppeared)
    }

    // MARK: - Completed section

    /// 已完成区:跟 HomeSelectedDayListView 的「已完成」section 一致语义——
    /// 当日已完成 occurrence + 全局已完成 unscheduled。放 timeline 末尾,
    /// 用一个 sectionHeader 分隔(不再走 timeline slot 视觉,已完成不占用时段)。
    @ViewBuilder
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xs) {
                Text(String(localized: "home.completed_section_title"))
                    .font(WarmFont.headline(15))
                let totalCount = state.completedOccurrences.count + state.completedUnscheduledTodos.count
                Text("\(totalCount)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.primaryDark)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
            }
            .foregroundColor(WarmTheme.textSecondary)
            .padding(.leading, WarmSpacing.xl)
            .padding(.top, WarmSpacing.sm)
            .padding(.bottom, WarmSpacing.xxs)

            ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                occurrenceCard(occurrence, index: state.uncompletedOccurrences.count + idx)
            }
            ForEach(Array(state.completedUnscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                completedTodoCard(todo, index: state.selectedOccurrences.count + state.unscheduledTodos.count + idx)
            }
        }
    }

    @ViewBuilder
    private func completedTodoCard(_ todo: TodoItemData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) }
        )
        .cardEntrance(id: todo.id, index: index, cardAppeared: $cardAppeared)
        .padding(.leading, Self.completedCardLeadingInset)
        .padding(.trailing, WarmSpacing.lg)
        .padding(.vertical, WarmSpacing.xxs)
    }

    // MARK: - Empty state

    private var emptyStateRow: some View {
        VStack(spacing: WarmSpacing.xs) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(WarmTheme.primary.opacity(0.6))
            Text(String(localized: "empty.day.title"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .accessibilityIdentifier("EmptyState")
    }
}
