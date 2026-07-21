import SwiftUI

/// 网格模式（`CalendarDisplayMode.grid`）的月历单格：与 `HomeMonthDayButton`（列表模式）并列。
///
/// 与 `HomeMonthDayButton` 的差异：
/// - **列表模式**：每格只渲染数字 + 单圆点（信息密度低，配合下方任务列表读详情）。
/// - **网格模式**：每格直接渲染数字 + ≤2 个事件条 + `+N`，事件概览不需要点开列表。
///
/// 共用契约（必须对齐 `HomeMonthDayButton`）：
/// - 整格都是点击热区（点击 → `onSelect(date)`）
/// - 拖拽 drop：从 Unscheduled 拖任务到格子 → `onDropTodo(id)`
/// - accessibilityLabel 朗读完整状态（视觉信息翻译成文字）
///
/// 数据来源：`dayState.occurrences` 已按天分组，`todo.category` 给配色。
///
/// 命名对齐 `HomeMonthDayButton`（同为 Button 后缀）：虽然 SwiftUI 内部是 Button，
/// 但外部类型名按项目约定「日期格 = Day/Grid Button」命名，便于按 Button 后缀检索。
struct HomeMonthGridButton: View {
    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void
    var onDropTodo: ((UUID) -> Void)? = nil
    // 默认值与 HomeMonthDayButton 同步（WarmSpacing.xxxl = 48pt）——只在"未通过 HomeMonthHeaderView
    // 调用"的预览/测试场景下使用；正式路径 dayCell(for:) 永远会传 dayRowHeight（grid+月至少 80pt）。
    var rowHeight: CGFloat = WarmSpacing.xxxl
    /// 单格最多渲染几个事件条。超过的显示 `+N`。
    private static let maxVisibleEvents = 2

    @State private var isDropTargeted = false

    /// 日数字配色（与 `HomeMonthDayButton` 同色系）：选中白 / 今天 primaryDark /
    /// 跨月补齐 textMuted / 其他 textPrimary。命名用 dayNumber 而非 category，
    /// 因为这里只决定数字的颜色——事件条背景色由 `WarmTheme.color(for:)` 单独算。
    private var dayNumberColor: Color {
        dayState.isSelected ? .white :
        (dayState.isToday ? WarmTheme.primaryDark :
        (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))
    }

    var body: some View {
        // 单次计算 visibleEvents + extraCount + accessibilityLabel：避免在 ForEach / `+N` /
        // VoiceOver 三处重复访问 computed property（过滤+切片）。月视图下 LazyVGrid 重绘时
        // 会逐格调用 body,若 occurrences 大(>10) 且每次都算三遍,卡顿会被放大。
        let visible = visibleEvents
        let extra = extraEventsCount(from: visible)
        let voiceOverText = gridAccessibilityLabel(from: visible)
        return Button {
            onSelect(dayState.date)
        } label: {
            // VStack 左对齐：数字顶部对齐，事件条堆在下方。
            // 事件条按 category 截断显示；超过 maxVisibleEvents 显示 `+N`。
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                dayNumberView
                // id 用 occurrence.id（稳定标识），不要用 .enumerated() + offset——
                // offset 在 occurrences 数组变化时不稳定，会导致 SwiftUI view diff 错配，
                // 触发不必要的重绘/动画异常。occurrence.id 已是 Identifiable 形态。
                ForEach(visible, id: \.id) { occurrence in
                    eventBar(occurrence)
                }
                if let extraCount = extra {
                    Text("+\(extraCount)")
                        .font(WarmFont.caption(9))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: rowHeight, alignment: .top)
            // 跨月补齐日：整格降低存在感，不灰化事件条（仍可见，只是数字弱）。
            .opacity(dayState.isCurrentMonth ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        // grid 模式视觉已显示事件 title（≤2 条），VoiceOver 必须把 title 也读出来——
        // 否则盲人用户只能听到 "5 日 3 项待办"，不知道是哪 3 项。
        // list 模式仍走 `VoiceOverLabel.build(for:)`（视觉只有圆点，没有 title 信息要翻译）。
        .accessibilityLabel(voiceOverText)
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthGridCell_\(dayState.date.formatted(.dateTime.year().month().day()))")
        .dropDestination(for: String.self) { items, _ in
            // 无回调时返回 false：让系统知道 drop 未被处理（避免视觉反馈成功但无副作用）。
            guard let callback = onDropTodo,
                  let idString = items.first,
                  let id = UUID(uuidString: idString) else { return false }
            callback(id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WarmTheme.primary, lineWidth: 2)
            }
        }
        .animation(WarmAnimation.springFast, value: isDropTargeted)
    }

    // MARK: - Subviews

    /// 顶部日数字：选中实心圆 / 今天浅圆 / 其他无背景。
    /// 与 `HomeMonthDayButton` 的视觉语言一致（同色系、同选中态），只是位置从居中改成左上。
    private var dayNumberView: some View {
        let circleDiameter: CGFloat = 22
        return ZStack {
            if dayState.isSelected {
                Circle().fill(WarmTheme.primary)
            } else if dayState.isToday {
                Circle().fill(WarmTheme.primary.opacity(0.18))
            }
            Text("\(dayState.dayNumber)")
                .font(WarmFont.headlineFixed(13))
                .foregroundColor(dayNumberColor)
                // fixedSize:绕开 SwiftUI 对固定字号 Text 的 Dynamic Type layout 补偿(AX 档位下
                // intrinsic width 被放大 ×2~3 → 压进 22pt circleDiameter 触发 .tail truncation →
                // 显示「…」)。详见 HomeMonthDayButton 同位置注释。
                .fixedSize()
        }
        .frame(width: circleDiameter, height: circleDiameter)
    }

    /// 单条事件条：分类色背景 + 截断 title。
    /// 已完成的降低不透明度（视觉上"过去"），但不加删除线——网格密度下删除线会糊。
    private func eventBar(_ occurrence: TodoOccurrenceData) -> some View {
        let color = WarmTheme.color(for: occurrence.todo.category)
        return Text(occurrence.todo.title)
            .font(WarmFont.caption(9))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 14)
            .background(color.opacity(occurrence.isCompleted ? 0.4 : 0.85))
            .cornerRadius(3)
    }

    // MARK: - Data slicing

    /// 格子上要渲染的 events：优先未完成（信息密度更高，与 `HomeMonthDayButton`
    /// 圆点逻辑"全完成 textMuted / 有未完成 primary"同语义）。已完成的事件折叠进 `+N`。
    ///
    /// **未完成不足时用已完成补齐**：保证格子里有事件可见，而不是显示空（信息丢失）。
    /// 副作用:visible 可能含 1 未完成 + 1 已完成,但 `+N` 只算未完成余量——
    /// 用户视觉看到 2 条但 +N 为 nil,可能误以为"今天 2 项"而实际可能更多。
    /// 取舍:宁可让用户"看到已完成"也不要让格子空,真正的余量请切 list 视图查看。
    private var visibleEvents: [TodoOccurrenceData] {
        let uncompleted = dayState.occurrences.filter { !$0.isCompleted }
        // 未完成不足 maxVisibleEvents 时用已完成补齐——保证格子里有事件可见，
        // 而不是显示空（信息丢失）。优先顺序：未完成 > 已完成（按 dayState.occurrences 原顺序）。
        if uncompleted.count >= Self.maxVisibleEvents {
            return Array(uncompleted.prefix(Self.maxVisibleEvents))
        }
        let completed = dayState.occurrences.filter { $0.isCompleted }
        let needed = Self.maxVisibleEvents - uncompleted.count
        return uncompleted + Array(completed.prefix(needed))
    }

    /// `+N` 计数：与 visibleEvents 同口径（未完成优先）。
    /// 只显示"还有 N 个未完成未渲染"——避免把已完成历史任务挤进 +N 误导用户。
    ///
    /// **设计取舍**：visible 可能含 1 条已完成（当未完成不足 2 时补齐）。此时 +N 不含已完成的
    /// 未渲染余量——用户看到的"事件条 1 未完成 + 1 已完成"已传达"过去有任务完成"的事实,
    /// +N 只关心"还有几个未完成需要处理"。若用户切到 list 视图才能看到所有已完成事件。
    /// 参数 `visible` 由调用方在 body 顶部一次性算好后传入,避免重复访问 `visibleEvents`。
    private func extraEventsCount(from visible: [TodoOccurrenceData]) -> Int? {
        let uncompletedTotal = dayState.occurrences.filter { !$0.isCompleted }.count
        let uncompletedVisible = visible.filter { !$0.isCompleted }.count
        let count = uncompletedTotal - uncompletedVisible
        return count > 0 ? count : nil
    }

    /// VoiceOver 文案：基于 `VoiceOverLabel.build` 的基础描述 + 列出可见事件 title。
    /// 视觉层显示的事件 title 必须翻译到无障碍文案,否则盲人用户只听到 "5 日 3 项待办"
    /// 不知道是哪几项。`+N` 部分通过基础描述里的"todo_count"朗读。
    /// 参数 `visible` 由调用方在 body 顶部一次性算好后传入,避免重复访问 `visibleEvents`。
    private func gridAccessibilityLabel(from visible: [TodoOccurrenceData]) -> String {
        let base = VoiceOverLabel.build(for: dayState)
        let titles = visible.map { $0.todo.title }
        guard !titles.isEmpty else { return base }
        let list = titles.joined(separator: String(localized: "a11y.day.separator"))
        return base + String(localized: "a11y.day.separator") + list
    }
}
