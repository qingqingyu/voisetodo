import SwiftUI

/// 网格+周（`displayMode == .grid && viewMode == .week`）专属：7 天横排时间轴。
///
/// 与 HTML 设计稿 `weekTimelineHTML` 对齐：
/// - 顶部 7 列表头：weekday(一/二/...) + dayNumber(选中的高亮圆)
/// - 下方时间轴：固定 8:00–22:00（14 小时）× 48pt/小时 = 672pt
/// - 事件块按 `todo.dueDate` 的小时分量绝对定位
/// - 整体垂直滚动（672pt 超出可视区）
///
/// **不渲染的待办类别**：
/// - 无 `dueDate`：纯未安排任务，归外层 Unscheduled 区。
/// - 有 `dueDate` 但 `hasDueTime == false`：有日期但无具体钟点，时间轴上无法定位 → **不显示**。
///   用户切回 `list+week` 或 `list+month` 才能看到这类待办。这是已知取舍：时间轴强调"时段布局"，
///   无时段信息不应硬塞一个随机位置。若产品需要兼顾，考虑底部加 "无时段" 分区（follow-up）。
/// - `dueDate` 的小时分量 ≥ 22 或 < 8（但 hasDueTime=true）：clamp 到时间轴边缘（详见 `position()`）。
///
/// **与外层切月/周手势的关系**：
/// 外层 `monthHomeView` 挂的垂直手势用 `SimultaneousDragGesture`（UIKit workaround），
/// 跟 ScrollView 内部的滚动是 simultaneous 关系。阈值分离：
/// - 小幅垂直滑动 → ScrollView 滚动
/// - 大幅垂直滑动（≥80pt）→ 外层手势切换 month/week 视图（双向：week→month 或 month→week）
/// 实测左右翻周冲突时调整 `HomeLayoutMetrics.periodSwipeThreshold`（60pt 水平阈值）；
/// 垂直切视图阈值在 `HomeLayoutMetrics.viewModeSwitchThreshold`（80pt）。
struct WeekTimelineView: View {
    let state: HomeCalendarState
    let onSelectDay: (Date) -> Void
    /// 点击事件块打开详情。传整个 `TodoItemData`（对齐 `HomeSelectedDayListView.onOpenTodo` 签名），
    /// 调用方无需再按 id 回查。
    var onOpenTodo: ((TodoItemData) -> Void)? = nil
    /// 左右滑翻周回调（+1=下周，-1=上周）。与 `HomeMonthHeaderView.onShiftPeriod` 同契约。
    /// 内部挂水平手势（horizontal > vertical + periodSwipeThreshold），跟 ScrollView 垂直滚动共存。
    ///
    /// **未提供 onDropTodo 回调**：时间轴上的事件块已占据精确时段，从 Unscheduled 拖入需要
    /// 用户先指定"哪一天 + 哪个钟点"，目前交互复杂度过高。如需拖拽改期，切到 list/grid+月，
    /// 那里有 `dropDestination` 支持"拖到格子即改日期"（钟点不变）。
    var onShiftPeriod: ((Int) -> Void)? = nil

    /// 时间轴起点（含）。固定 8:00——大多数待办集中在工作时间。
    /// 早于 8 的事件会被夹在顶部（top=0），不溢出但不精确——后续如需动态范围再改。
    private static let startHour: Double = 8
    /// 时间轴终点（不含）。22:00 = 晚上 10 点，覆盖晚间提醒。
    private static let endHour: Double = 22
    /// 每小时行高（pt）。48pt 与 HTML 设计稿 ROW=48 对齐——事件块至少 48pt 才能装下文字。
    private static let rowPerHour: CGFloat = 48
    /// 无 endTime 的事件默认占多少小时。1 小时是日历类应用惯例。
    private static let defaultDurationHours: Double = 1
    /// 时间刻度步长（小时）：每 2 小时一条横线 + 一个刻度标签（8, 10, 12, ...）。
    /// `timeGutter` 与 `timelineBackground` 共用此常量，避免一处改一处漏。
    private static let gridLineStepHours: Double = 2
    /// 左侧时间刻度列宽（pt）。
    private static let gutterWidth: CGFloat = 32
    /// 单列最小宽度下限（pt）：极窄屏（Stage Manager 多窗口）下 `proxy.size.width - gutterWidth`
    /// 可能 < 0 被夹到 0，导致表头 26pt 圆 frame 溢出列宽。30pt 保证数字 + 圆可读。
    private static let minColumnWidth: CGFloat = 30

    /// 与 `HomeCalendarState`/`HomeView` 同源的 calendar 实例——**禁止用 `Calendar.current`**：
    /// `state.occurrencesByDay` 的 dayKey 是按注入 calendar 算的，若 `position()` 内用
    /// `.current` 取 hour/minute，在非 gregorian 用户（如 islamic 日历）下 hour 计算结果会
    /// 与 dayKey 聚合口径不一致 → 事件块定位错位。统一走 state.calendar。
    private var calendar: Calendar { state.calendar }

    /// 时间轴总高度 = (endHour - startHour) × rowPerHour
    private var timelineHeight: CGFloat {
        CGFloat(Self.endHour - Self.startHour) * Self.rowPerHour
    }

    var body: some View {
        GeometryReader { proxy in
            // 7 列等宽，每列宽 = (总宽 - gutter) / 7。极窄屏（Stage Manager 多窗口、宽度 < gutter）
            // 会被夹到 minColumnWidth(30pt)，让表头 26pt 圆 frame 不会溢出列宽。
            // 宁可横向溢出整个时间轴（用户横向滚动），也不让单列错位。
            let colWidth = max(Self.minColumnWidth, (proxy.size.width - Self.gutterWidth) / 7)

            VStack(spacing: WarmSpacing.xs) {
                // 顶部 7 天表头
                HStack(spacing: 0) {
                    Spacer().frame(width: Self.gutterWidth)
                    ForEach(state.visibleDays, id: \.self) { day in
                        dayHeaderColumn(day, width: colWidth)
                    }
                }

                // 可滚动时间轴
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(spacing: 0) {
                        // 左侧时间刻度
                        timeGutter

                        // 7 列事件区（ZStack 叠加事件块 + 列分割线）
                        ZStack(alignment: .topLeading) {
                            // 横线 + 列底
                            timelineBackground(colWidth: colWidth)

                            // 事件块
                            ForEach(state.visibleDays, id: \.self) { day in
                                dayEventsColumn(day, width: colWidth)
                            }
                        }
                        .frame(height: timelineHeight)
                    }
                    // 底部 padding 兜底：靠近 endHour 的事件块 position.height 可能 < 14pt,
                    // eventBlock 用 max(14, height) 撑高后会向下溢出 timeAxisHeight (~2-10pt)。
                    // 这里给 ScrollView content 14pt 底部空间,避免溢出被裁切（用户可滚到底看到完整块）。
                    .padding(.bottom, 14)
                }
            }
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.xxs)
        // 水平翻周手势：与 HomeMonthHeaderView 同一套阈值/语义。
        // 与内部 ScrollView 的垂直滚动共存（SimultaneousDragGesture 允许 simultaneous）。
        .gesture(
            SimultaneousDragGesture(minimumDistance: HomeLayoutMetrics.viewModeDragThreshold) { drag in
                let vertical = abs(drag.translation.height)
                let horizontal = abs(drag.translation.width)
                guard horizontal > vertical,
                      horizontal > HomeLayoutMetrics.periodSwipeThreshold else { return }
                onShiftPeriod?(drag.translation.width < 0 ? 1 : -1)
            }
        )
        .accessibilityIdentifier("WeekTimelineView")
    }

    // MARK: - Header

    /// 顶部单列表头：weekday 缩写 + dayNumber（选中的高亮圆）。
    private func dayHeaderColumn(_ day: Date, width: CGFloat) -> some View {
        let dayState = state.dayState(for: day)
        let isSelected = dayState.isSelected
        let isToday = dayState.isToday
        // weekday 提到顶部只算一次——Text 视觉与 accessibilityLabel 都要用，避免重复方法调用。
        let weekdayTitle = state.weekdayTitle(for: day)
        return VStack(spacing: 2) {
            Text(weekdayTitle)
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.textSecondary)
            ZStack {
                if isSelected || isToday {
                    Circle()
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.primary.opacity(0.18))
                }
                Text("\(dayState.dayNumber)")
                    .font(WarmFont.headlineFixed(13))
                    .foregroundColor(
                        isSelected ? .white :
                        (isToday ? WarmTheme.primaryDark : WarmTheme.textPrimary)
                    )
            }
            .frame(width: 26, height: 26)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay(day) }
        .accessibilityElement(children: .ignore)
        // VoiceOver 文案：必须按每列对应的日期朗读，不能用全局 selectedDateTitle，
        // 否则 7 列朗读同一句，用户无法区分"星期三"和"星期四"。
        // 格式 "weekday dayNumber"（如 "周三 17"）——weekday 已是本地化字符串，dayNumber 是裸数字。
        .accessibilityLabel("\(weekdayTitle) \(dayState.dayNumber)")
        .accessibilityHint(isSelected ? String(localized: "a11y.day.hint") : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: - Timeline background

    /// 横线刻度对应的 hour 序列（[8, 10, 12, ..., 20]）。`timeGutter` 与 `timelineBackground`
    /// 共用——改步长只改 `gridLineStepHours` 一处，避免两处漂移。
    ///
    /// 注：`ForEach(gridLineHours, id: \.self)` 依赖 Double 严格相等。当前 `gridLineStepHours = 2`
    /// （整数累加,无浮点误差）安全;若改为 0.5 / 0.25（半小时）需先用 `round(h * 4) / 4`
    /// 量化,否则 stride 浮点累加会产生 8.499999... 类似值,导致 id 重复或漏行。
    private static let gridLineHours: [Double] = Array(
        stride(from: startHour, to: endHour, by: gridLineStepHours)
    )

    /// 左侧时间刻度列：每 2 小时一个标签 + 一条横线穿过整个时间轴。
    private var timeGutter: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.gridLineHours, id: \.self) { h in
                // 每个标签 + 横线占一行
                Text(Self.hourLabel(h))
                    .font(WarmFont.caption(10))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(width: Self.gutterWidth - 4, alignment: .leading)
                    .offset(y: CGFloat(h - Self.startHour) * Self.rowPerHour - 6)
            }
        }
        .frame(width: Self.gutterWidth, height: timelineHeight, alignment: .topLeading)
    }

    /// 时间轴底：横向网格线（每 2 小时一条）+ 7 列分隔线。
    private func timelineBackground(colWidth: CGFloat) -> some View {
        let totalWidth = colWidth * 7
        // 复用 WarmTheme.sketch.opacity(0.3)——与现有线条（WarmInkPen 等）同一色系。
        let lineColor = WarmTheme.sketch.opacity(0.3)
        return ZStack(alignment: .topLeading) {
            // 横线
            ForEach(Self.gridLineHours, id: \.self) { h in
                Rectangle()
                    .fill(lineColor)
                    .frame(width: totalWidth, height: 0.5)
                    .offset(y: CGFloat(h - Self.startHour) * Self.rowPerHour)
            }
            // 列分隔线（每列右边一条）
            ForEach(0..<6, id: \.self) { i in
                Rectangle()
                    .fill(lineColor)
                    .frame(width: 0.5, height: timelineHeight)
                    .offset(x: colWidth * CGFloat(i + 1))
            }
        }
        .frame(width: totalWidth, height: timelineHeight, alignment: .topLeading)
    }

    // MARK: - Events

    /// 单天的事件列：所有事件块按 startTime 绝对定位叠加。
    ///
    /// **已知限制**：同时刻 ≥2 个事件会 ZStack 完全重叠（仅显示最上层一条），用户看不到被遮挡的。
    /// 未来如需支持并排展示（Google Calendar 式 cascade）,需要按 (startHour, duration) 做
    /// lane 分配算法（贪心或 sweep-line），把同时段事件按 lane index 错位 + 宽度按 lane 总数等分。
    /// 当前实现优先保证 1-2 个同时段事件的可读性——多事件叠加是设计取舍（密度 vs 完整性）。
    private func dayEventsColumn(_ day: Date, width: CGFloat) -> some View {
        let dayKey = TodoOccurrenceData.dayKey(for: day, calendar: calendar)
        let occurrences = state.occurrencesByDay[dayKey] ?? []
        // id 拼接 dayKey 前缀：跨天同一 occurrence.id（理论不该出现，但防御）
        // 或同一天多条同源 occurrence 会触发 SwiftUI id 冲突运行时告警。
        let positioned = occurrences.compactMap { occurrence -> PositionedEvent? in
            guard let pos = position(for: occurrence) else { return nil }
            return PositionedEvent(
                occurrence: occurrence,
                dayKey: dayKey,
                position: pos,
                realStartHour: realStartHour(for: occurrence)
            )
        }
        return ZStack(alignment: .topLeading) {
            ForEach(positioned, id: \.id) { item in
                eventBlock(item, colWidth: width)
                    .offset(x: 0, y: item.position.top)
            }
        }
        .frame(width: width, height: timelineHeight, alignment: .topLeading)
    }

    /// 单个事件块：分类色背景 + 截断 title，点击 onOpenTodo。
    /// 若事件真实开始时刻早于 startHour（被 clamp 到顶部），顶部叠加一条白色渐变条
    /// 提示"延伸到时间轴外上方"——避免用户把贴顶的事件误读为 8:00 整开始。
    private func eventBlock(_ item: PositionedEvent, colWidth: CGFloat) -> some View {
        let color = WarmTheme.color(for: item.occurrence.todo.category)
        let isClampedAtTop = (item.realStartHour ?? Self.startHour) < Self.startHour
        return Button {
            onOpenTodo?(item.occurrence.todo)
        } label: {
            Text(item.occurrence.todo.title)
                .font(WarmFont.caption(10))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: max(14, item.position.height))
                .background(color.opacity(item.occurrence.isCompleted ? 0.4 : 0.85))
                .cornerRadius(4)
                .overlay(alignment: .top) {
                    // 仅在事件块高度 > 8pt 时显示白条——矮块(靠近 endHour 被压扁)时
                    // 白条会占满整个块遮挡文字,反而比"没有提示"更糟。
                    if isClampedAtTop && item.position.height > 8 {
                        // 顶部 3pt 渐变白条——视觉提示"事件实际更早,被夹到 8:00 行"
                        // cornerRadius 已作用于父 frame,overlay 不再重复加圆角:
                        // 渐变条只在顶部边缘可见,底部渐隐不会触碰圆角的左右下角。
                        LinearGradient(
                            colors: [.white.opacity(0.85), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 3)
                        .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: max(0, colWidth - 3))
        .opacity(item.occurrence.isCompleted ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        // VoiceOver 文案直接拼接（不走 String(format:)）——
        // todo title 可能含 `%` 字符（如 "100% 完成"），String(format:) 会把 `%` 当格式说明符解析
        // 导致 crash 或乱码。直接拼接 + 本地化分隔符既保留多语言灵活性又安全。
        .accessibilityLabel(
            item.occurrence.todo.title
            + String(localized: "a11y.event_hour_separator")
            + Self.hourLabel(item.position.startHour)
        )
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Position math

    /// 把 occurrence 的 dueDate 解析成时间轴上的 (top, height, startHour)。
    /// - 无 dueDate → 不渲染（返回 nil，归入底部"无时间"分区由调用方处理）
    /// - 有 dueDate 但 !hasDueTime → 不渲染（无钟点不该塞时间轴）
    /// - 起点早于 startHour → 夹到顶部
    /// - 起点晚于 endHour → 不渲染（出轴）
    /// - 最小可见高度 trade-off：clampedStart 距 endHour ≥ 0.25h 时，endHour 兜底为
    ///   clampedStart + 0.25h（避免靠近 endHour 的事件被压成 < 12pt 不可读）；
    ///   若 clampedStart 距 endHour < 0.25h，minEnd 退回 endHour（自然结束时刻），
    ///   事件以 (endHour - clampedStart) 真实时长渲染——可能 < 12pt。此时渲染层
    ///   `eventBlock` 的 `max(14, height)` 兜底会撑到 14pt，**事件块视觉上会向下溢出时间轴边界
    ///   (endHour 22:00 行)~2-10pt**。这是设计取舍：宁可让最后一个事件块视觉略超边界，
    ///   也要保证 title 至少 2 行可读（信息完整性 > 边界严谨性）。
    private func position(for occurrence: TodoOccurrenceData) -> (top: CGFloat, height: CGFloat, startHour: Double)? {
        let todo = occurrence.todo
        guard let dueDate = todo.dueDate, todo.hasDueTime else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: dueDate)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        let startHour = Double(hour) + Double(minute) / 60
        let clampedStart = max(startHour, Self.startHour)
        guard clampedStart < Self.endHour else { return nil }
        // 默认持续 defaultDurationHours（1h），但不超出 endHour。
        let naturalEnd = min(clampedStart + Self.defaultDurationHours, Self.endHour)
        // 防极矮：靠近 endHour 的事件自然结束时刻 < clampedStart + 0.25h 时，
        // 强制延长到至少 0.25h（不超出 endHour，若 endHour - clampedStart < 0.25 则退回 naturalEnd）。
        let minEnd = min(clampedStart + 0.25, Self.endHour)
        let endHour = max(naturalEnd, minEnd)
        let top = CGFloat(clampedStart - Self.startHour) * Self.rowPerHour
        let height = CGFloat(endHour - clampedStart) * Self.rowPerHour
        return (top, height, clampedStart)
    }

    /// occurrence 真实开始时刻（未 clamp）。供 `eventBlock` 判断是否需要渲染顶部"被夹"指示条。
    /// 与 `position()` 同口径:无 dueDate / 无 hasDueTime / 解析失败 → 返回 nil。
    private func realStartHour(for occurrence: TodoOccurrenceData) -> Double? {
        let todo = occurrence.todo
        guard let dueDate = todo.dueDate, todo.hasDueTime else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: dueDate)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        return Double(hour) + Double(minute) / 60
    }

    /// "8" / "10" / "12" 刻度标签。
    private static func hourLabel(_ h: Double) -> String {
        String(Int(h))
    }
}

// MARK: - Positioned event

private struct PositionedEvent: Identifiable {
    let occurrence: TodoOccurrenceData
    let dayKey: String
    let position: (top: CGFloat, height: CGFloat, startHour: Double)
    /// occurrence 真实开始时刻（未 clamp 到 startHour）；nil 表示无 dueDate/无 dueTime。
    /// `eventBlock` 用此判断是否需要在顶部画白色渐变条提示"事件实际更早"。
    let realStartHour: Double?
    /// id 拼 dayKey 前缀：防止跨天/同天同源 occurrence 触发 SwiftUI ForEach id 冲突告警。
    var id: String { "\(dayKey)-\(occurrence.id)" }
}
