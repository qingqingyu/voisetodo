import SwiftUI

/// 网格+周（`displayMode == .grid && viewMode == .week`）专属：7 天横排时间轴。
///
/// **动态时间范围**(2026-07 重构):时间轴不再固定 8:00–22:00,而是按当周可见事件的
/// 最早/最晚时刻自适应。`rowPerHour` 反向算 = 可用高度 / (max - min),让时间轴
/// 恰好填满外层 frame,正常情况无需滚动。用户原话:
/// > 跟"月"视图一样,能够根据当前的任务和当前的屏幕,自动显示出长度。
/// > 一个屏幕上面就能看到所有的安排。
///
/// **边界**:
/// - 范围 < `minRangeHours`(4h)→ 扩展到 4h(事件块不挤一起)
/// - 范围 > `maxRangeHours`(14h)→ clamp 到 min+14(保留小幅滚动兜底)
/// - 当周无 `hasDueTime=true` 事件 → 隐藏时间轴 + 显示空状态
///
/// **不渲染的待办类别**(沿用旧规则):
/// - 无 `dueDate`:纯未安排任务,归外层 Unscheduled 区
/// - 有 `dueDate` 但 `hasDueTime == false`:有日期无钟点,时间轴无法定位 → 不显示
///   (用户切回 list+周 / list+月 能看到这类待办)
///
/// **与外层切月/周手势的关系**:
/// 外层 `monthHomeView` 挂的垂直手势用 `SimultaneousDragGesture`(UIKit workaround),
/// 跟 ScrollView 内部的滚动是 simultaneous 关系。阈值分离:
/// - 小幅垂直滑动 → ScrollView 滚动(极端情况才触发)
/// - 大幅垂直滑动(≥80pt)→ 外层手势切换 month/week 视图
struct WeekTimelineView: View {
    let state: HomeCalendarState
    let onSelectDay: (Date) -> Void
    /// 点击事件块打开详情。传整个 `TodoItemData`(对齐 `HomeSelectedDayListView.onOpenTodo` 签名),
    /// 调用方无需再按 id 回查。
    var onOpenTodo: ((TodoItemData) -> Void)? = nil
    /// 左右滑翻周回调(+1=下周,-1=上周)。与 `HomeMonthHeaderView.onShiftPeriod` 同契约。
    var onShiftPeriod: ((Int) -> Void)? = nil
    /// drawer 卡片拖到某天 column 排程。签名与 `HomeMonthHeaderView.onDropTodo` 一致,
    /// 让 HomeView 复用同一个 `assignTodoToDate` callback。
    /// drop 点挂在 `dayHeaderColumn`(顶部 7 天表头)而非 `dayEventsColumn`(时间轴事件列):
    /// 后者只在 timeRange != nil 时渲染,空状态(当周无定时事件)下不覆盖。
    var onDropTodo: ((UUID, Date) -> Void)? = nil

    /// 时间轴最小范围(小时)。防止事件稀疏时时间轴过短(比如只有 1 个事件,
    /// range = 1 小时会让事件块占满整屏)。4 小时是合理的最小工作时段。
    private static let minRangeHours: Double = 4
    /// 时间轴最大范围(小时)。事件跨度极大时(比如 6:00 + 23:00)clamp 到 14 小时,
    /// 避免时间轴过长反而需要大幅滚动。极端密集场景允许小幅滚动作为兜底。
    private static let maxRangeHours: Double = 14
    /// 无 endTime 的事件默认占多少小时。1 小时是日历类应用惯例。
    private static let defaultDurationHours: Double = 1
    /// 时间刻度步长(小时):每 2 小时一条横线 + 一个刻度标签(8, 10, 12, ...)。
    /// `timeGutter` 与 `timelineBackground` 共用此常量,避免一处改一处漏。
    private static let gridLineStepHours: Double = 2
    /// 左侧时间刻度列宽(pt)。
    private static let gutterWidth: CGFloat = 32
    /// 单列最小宽度下限(pt):极窄屏(Stage Manager 多窗口)下 `proxy.size.width - gutterWidth`
    /// 可能 < 0 被夹到 0,导致表头 26pt 圆 frame 溢出列宽。30pt 保证数字 + 圆可读。
    private static let minColumnWidth: CGFloat = 30
    /// 表头总高度(weekday 文本 + spacing 2 + dayNumber 圆 26 + 内边距)。
    /// 用于从 GeometryReader 总高度里减出时间轴可用高度。
    /// 48pt 是经验估算(实际约 14+2+26+6),在不同 Dynamic Type 下 weekday 文本高度会漂移,
    /// 误差范围 ±5pt:timelineHeight 略小 → 时间轴略矮于父容器(底部留白);
    /// timelineHeight 略大 → 时间轴略高于父容器(被 ScrollView frame 裁切,无视觉问题)。
    /// 不影响功能,产品上不可感知。如需精确值,改用 PreferenceKey 测量并回传。
    private static let headerTotalHeight: CGFloat = 48

    /// 与 `HomeCalendarState`/`HomeView` 同源的 calendar 实例——**禁止用 `Calendar.current`**:
    /// `state.occurrencesByDay` 的 dayKey 是按注入 calendar 算的,若 `position()` 内用
    /// `.current` 取 hour/minute,在非 gregorian 用户(如 islamic 日历)下 hour 计算结果会
    /// 与 dayKey 聚合口径不一致 → 事件块定位错位。统一走 state.calendar。
    private var calendar: Calendar { state.calendar }

    /// 计算当周时间轴范围(minHour, maxHour)。
    /// - 遍历 7 天的所有 occurrence,收集 `hasDueTime=true` 事件的 startHour(min 线索)
    ///   和 startHour+1h(max 线索,默认 1 小时持续)
    /// - 应用 min/max 边界(4h / 14h)
    /// - 返回 nil 表示当周无定时事件(走空状态)
    private var timeRange: (min: Double, max: Double)? {
        var minHour: Double?
        var maxHour: Double?
        for day in state.visibleDays {
            let dayKey = TodoOccurrenceData.dayKey(for: day, calendar: calendar)
            let occurrences = state.occurrencesByDay[dayKey] ?? []
            for occ in occurrences {
                guard let startHour = realStartHour(for: occ) else { continue }
                // min/max 配 ?? 初值:首次(nil)直接采用,后续比大小。
                // 比显式 if-else 短路或 map ?? true 更易读。
                minHour = min(minHour ?? startHour, startHour)
                let endHour = startHour + Self.defaultDurationHours
                maxHour = max(maxHour ?? endHour, endHour)
            }
        }
        guard let min = minHour, let rawMax = maxHour else { return nil }
        var adjustedMax = rawMax
        if adjustedMax - min < Self.minRangeHours {
            adjustedMax = min + Self.minRangeHours
        }
        if adjustedMax - min > Self.maxRangeHours {
            adjustedMax = min + Self.maxRangeHours
        }
        return (min, adjustedMax)
    }

    var body: some View {
        GeometryReader { proxy in
            // 7 列等宽,每列宽 = (总宽 - gutter) / 7。极窄屏(Stage Manager 多窗口、宽度 < gutter)
            // 会被夹到 minColumnWidth(30pt),让表头 26pt 圆 frame 不会溢出列宽。
            let colWidth = max(Self.minColumnWidth, (proxy.size.width - Self.gutterWidth) / 7)
            // 时间轴可用高度 = 总高 - 表头 - VStack spacing(WarmSpacing.xs) - 顶部 padding(WarmSpacing.xxs)。
            // 减出来的 timelineHeight 反推 rowPerHour,让时间轴恰好填满(无滚动)。
            let timelineHeight = max(0, proxy.size.height - Self.headerTotalHeight - WarmSpacing.xs - WarmSpacing.xxs)

            VStack(spacing: WarmSpacing.xs) {
                // 顶部 7 天表头
                HStack(spacing: 0) {
                    Spacer().frame(width: Self.gutterWidth)
                    ForEach(state.visibleDays, id: \.self) { day in
                        dayHeaderColumn(day, width: colWidth)
                    }
                }

                if let range = timeRange {
                    // 可滚动时间轴(正常不触发滚动,极端密集时兜底)
                    ScrollView(.vertical, showsIndicators: true) {
                        HStack(spacing: 0) {
                            timeGutter(minHour: range.min, maxHour: range.max, timelineHeight: timelineHeight)
                            ZStack(alignment: .topLeading) {
                                timelineBackground(colWidth: colWidth, minHour: range.min, maxHour: range.max, timelineHeight: timelineHeight)
                                ForEach(state.visibleDays, id: \.self) { day in
                                    dayEventsColumn(day, width: colWidth, minHour: range.min, maxHour: range.max, timelineHeight: timelineHeight)
                                }
                            }
                            .frame(height: timelineHeight)
                        }
                        // 底部 padding 兜底:靠近 maxHour 的事件块 height 可能 < 14pt,
                        // eventBlock 用 max(14, height) 撑高后会向下溢出 timelineHeight (~2-10pt)。
                        // 给 ScrollView content 14pt 底部空间,避免溢出被裁切(用户可滚到底看到完整块)。
                        .padding(.bottom, 14)
                    }
                    // 抑制 iOS 17 ScrollView 默认 contentMargins 自动 inset:
                    // timelineHeight 已基于 GeometryReader 精确推导,系统再叠加 inset 会让时间轴
                    // 与父容器顶部/底部错位(顶部被压、底部留白)。对齐 HomeSelectedDayListView 做法。
                    .contentMargins(.vertical, 0, for: .scrollContent)
                } else {
                    // 空状态:当周无定时事件(只有无钟点或无日期的待办,那些归 list+月/list+周 看)
                    emptyState
                }
            }
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.xxs)
        // 水平翻周手势:与 HomeMonthHeaderView 同一套阈值/语义。
        // 与内部 ScrollView 的垂直滚动共存(SimultaneousDragGesture 允许 simultaneous)。
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

    /// 顶部单列表头:weekday 缩写 + dayNumber(选中的高亮圆)。
    private func dayHeaderColumn(_ day: Date, width: CGFloat) -> some View {
        let dayState = state.dayState(for: day)
        let isSelected = dayState.isSelected
        let isToday = dayState.isToday
        // weekday 提到顶部只算一次——Text 视觉与 accessibilityLabel 都要用,避免重复方法调用。
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
                    // fixedSize:绕开 SwiftUI 对固定字号 Text 的 Dynamic Type layout 补偿(AX 档位下
                    // intrinsic width 被放大 ×2~3 → 压进 26pt frame 触发 .tail truncation → 显示「…」)。
                    // 详见 HomeMonthDayButton 同位置注释。
                    .fixedSize()
            }
            .frame(width: 26, height: 26)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay(day) }
        .accessibilityElement(children: .ignore)
        // VoiceOver 文案:必须按每列对应的日期朗读,不能用全局 selectedDateTitle,
        // 否则 7 列朗读同一句,用户无法区分"星期三"和"星期四"。
        // 格式 "weekday dayNumber"(如 "周三 17")——weekday 已是本地化字符串,dayNumber 是裸数字。
        .accessibilityLabel("\(weekdayTitle) \(dayState.dayNumber)")
        .accessibilityHint(isSelected ? String(localized: "a11y.day.hint") : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        // drawer 卡片 drop 接收点:载荷是 `todo.id.uuidString`(见 UnscheduledDrawer.unscheduledCard),
        // drop 到某天表头 → assignTodoToDate(id, date: day) 设 dueDate(不指定钟点,跟
        // HomeMonthGridButton 的 drop 行为对齐)。用户从 drawer 把未安排任务拖到 week 网格,
        // drop 到这一列的任意一天都能排程。
        // **不加 isTargeted 视觉反馈**:与 HomeMonthGridButton(有 isDropTargeted 描边高亮)不同,
        // week 分支主动省略命中态高亮,降低状态复杂度;系统默认 drag preview 已提供足够反馈
        // (卡片跟随手指 + snap 行为)。如后续发现用户需要更明显的落点指示,可补 isTargeted + overlay。
        .dropDestination(for: String.self) { items, _ in
            // 无回调时返回 false:让系统知道 drop 未被处理,避免「drop 视觉成功但无副作用」
            // 误导(对齐 HomeMonthGridButton.dropDestination 同场景做法)。
            guard let callback = onDropTodo,
                  let idString = items.first,
                  let id = UUID(uuidString: idString) else { return false }
            callback(id, day)
            return true
        }
    }

    // MARK: - Empty State

    /// 当周无 `hasDueTime=true` 事件时显示。7 天表头仍在(用户能看到日期),只是时间轴区显示空状态。
    /// 复用 ProductEmptyStateView 跟首页/确认页空状态视觉一致。
    private var emptyState: some View {
        ProductEmptyStateView(
            icon: "calendar.badge.clock",
            title: String(localized: "empty.week.no_timed.title"),
            message: String(localized: "empty.week.no_timed.message"),
            cardless: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline background

    /// 横线刻度对应的 hour 序列(基于 timeRange)。每 `gridLineStepHours` 一条,落在整点上。
    /// 注:`ForEach(gridLineHours, id: \.self)` 依赖 Double 严格相等。当前 `gridLineStepHours = 2`
    /// (整数累加,无浮点误差)安全;若改为 0.5 / 0.25 需要先量化。
    private static func gridLineHours(minHour: Double, maxHour: Double) -> [Double] {
        // 对齐到 gridLineStepHours 整数倍:比如 min=9.5 → 从 10 开始;min=8 → 从 8 开始
        let start = (minHour / gridLineStepHours).rounded(.up) * gridLineStepHours
        guard start < maxHour else { return [] }
        return Array(stride(from: start, through: maxHour, by: gridLineStepHours))
    }

    /// 左侧时间刻度列:每 2 小时一个标签 + 一条横线穿过整个时间轴。
    private func timeGutter(minHour: Double, maxHour: Double, timelineHeight: CGFloat) -> some View {
        let rowPerHour = timelineHeight / CGFloat(maxHour - minHour)
        let hours = Self.gridLineHours(minHour: minHour, maxHour: maxHour)
        return ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { h in
                Text(Self.hourLabel(h))
                    .font(WarmFont.caption(10))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(width: Self.gutterWidth - 4, alignment: .leading)
                    .offset(y: CGFloat(h - minHour) * rowPerHour - 6)
            }
        }
        .frame(width: Self.gutterWidth, height: timelineHeight, alignment: .topLeading)
    }

    /// 时间轴底:仅横向网格线(每 gridLineStepHours 一条,整点位置)。
    ///
    /// **设计取舍**(2026-07 用户反馈):
    /// - 去掉 7 列分隔竖线 —— 竖线让空白区变成"格子纸",视觉噪音压过稀疏的事件内容。
    ///   竞品(Apple Calendar / Google Calendar)只画横线,竖向用 column 间的视觉留白区分。
    /// - 横线 opacity 0.3 → 0.08 —— 横线是必要的整点锚点,但 0.3 太重,降到 8% 让事件块主导视觉。
    private func timelineBackground(colWidth: CGFloat, minHour: Double, maxHour: Double, timelineHeight: CGFloat) -> some View {
        let totalWidth = colWidth * 7
        let rowPerHour = timelineHeight / CGFloat(maxHour - minHour)
        let lineColor = WarmTheme.sketch.opacity(0.08)
        let hours = Self.gridLineHours(minHour: minHour, maxHour: maxHour)
        return ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { h in
                Rectangle()
                    .fill(lineColor)
                    .frame(width: totalWidth, height: 0.5)
                    .offset(y: CGFloat(h - minHour) * rowPerHour)
            }
        }
        .frame(width: totalWidth, height: timelineHeight, alignment: .topLeading)
    }

    // MARK: - Events

    /// 单天的事件列:所有事件块按 startTime 绝对定位叠加。
    ///
    /// **已知限制**:同时刻 ≥2 个事件会 ZStack 完全重叠(仅显示最上层一条),用户看不到被遮挡的。
    /// 未来如需支持并排展示(Google Calendar 式 cascade),需要按 (startHour, duration) 做
    /// lane 分配算法(贪心或 sweep-line),把同时段事件按 lane index 错位 + 宽度按 lane 总数等分。
    /// 当前实现优先保证 1-2 个同时段事件的可读性——多事件叠加是设计取舍(密度 vs 完整性)。
    private func dayEventsColumn(_ day: Date, width: CGFloat, minHour: Double, maxHour: Double, timelineHeight: CGFloat) -> some View {
        let rowPerHour = timelineHeight / CGFloat(maxHour - minHour)
        let dayKey = TodoOccurrenceData.dayKey(for: day, calendar: calendar)
        let occurrences = state.occurrencesByDay[dayKey] ?? []
        // id 拼接 dayKey 前缀:跨天同一 occurrence.id(理论不该出现,但防御)
        // 或同一天多条同源 occurrence 会触发 SwiftUI id 冲突运行时告警。
        let positioned = occurrences.compactMap { occurrence -> PositionedEvent? in
            guard let pos = position(for: occurrence, minHour: minHour, maxHour: maxHour, rowPerHour: rowPerHour) else { return nil }
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

    /// 单个事件块:分类色背景 + 截断 title,点击 onOpenTodo。
    /// 若事件真实开始时刻早于 minHour(被 clamp 到顶部),顶部叠加一条白色渐变条
    /// 提示"延伸到时间轴外上方"——避免用户把贴顶的事件误读为 minHour 整开始。
    private func eventBlock(_ item: PositionedEvent, colWidth: CGFloat) -> some View {
        let color = WarmTheme.color(for: item.occurrence.todo.category)
        // realStartHour != nil 由 position() 过滤保证(无 dueTime 不进 positioned);
        // 若 realStartHour == nil 视为未 clamp,不画顶部白条(避免误导性提示)。
        let isClampedAtTop = item.realStartHour.map { $0 < item.position.startHour } ?? false
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
                    // 仅在事件块高度 > 8pt 时显示白条——矮块(靠近 maxHour 被压扁)时
                    // 白条会占满整个块遮挡文字,反而比"没有提示"更糟。
                    if isClampedAtTop && item.position.height > 8 {
                        // 顶部 3pt 渐变白条——视觉提示"事件实际更早,被夹到 minHour 行"
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
        // VoiceOver 文案直接拼接(不走 String(format:))——
        // todo title 可能含 `%` 字符(如 "100% 完成"),String(format:) 会把 `%` 当格式说明符解析
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
    /// 范围参数(minHour/maxHour/rowPerHour)由调用方根据 timeRange + timelineHeight 推导后传入。
    /// - 无 dueDate → 不渲染(返回 nil,归入底部"无时间"分区由调用方处理)
    /// - 有 dueDate 但 !hasDueTime → 不渲染(无钟点不该塞时间轴)
    /// - 起点早于 minHour → 夹到顶部
    /// - 起点晚于 maxHour → 不渲染(出轴)
    /// - 最小可见高度 trade-off:clampedStart 距 maxHour ≥ 0.25h 时,maxHour 兜底为
    ///   clampedStart + 0.25h(避免靠近 maxHour 的事件被压成 < 12pt 不可读);
    ///   若 clampedStart 距 maxHour < 0.25h,minEnd 退回 maxHour(自然结束时刻),
    ///   事件以 (maxHour - clampedStart) 真实时长渲染——可能 < 12pt。此时渲染层
    ///   `eventBlock` 的 `max(14, height)` 兜底会撑到 14pt,**事件块视觉上会向下溢出时间轴边界
    ///   (maxHour 行)~2-10pt**。这是设计取舍:宁可让最后一个事件块视觉略超边界,
    ///   也要保证 title 至少 2 行可读(信息完整性 > 边界严谨性)。
    private func position(for occurrence: TodoOccurrenceData, minHour: Double, maxHour: Double, rowPerHour: CGFloat) -> (top: CGFloat, height: CGFloat, startHour: Double)? {
        let todo = occurrence.todo
        guard let dueDate = todo.dueDate, todo.hasDueTime else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: dueDate)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        let startHour = Double(hour) + Double(minute) / 60
        let clampedStart = max(startHour, minHour)
        guard clampedStart < maxHour else { return nil }
        // 默认持续 defaultDurationHours(1h),但不超出 maxHour。
        let naturalEnd = min(clampedStart + Self.defaultDurationHours, maxHour)
        // 防极矮:靠近 maxHour 的事件自然结束时刻 < clampedStart + 0.25h 时,
        // 强制延长到至少 0.25h(不超出 maxHour)。
        let minEnd = min(clampedStart + 0.25, maxHour)
        let endHour = max(naturalEnd, minEnd)
        let top = CGFloat(clampedStart - minHour) * rowPerHour
        let height = CGFloat(endHour - clampedStart) * rowPerHour
        return (top, height, clampedStart)
    }

    /// occurrence 真实开始时刻(未 clamp)。供 `timeRange` 收集 min/max 线索,
    /// 也供 `eventBlock` 判断是否需要渲染顶部"被夹"指示条。
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
    /// occurrence 真实开始时刻(未 clamp 到 minHour);nil 表示无 dueDate/无 dueTime。
    /// `eventBlock` 用此判断是否需要在顶部画白色渐变条提示"事件实际更早"。
    let realStartHour: Double?
    /// id 拼 dayKey 前缀:防止跨天/同天同源 occurrence 触发 SwiftUI ForEach id 冲突告警。
    var id: String { "\(dayKey)-\(occurrence.id)" }
}
