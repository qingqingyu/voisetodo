import SwiftUI

/// 月历网格单格:数字 + N 条纯色 Capsule 事件概览 + `+N`。
/// N 由 `HomeMonthHeaderView` 的注水法分配器决定,上限跟着每行物理高度动态反推
/// (4 周的月每行 ~150pt → cap ~8,6 周的月每行 ~100pt → cap ~5),硬上限 15 防极端。
/// 默认 3 仅供预览/测试使用。
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
    /// 由注水法分配器决定:动态 cap 跟着每行物理高度反推(4 周的月 cap 大,6 周的月 cap 小)。
    /// 默认 3 用于预览。调用方(HomeMonthHeaderView)传入的值由 `HomeLayoutMetrics.allocateRowHeights`
    /// 保证不超过 `gridMaxBarsPerCellHardLimit`(=15,防极端)。调用方在传入前必须自行夹紧——
    /// SwiftUI View struct 的 init 不触发 didSet,Swift memberwise init 也不夹紧,
    /// 因此 clamping 责任在调用方(单一来源:HomeMonthHeaderView.dayCell)。
    var maxVisibleEvents: Int = 3

    /// 点击单条事件条 → 打开该 todo 详情。nil = 事件条不可点,整格点击仍走 onSelect。
    /// 与 WarmTodoCard.contextMenu 同策略(WarmTodoCard.swift:334-336):
    /// 调用方不注入 callback 时不挂 Button,避免空 action 的 Button 吞掉整格 tap。
    var onOpenTodo: ((TodoItemData) -> Void)? = nil

    @State private var isDropTargeted = false

    private var dayNumberColor: Color {
        // v2 配色稿:「今天」橙胶囊(primary.opacity(0.15) + primaryDark 字)完全舍弃,
        // 与「选中」视觉合并——两者都是实色品牌橙底 + 白字(对齐 HTML/spec 56 行)。
        // 这是 Apple Calendar 风格:今日默认被选中,两个状态视觉一致。
        // 如未来需要「今天非选中」用圆环等额外标记区分,需要新一次设计决策。
        isHighlighted ? .white :
        (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted)
    }

    /// 今日或选中态都需要实色品牌橙底 + 白字高亮(v2 配色稿:今日胶囊舍弃,与选中合并)。
    private var isHighlighted: Bool {
        dayState.isSelected || dayState.isToday
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
                    eventBarRow(occurrence, idx: idx, isLast: idx == visible.count - 1, overflow: overflow)
                }
                Spacer(minLength: 0)
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: rowHeight, alignment: .top)
            .opacity(dayState.isCurrentMonth ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverText)
        .accessibilityHint(String(localized: "a11y.day.hint"))
        // 事件条是嵌套 Button,被 accessibilityElement(children: .ignore) 从 AX 树里吞掉,
        // VoiceOver / Switch Control 无法直达。用 custom action 补一条等价路径:
        // 每条可见事件一个「打开 <标题>」动作(与视觉可见条一一对应;
        // overflow 的 N 条视觉上也点不到,a11y 保持同口径,不额外暴露)。
        .accessibilityActions {
            if let onOpenTodo {
                ForEach(visible, id: \.id) { occurrence in
                    Button(String(format: String(localized: "a11y.day.open_todo"), occurrence.todo.title)) {
                        onOpenTodo(occurrence.todo)
                    }
                }
            }
        }
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
        // 日数字居中在格子顶部:与上方 weekday 居中对齐(Apple Calendar 式布局)。
        // 下方事件条仍左对齐填满宽度——日数字居中、事件条左对齐是日历视图的标准模式。
        // 原实现用 HStack { Text; Spacer } 把数字推到左侧,这里改为 frame 居中。
        Text(verbatim: "\(dayState.dayNumber)")
            .font(WarmFont.mono(11))
            .foregroundColor(dayNumberColor)
            // 选中/今日加胶囊背景:实色 primary + 白字(v2 配色稿:今日与选中合并)。
            // 不加背景时白字会消失在页面背景上(纯留白方案格子无独立白底)。
            .padding(.horizontal, isHighlighted ? 4 : 0)
            .background(
                Capsule().fill(isHighlighted ? WarmTheme.primary : Color.clear)
            )
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 事件条的交互包装。onOpenTodo == nil 时返回裸 eventBar——
    /// 空 action 的 Button 会吞掉 tap,让整格 onSelect 在事件条区域失效。
    /// 与 WarmTodoCard 的嵌套 Button 先例同构(WarmTodoCard.swift:330 注释记录了
    /// 「SwiftUI 把 tap 派发给最内层 Button」+「必须用 Button 不能用 onTapGesture,
    /// iOS 26 FB18199844:顶层 onTapGesture 吞 List swipeActions 删除按钮」两条结论)。
    ///
    /// 命中区:`.contentShape(Rectangle().inset(by: 2))` 把条间死区从 2pt 拓到 6pt,
    /// 减少误触相邻条(条间距 = gridBarSpacing = 2pt,手指接触面 ~40pt 易偏移到邻条)。
    /// 仍低于 Apple HIG 44pt 最小命中区(gridBarHeight=24pt),但展开态下「选中当天」
    /// 收益本就低(下方列表不渲染),事件条打开详情的收益高得多——划得来的取舍。
    @ViewBuilder
    private func eventBarRow(_ occurrence: TodoOccurrenceData, idx: Int, isLast: Bool, overflow: Int?) -> some View {
        if let onOpenTodo {
            Button {
                HapticFeedback.light()
                onOpenTodo(occurrence.todo)
            } label: {
                eventBar(occurrence, isLast: isLast, overflow: overflow)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: 2))
            .accessibilityIdentifier("MonthGridBar_\(TodoOccurrenceData.dayKey(for: dayState.date, calendar: Self.calendar))_\(idx)")
        } else {
            eventBar(occurrence, isLast: isLast, overflow: overflow)
        }
    }

    /// 单条事件文字条:浅色分类背景 + 深色文字 + 可选时间前缀 + 可选 +N 尾标。
    /// 高度固定 24pt,允许标题显示两行;Overflow +N 嵌入最后一条尾部。
    /// 已完成态:**中性灰底 + 灰字 + 删除线**(v2 配色稿 calendar-color-spec.md 第 5 条)。
    /// 推翻了旧设计「失去填充 Color.clear + textMuted」——旧版依赖形态对比(实心 vs 空)
    /// 在小尺寸 9pt 下不够稳健;新版用「明确但低饱和」的灰底,让已完成成为整屏最不显眼一档。
    /// 中性灰脱钩分类色相,传达"已完成属于哪类在复盘场景下价值低"。
    /// 满足 WCAG 1.4.1「不能仅用颜色传达信息」:删除线对红绿色盲用户依然有效。
    ///
    /// 字体策略:三段都固定字号不响应 Dynamic Type——月历格事件条是"预览类 UI"(用户点开看详情),
    /// 不是主读内容;固定字号让字号缩放不再影响布局判定,与 Apple Calendar 日期数字一致。
    /// 取舍:违反 iOS HIG「内容应跟随 Dynamic Type」建议。
    /// - 标题段用 `.system(size: 9, weight: .regular)`(非 `WarmFont.captionFixed`):
    ///   `.custom("Avenir Next", size:)` 在中英混排下宽度测量偏大,导致提前 "…" 截断;
    ///   `.system` 用 CoreText 系统字体测量,中英混排宽度判定更准。详见函数内注释。
    /// - hour 段与 +N 段用 `WarmFont.mono(8)`(`.system(.monospaced)`),无测量问题。
    ///
    /// **布局**:可选的 hour 前缀 / 必有的标题 / 可选的 +N 尾标通过
    /// `Text` 插值合并,保留每段的字体。月历单列只有约 52pt,单行省略号本身会再占
    /// 近一个中文字的宽度;两行布局能在不缩小 9pt 字号的前提下完整显示常见标题。
    /// 字段间间距由 hour 段尾随空格、+N 段前导空格提供。
    private func eventBar(_ occurrence: TodoOccurrenceData, isLast: Bool, overflow: Int?) -> some View {
        // v2 配色:背景 + 文字色用独立 hex,不再由主色 opacity 派生。
        // 见 WarmTheme.monthGridBackground / monthGridText 注释。
        let categoryBg = WarmTheme.monthGridBackground(for: occurrence.todo.category)
        let categoryTx = WarmTheme.monthGridText(for: occurrence.todo.category)
        // 已完成:中性灰底 + 灰字 + 删除线(spec 第 5 条)。
        let bg = occurrence.isCompleted ? WarmTheme.monthGridDoneBackground : categoryBg
        let tx = occurrence.isCompleted ? WarmTheme.monthGridDoneText : categoryTx

        // hour 前缀:只显示小时(两位数)省空间:"09:55" → "09",给任务名留更多宽度。
        // 颜色策略:
        // - 未完成:沿用 tx(分类深字)但 opacity 0.62(spec 第 42 行)——任务名是主信息,时间是次要信息。
        // - 已完成:不叠 opacity。已完成态 tx 已经是中性灰 #B4BCC7,再叠 0.62 会让 hour 几乎不可见
        //   (灰色文字+灰色背景+删除线 + 6 折透明度 = 对比度过低)。spec 第 42 行的 opacity 分级
        //   明确针对「分类色文字」场景,已完成态文字全部统一为 #B4BCC7 已经够弱,无需再分级。
        // Text+Text 拼接时段内 foregroundColor 优先,外层 combined.foregroundColor(tx) 不会覆盖。
        let hourOpacity: Double = occurrence.isCompleted ? 1.0 : WarmTheme.monthGridHourOpacity
        // 跨天事件:起始日保留钟点前缀;非起始日改用"N/M "纯数字标记
        // (避开 RTL 方向符号,M9 把"第 N/M 天"包装文案加进 Localizable.xcstrings)。
        let hourText: Text
        if occurrence.isSpanStart {
            if occurrence.todo.hasDueTime, let dueDate = occurrence.todo.dueDate {
                hourText = Text(verbatim: String(format: "%02d ", Self.calendar.component(.hour, from: dueDate)))
                    .font(WarmFont.mono(8))
                    .foregroundColor(tx.opacity(hourOpacity))
            } else {
                hourText = Text("")
            }
        } else {
            hourText = Text(verbatim: "\(occurrence.spanIndex + 1)/\(occurrence.spanCount) ")
                .font(WarmFont.mono(8))
                .foregroundColor(tx.opacity(hourOpacity))
        }
        let titleText = Text(verbatim: occurrence.todo.title)
            // 用 .system 而非 WarmFont.captionFixed(.custom("Avenir Next", size:)):
            // SwiftUI 对 .custom 字体的宽度测量在中英混排下精度差。
            .font(.system(size: 9, weight: .regular))

        let overflowText: Text
        if let overflow, isLast, overflow > 0 {
            overflowText = Text(verbatim: " +\(overflow)")
                .font(WarmFont.mono(8))
        } else {
            overflowText = Text("")
        }

        // 删除线 color 与已完成文字色同色系但略深一档(spec 第 49 行),避免"灰文字 + 异色线"。
        // Text + Text 拼接(不是 LocalizedStringKey 插值):三段分别带各自的字体/样式,
        // + 运算符返回 Text 同时保留分段样式;若用 Text("\(t1)\(t2)") 会走本地化系统,
        // 在伪本地化/多语言下产生破损输出(参见 Localizable.xcstrings 历史垃圾 key %@%@%@)。
        let combined = (hourText + titleText + overflowText)
            .strikethrough(occurrence.isCompleted, color: WarmTheme.monthGridDoneStrikethrough)

        return combined
            .foregroundColor(tx)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 1)
            .frame(height: HomeLayoutMetrics.gridBarHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg))
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
