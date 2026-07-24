import SwiftUI

/// 月历网格单格:数字 + N 条纯色 Capsule 事件概览 + `+N`。
/// N 由 `HomeMonthHeaderView` 的注水法分配器决定(0...`HomeLayoutMetrics.gridMaxBarsPerCell` = 6),
/// 忙周分配更多条,空周更少;默认 3 仅供预览/测试使用。
/// 契约:
/// - 整格都是点击热区(点击 → `onSelect(date)`)
/// - 拖拽 drop:从 Unscheduled 拖任务到格子 → `onDropTodo(id)`
/// - accessibilityLabel 朗读完整状态(视觉信息翻译成文字,含可见事件 title,数量由分配器决定)
///
/// 数据来源:`dayState.occurrences` 已按天分组,`todo.category` 给配色。
struct HomeMonthGridButton: View {
    /// 提取为静态:避免 body 内每格每条事件都重建 Calendar.current(月视图 42 格 × N 事件/帧)。
    /// 用 .current 而非 gregorian 是为了尊重用户时区(小时标签应匹配本地时间)。
    private static let calendar = Calendar.current

    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void
    var onDropTodo: ((UUID) -> Void)? = nil
    var rowHeight: CGFloat = WarmSpacing.xxxl
    /// 由注水法分配器决定:忙周显示更多条,空周更少。默认 3 用于预览。
    /// 调用方(HomeMonthHeaderView)传入的值由 `HomeLayoutMetrics.allocateRowHeights` 保证
    /// 不超过 `gridMaxBarsPerCell`(=6)。调用方在传入前必须自行夹紧——
    /// SwiftUI View struct 的 init 不触发 didSet,Swift memberwise init 也不夹紧,
    /// 因此 clamping 责任在调用方(单一来源:HomeMonthHeaderView.dayCell)。
    var maxVisibleEvents: Int = 3

    @State private var isDropTargeted = false

    private var dayNumberColor: Color {
        dayState.isSelected ? .white :
        (dayState.isToday ? WarmTheme.primaryDark :
        (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))
    }

    var body: some View {
        let (visible, overflow) = slicedEvents()
        let voiceOverText = gridAccessibilityLabel(from: visible, overflow: overflow)
        return Button {
            onSelect(dayState.date)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                dayNumberView
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, occurrence in
                    eventBar(occurrence, isLast: idx == visible.count - 1, overflow: overflow)
                }
                Spacer(minLength: 0)
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: rowHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(dayState.isCurrentMonth ? WarmTheme.cardBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(WarmTheme.sketch.opacity(dayState.isCurrentMonth ? 0.12 : 0), lineWidth: 1)
            )
            .opacity(dayState.isCurrentMonth ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverText)
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthGridCell_\(dayState.date.formatted(.dateTime.year().month().day()))")
        .dropDestination(for: String.self) { items, _ in
            // 跨月补齐日(isCurrentMonth=false)视觉上被 opacity 0.5 弱化,
            // 用户不会预期它可接收拖放;同时任务被排到"可见但非当月"的格子会误导。
            // 这里直接拒绝 drop,让系统把拖拽事件回退给下层视图。
            guard dayState.isCurrentMonth,
                  let callback = onDropTodo,
                  let idString = items.first,
                  let id = UUID(uuidString: idString) else { return false }
            callback(id)
            return true
        } isTargeted: { targeted in
            // 跨月格不显示 drop 高亮:与 dropDestination 的 accept 逻辑一致,
            // 避免视觉暗示"可放"但实际被拒绝。
            isDropTargeted = targeted && dayState.isCurrentMonth
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(WarmTheme.primary, lineWidth: 2)
            }
        }
        .animation(WarmAnimation.springFast, value: isDropTargeted)
    }

    // MARK: - Subviews

    private var dayNumberView: some View {
        HStack(spacing: 2) {
            Text("\(dayState.dayNumber)")
                .font(WarmFont.mono(11))
                .foregroundColor(dayNumberColor)
                // 选中/今天加胶囊背景:选中=primary 实色+白字;今天=浅 primary+primaryDark 字。
                // 不加背景时选中日白字会消失在白色卡片底上。
                .padding(.horizontal, dayState.isSelected || dayState.isToday ? 4 : 0)
                .background(
                    Capsule().fill(
                        dayState.isSelected ? WarmTheme.primary :
                        dayState.isToday ? WarmTheme.primary.opacity(0.15) :
                        Color.clear
                    )
                )
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    /// 单条事件文字条:浅色分类背景 + 深色文字 + 可选时间前缀 + 可选 +N 尾标。
    /// 高度固定 14pt(对齐 HTML .bar 样式),Overflow +N 嵌入最后一条尾部。
    /// 已完成态用分类色 40% 透明(非纯白 secondaryBackground):格子底色是 cardBackground(白),
    /// 若已完成条也用白底会完全融入背景不可见。保留分类色相让用户仍能辨认"过去的事属于哪类"。
    ///
    /// 字体用 `captionFixed` 不响应 Dynamic Type:月历格事件条是"预览类 UI"(用户点开看详情),
    /// 不是主读内容;固定 9pt 让字号缩放不再影响布局判定,与 Apple Calendar 日期数字一致。
    /// 取舍:违反 iOS HIG「内容应跟随 Dynamic Type」建议,但与 `headlineFixed`/`mono` 同模式。
    private func eventBar(_ occurrence: TodoOccurrenceData, isLast: Bool, overflow: Int?) -> some View {
        let categoryBg = WarmTheme.categoryBackground(for: occurrence.todo.category)
        let categoryTx = WarmTheme.categoryTextColor(for: occurrence.todo.category)
        // 已完成:背景降透明度到 0.4(保留色相),文字用 textMuted 与未完成区分。
        let bg = occurrence.isCompleted ? categoryBg.opacity(0.4) : categoryBg
        let tx = occurrence.isCompleted ? WarmTheme.textMuted : categoryTx
        return HStack(spacing: 2) {
            if occurrence.todo.hasDueTime, let dueDate = occurrence.todo.dueDate {
                // 只显示小时(两位数)省空间:"09:55" → "09",给任务名留更多宽度。
                Text(verbatim: String(format: "%02d", Self.calendar.component(.hour, from: dueDate)))
                    .font(WarmFont.mono(8))
                    .fixedSize()
            }
            // 优先完整显示标题;格子宽容不下时才 tail 截断。
            // 旧实现只挂 lineLimit + truncationMode,SwiftUI HStack 会给 Text 分配"压缩后"宽度,
            // 即使事件条实际还有水平余量也会过早出现"…"。ViewThatFits 会以无外部宽度约束测量
            // 每个候选的理想尺寸,选第一个放得下的——第一个候选(无 truncationMode、lineLimit(1))
            // 的理想尺寸即单行自然宽度,放得下就消除伪截断;放不下回退到带 tail 截断的第二个候选。
            // 与"文本截断零容忍"约定一致:绝不优先选择截断布局。
            // 注意:候选不能挂 fixedSize(horizontal: true, vertical: false)——fixedSize 会强制
            // 候选报告固定宽度突破父约束,ViewThatFits 会误判为"永远 fit",导致长标题溢出 capsule。
            ViewThatFits(in: .horizontal) {
                Text(occurrence.todo.title)
                    .font(WarmFont.captionFixed(9))
                    .lineLimit(1)
                Text(occurrence.todo.title)
                    .font(WarmFont.captionFixed(9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let overflow, isLast {
                Text("+\(overflow)")
                    .font(WarmFont.mono(8))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 3)
        .frame(height: HomeLayoutMetrics.gridBarHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(bg))
        .foregroundColor(tx)
    }

    // MARK: - Data slicing

    /// 切片 + 排序:4 级规则(对齐 HTML 参考稿 sortT)。
    /// 1. 未完成 → 已完成
    /// 2. 有钟点的按 dueDate 升序(09:00 在 14:00 前)
    /// 3. 无钟点的排所有有钟点的之后
    /// 4. 同组(都无钟点 / 同一钟点)按 sortOrder 保持用户手动顺序
    /// - overflow 只算"未完成且未渲染"的数量——避免把已完成历史任务计入 +N 误导用户
    ///   以为"还有 N 项待办"。已完成事件的信息通过 visible 补齐已传达"过去有任务完成"。
    /// - Returns: (visible 切片, overflow 数。overflow=nil 表示无未完成溢出)
    private func slicedEvents() -> (visible: [TodoOccurrenceData], overflow: Int?) {
        // maxVisibleEvents=0:行高预算极度紧张,无法显示任何事件条。
        // 此时 overflow 也不显示(无处渲染)——这与分配器契约一致:
        // demand==0 的周本来就没有事件;demand>0 但预算不足是极端边缘场景,
        // 整月缩到几像素高时用户切到 list 视图看详情更合理。
        guard maxVisibleEvents > 0 else { return ([], nil) }
        // 单次 reduce 同时算 total 和 uncompletedCount,避免对 occurrences 两次全扫描。
        let (total, uncompletedCount) = dayState.occurrences.reduce(into: (0, 0)) { acc, occ in
            acc.0 += 1
            if !occ.isCompleted { acc.1 += 1 }
        }

        let pool = dayState.occurrences.sorted { (lhs: TodoOccurrenceData, rhs: TodoOccurrenceData) -> Bool in
            // Rule 1: 未完成排前
            if lhs.isCompleted != rhs.isCompleted {
                return !lhs.isCompleted
            }
            let lhsHasTime = lhs.todo.hasDueTime && lhs.todo.dueDate != nil
            let rhsHasTime = rhs.todo.hasDueTime && rhs.todo.dueDate != nil
            // Rule 2: 都有钟点 → 按时间升序
            if lhsHasTime && rhsHasTime, let l = lhs.todo.dueDate, let r = rhs.todo.dueDate {
                return l < r
            }
            // Rule 3: 有钟点排无钟点前
            if lhsHasTime != rhsHasTime {
                return lhsHasTime
            }
            // Rule 4: 同组按 sortOrder;再 tiebreak 用 id(TodoOccurrenceData.id 是 String)
            // 保证全序,避免 Swift sorted 不稳定导致同 sortOrder 任务在每次重算时顺序跳动。
            if lhs.todo.sortOrder != rhs.todo.sortOrder {
                return lhs.todo.sortOrder < rhs.todo.sortOrder
            }
            return lhs.id < rhs.id
        }

        if total <= maxVisibleEvents {
            return (pool, nil)
        }
        // 直接取前 maxVisibleEvents 条;最后一条是否挂 +N 由 eventBar 内 isLast 判定,
        // 构造时无需特殊处理。
        let visible = Array(pool.prefix(maxVisibleEvents))
        let uncompletedRendered = visible.filter { !$0.isCompleted }.count
        let overflow = uncompletedCount - uncompletedRendered
        return (visible, max(0, overflow))
    }

    private func gridAccessibilityLabel(from visible: [TodoOccurrenceData], overflow: Int?) -> String {
        let base = VoiceOverLabel.build(for: dayState)
        let titles = visible.map { $0.todo.title }
        guard !titles.isEmpty else { return base }
        let list = titles.joined(separator: String(localized: "a11y.day.separator"))
        var result = base + String(localized: "a11y.day.separator") + list
        // VoiceOver 补读溢出数:视觉上 +N 嵌在最后一条尾部,但 accessibilityElement(.ignore)
        // 把子视图吞掉,VoiceOver 用户听不到 "+5"。这里把溢出数显式拼进 label,
        // 让盲人用户知道"除了念出的这几项,还有 N 项未完成"。
        if let overflow, overflow > 0 {
            result += String(localized: "a11y.day.separator") + String(format: String(localized: "a11y.day.overflow"), overflow)
        }
        return result
    }
}
