import SwiftUI

/// `BucketHourSheet` 触发器。`TimeBucket` 自身非 `Identifiable`,
/// 用 wrapper 让 `.sheet(item:)` 可绑 `TimeBucket?`。
private struct BucketHourSheetItem: Identifiable {
    let bucket: TimeBucket
    var id: String { bucket.rawValue }
}

/// 纵向单天 timeline:Calendar tab 选中日的渲染器。
///
/// 按 TimeBucket(Anytime/Morning/Afternoon/Evening)分 4 个 slot,每个 slot:
/// 左侧 bucket 标签 + 中间节点圆点 + 贯穿垂直线 + 右侧卡片列表。
///
/// **功能范围**:
/// - bucket slot 末尾「+ 设钟点」按钮(仅 morning/afternoon/evening),弹 `BucketHourSheet`
///   给 slot 内未指定钟点的 todo 设钟点
/// - drawer ↔ timeline 双向拖拽:`UnscheduledDrawer` 卡片拖到 bucket slot 排程,
///   timeline 卡片拖回 drawer 清 dueDate
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
    /// slot「+ 设钟点」入口:把选中的 todo + hour/minute Date 传给调用方。
    /// 调用方(`HomeView`)负责合入选中日,写 `dueDate+hasDueTime=true+timeBucket=nil`。
    let onSetTodoHour: (UUID, Date) -> Void
    /// drawer → timeline:unscheduled 卡片拖到 bucket slot 排程。
    /// 调用方(`HomeView`)实现 `assignTodoToBucket`(设 dueDate + bucket)。
    let onDropToBucket: (UUID, TimeBucket) -> Void
    /// 长按 context menu:卡片移到同 day 的另一 bucket。语义上跟 `onDropToBucket` 同业务动作,
    /// 但来源是 contextMenu(非拖拽),独立 callback 不污染 drop 路径的语义。
    let onMoveToBucket: (UUID, TimeBucket) -> Void
    /// 长按 context menu:卡片移到明天(保留 timeBucket/钟点)。
    let onMoveToTomorrow: (UUID) -> Void

    /// 当前打开钟点 sheet 的 bucket(`nil` 表示未打开)。仅 non-anytime bucket 可设。
    @State private var hourSheetItem: BucketHourSheetItem?
    /// 当前拖拽命中的 bucket(`nil` 表示未命中)。bucket slot 用它描边高亮。
    @State private var targetedBucket: TimeBucket?

    /// Section header 垂直 padding。用 `@ScaledMetric(relativeTo: .subheadline)`
    /// 让 padding 跟随字号一起放大 —— AX5 下文字变 ~3x,padding 也变 ~3x,避免
    /// 「字大但间距挤」的失衡。基准 8pt 对齐 SwiftUI 默认 List section header 间距。
    @ScaledMetric(relativeTo: .subheadline) private var sectionVerticalPadding: CGFloat = 8

    /// Section header 与下方卡片/分隔线的间距。同样跟随 Dynamic Type 缩放,
    /// 基准 WarmSpacing.xs(8pt)。独立于 `sectionVerticalPadding` 是因为这两段
    /// 语义不同:sectionVerticalPadding 是 header 内部上下边距,
    /// headerToContentGap 是 header 到内容的过渡空间。
    @ScaledMetric(relativeTo: .subheadline) private var headerToContentGap: CGFloat = WarmSpacing.xs

    var body: some View {
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $hourSheetItem) { item in
            BucketHourSheet(
                bucket: item.bucket,
                candidates: state.indexedUncompletedOccurrences(in: item.bucket)
                    .compactMap { _, occurrence -> TodoItemData? in
                        occurrence.todo.hasDueTime ? nil : occurrence.todo
                    },
                onApply: { id, date in
                    onSetTodoHour(id, date)
                    hourSheetItem = nil
                },
                onDismiss: { hourSheetItem = nil }
            )
        }
    }

    // MARK: - Bucket slot

    /// 渲染单个 bucket 的 timeline slot:水平 section header + 下方卡片列表。
    /// 用户原话:「改成水平 section header:标签左对齐占满整行,下面挂该时段的任务卡片,
    /// 去掉那条竖直时间线(它只是装饰,没承担功能)。这样和 Unscheduled 的分组逻辑一致,
    /// 整个页面只有一套分组模式。」
    ///
    /// **不挂图标**(☀️/🌤/🌙):Morning/Afternoon/Evening 本身无歧义,任务卡片左侧
    /// 已有分类彩色图标,时段属于结构层,应该更安静,不该再引入第二套图标系统。
    @ViewBuilder
    private func bucketSlot(_ bucket: TimeBucket) -> some View {
        let occurrences = state.indexedUncompletedOccurrences(in: bucket)
        let hasCards = !occurrences.isEmpty
        // Anytime 无钟点概念;只对 morning/afternoon/evening 显示「+ 设钟点」入口。
        // 只在 slot 内有「未指定钟点的卡片」时显示按钮,避免 candidates 空时让用户白点。
        let hasHourlessCard = bucket != .anytime
            && occurrences.contains { _, occurrence in !occurrence.todo.hasDueTime }

        VStack(alignment: .leading, spacing: headerToContentGap) {
            // Section header:左对齐 bucket 标签 + 右侧可选「+ 设钟点」入口。
            // 字体用语义 token(.subheadline + .semibold + .secondary),不写死 .system(size:),
            // 跟随 Dynamic Type 全档位缩放。.lineLimit(nil) + .fixedSize 让 AX5 下整词换行
            // 而非字符截断(避免 "Aftern/oon" 这种尴尬断词)。
            HStack(alignment: .firstTextBaseline, spacing: WarmSpacing.sm) {
                Text(bucket.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WarmSpacing.sm)
                if hasHourlessCard {
                    setHourButton(bucket)
                }
            }
            .padding(.vertical, sectionVerticalPadding)

            // 卡片列表或空 bucket 占位。
            // 空状态不用固定高度 —— 让内容(分隔线 + padding)决定高度,
            // 避免大字号下 header 被外层固定 frame 压扁。
            if hasCards {
                VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                    ForEach(occurrences, id: \.1.id) { originalIndex, occurrence in
                        occurrenceCard(occurrence, index: originalIndex)
                    }
                }
            } else {
                // 空 bucket 的「细条」视觉:一条淡淡的水平分隔线。
                // 不用 Color.clear 占位 —— 用户反馈空时段仍需视觉锚点(否则看起来像漏渲染)。
                Rectangle()
                    .fill(WarmTheme.sketch.opacity(0.25))
                    .frame(height: 0.5)
                    .padding(.vertical, WarmSpacing.xs)
            }
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.bottom, WarmSpacing.sm)
        // drawer → timeline 拖拽落点:把 unscheduled 卡片排到当前 bucket。
        // Anytime slot 也接受 drop(用户可以把任务排到「随时」)。
        // **与 DragTargetOverlay 的协同**:drag session 进行中(isTaskDragging=true)
        // HomeView 顶层会盖一层 DragTargetOverlay 作 drop target。当 overlay 完全覆盖本 slot 时,
        // drop 命中 overlay;但 overlay 几何与本 slot 边缘可能不重合,drop 命中本 slot 仍走这里。
        // 两路 drop 最终都调用 `onDropToBucket`(同业务动作),不会数据冲突,
        // 但 haptic 反馈路径不同:overlay 走 DropStrip 的 HapticFeedback.success,
        // 本 slot 不触发 haptic。用户感知上可能"丢一下振动",非功能性 bug。
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            onDropToBucket(id, bucket)
            return true
        } isTargeted: { targeted in
            withAnimation(WarmAnimation.springFast) {
                targetedBucket = targeted ? bucket : (targetedBucket == bucket ? nil : targetedBucket)
            }
        }
        .overlay {
            if targetedBucket == bucket {
                // 拖拽命中态高亮:描边整个 slot 范围,跟外层 padding 对齐避免视觉溢出。
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .stroke(WarmTheme.primary, lineWidth: 2)
                    .padding(.horizontal, WarmSpacing.xxs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 「+ 设钟点」入口:打开 `BucketHourSheet`。candidates 由 `hourSheet` 计算。
    /// 视觉保持小标签风格,避免抢 bucket 标签焦点。
    /// 字号跟随 Dynamic Type(.caption 是语义 token),不写死 size。
    private func setHourButton(_ bucket: TimeBucket) -> some View {
        Button {
            hourSheetItem = BucketHourSheetItem(bucket: bucket)
        } label: {
            Label(String(localized: "home.timeline.set_hour"), systemImage: "plus.circle")
                .font(.caption)
                .foregroundColor(WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "a11y.timeline.set_hour"))
    }

    // MARK: - Cards

    /// 单张 occurrence 卡片。复用 WarmTodoCard,挂 `.draggable` 支持反向拖回 drawer。
    /// 删除走详情页(不挂 swipeActions,本阶段简化)。
    /// 入场动画复用 cardAppeared set,跟 HomeSelectedDayListView 一致。
    ///
    /// 若卡片已设钟点(`todo.hasDueTime=true`),在卡片下方显示钟点小标签,
    /// 让用户在 timeline 内能扫到具体时间(参考 HTML 视觉)。
    @ViewBuilder
    private func occurrenceCard(_ occurrence: TodoOccurrenceData, index: Int) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            WarmTodoCard(
                index: index,
                todo: occurrence.todo,
                onToggle: { onToggleOccurrence(occurrence) },
                onTap: { onOpenTodo(occurrence.todo) },
                onMoveToBucket: { bucket in onMoveToBucket(occurrence.todo.id, bucket) },
                onMoveToTomorrow: { onMoveToTomorrow(occurrence.todo.id) },
                showsTimeBucketMetadata: false,
                // 已在 timeline 内,bucket 标签冗余;只保留 overdue 红标。
                dueStatusDisplayMode: .overdueOnly
            )
            if occurrence.todo.hasDueTime, let due = occurrence.todo.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(due, format: .dateTime.hour().minute())
                        .font(WarmFont.caption(11))
                }
                .foregroundColor(WarmTheme.primaryDark)
                .padding(.leading, WarmSpacing.sm)
                .accessibilityLabel(String(localized: "a11y.timeline.due_time"))
            }
        }
        .cardEntrance(id: occurrence.todo.id, index: index, cardAppeared: $cardAppeared)
        .draggable(occurrence.todo.id.uuidString) {
            HStack(spacing: WarmSpacing.xxs) {
                Text(occurrence.todo.category.emoji)
                Text(occurrence.todo.title).lineLimit(1)
            }
            .font(WarmFont.caption(13))
            .padding(.horizontal, WarmSpacing.sm)
            .padding(.vertical, WarmSpacing.xs)
            .background(Capsule().fill(WarmTheme.secondaryBackground))
        }
    }

    // MARK: - Completed section

    /// 已完成区:跟 HomeSelectedDayListView 的「已完成」section 一致语义——
    /// 当日已完成 occurrence + 全局已完成 unscheduled。放 timeline 末尾,
    /// 用一个 sectionHeader 分隔(不再走 timeline slot 视觉,已完成不占用时段)。
    ///
    /// header 字体与 bucketSlot 的 section header 保持一致(.subheadline.weight(.semibold) +
    /// .secondary),整个 timeline 只有一套 header 样式,避免 AX5 下两种 header 缩放系数不同
    /// 形成「一放大一不放大」的撕裂。
    @ViewBuilder
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xs) {
                Text(String(localized: "home.completed_section_title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                let totalCount = state.completedOccurrences.count + state.completedUnscheduledTodos.count
                Text("\(totalCount)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.primaryDark)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
            }
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
