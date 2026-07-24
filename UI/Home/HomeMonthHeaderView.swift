import SwiftUI
import UIKit

struct HomeMonthHeaderView: View {
    let state: HomeCalendarState
    let onSelectDay: (Date) -> Void
    /// 从 Unscheduled 拖任务到日期格时触发（UUID = 任务，Date = 格子日期）。
    var onDropTodo: ((UUID, Date) -> Void)? = nil
    /// 左右滑翻月回调：参数 +1 = 下一月，-1 = 上一月。
    /// 手势挂在本视图（日历区域）本身——挂在这里的 recognizer，
    /// 其 host view 的 bounds 只覆盖日历区，起点天然在日历区，不需要 startLocation 判定。
    ///
    /// 调用方契约：本视图自带手势在 `onShiftPeriod != nil` 时始终激活,Header **不做 tab 守卫**——
    /// 外层(HomeView.monthHomeView)必须仅在 `selectedBottomTab == .calendar` 时渲染本视图,
    /// 否则「今日」tab 误挂载时左右滑仍会触发翻月。
    var onShiftPeriod: ((Int) -> Void)? = nil
    /// 网格总预算高度(来自 GeometryReader)。0 = 不约束,用默认行高。
    var availableHeight: CGFloat = 0

    /// 把 42 天按周分组,过滤掉全是跨月溢出的行(如纯下月 3-9 号那一行)。
    /// 保留跨月混合行(如上月 30-31 + 本月 1-2,或本月 29-31 + 下月 1-2)。
    /// 对齐 HTML 参考稿 `weeks.filter(w => w.some(d => !d.out))`。
    /// 删掉纯溢出行后,剩余周分到更多高度,格子内能显示更多事件条。
    private var weekGroups: [[Date]] {
        let raw = stride(from: 0, to: state.visibleDays.count, by: 7).map {
            Array(state.visibleDays[$0..<min($0 + 7, state.visibleDays.count)])
        }
        return raw.filter { week in
            week.contains { state.calendar.isDate($0, equalTo: state.visibleMonthAnchor, toGranularity: .month) }
        }
    }

    /// 注水法分配结果:行高 + 每周可显示条数 + 内部用的 weekGroups。
    /// 把 weekGroups / eventsPerDay / 分配三步合并到单一 computed property,
    /// 让 body 只触发一次完整计算(而不是三个独立 computed 各自重建数组)。
    private struct AllocationResult {
        let weekGroups: [[Date]]
        let rowHeights: [CGFloat]
        let barsShown: [Int]
    }

    private var allocation: AllocationResult {
        let weeks = weekGroups
        let eventsPerDay = weeks.map { week in
            week.map { day in
                let key = TodoOccurrenceData.dayKey(for: day, calendar: state.calendar)
                return (state.occurrencesByDay[key] ?? []).count
            }
        }
        let budget = max(0, availableHeight - HomeLayoutMetrics.calendarFixedSectionHeight)
        let (rowHeights, barsShown) = HomeLayoutMetrics.allocateRowHeights(
            eventsPerDay: eventsPerDay, budgetHeight: budget
        )
        return AllocationResult(weekGroups: weeks, rowHeights: rowHeights, barsShown: barsShown)
    }

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            // weekday 标签行
            // spacing 必须与下方格子行 (gridColumnSpacing=2) 一致：WarmSpacing.xs(8pt) 下
            // 7 个标签按 8pt 排布、格子按 2pt 排布，中心逐位累积偏移，`Mon` 不在第一格中心。
            // 统一到 2pt 后 weekday 中心严格对齐格子中心。
            HStack(spacing: HomeLayoutMetrics.gridColumnSpacing) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // 注水法变高行网格:忙的周高,空的周矮。
            // 注意:此处用 VStack+HStack 而非 LazyVGrid —— 因为每行高度由分配器独立决定(变高),
            // LazyVGrid 的 GridItem sizing 无法给每行不同 rowHeight。
            // 代价:失去行级懒加载。但月视图展开态下 6 行通常全部可见(等同 LazyVGrid 会渲染的量),
            // 仅在折叠态 + 小屏可能只看到 1-2 行——那时 ZStack 内 WeekStripCard 占据可见区,
            // 网格层 opacity 已淡到接近 0,SwiftUI 仍会构建但其开销可接受(42 格 × 简单 Text)。
            let alloc = allocation
            VStack(spacing: HomeLayoutMetrics.gridRowSpacing) {
                // id 用每周第一天:offset 会在翻月时复用(新月份第 0 周 offset 仍=0),
                // SwiftUI diff 认为"同一 id"不重建子视图,旧周 cell 的 @State(isDropTargeted)
                // 被新周继承 + alloc 结果延迟一帧应用。用周首日作 id 保证月份切换时
                // SwiftUI 识别为全新的 week identity,正确重建子树。
                ForEach(Array(alloc.weekGroups.enumerated()), id: \.element.first) { weekIndex, weekDays in
                    HStack(spacing: HomeLayoutMetrics.gridColumnSpacing) {
                        ForEach(weekDays, id: \.self) { day in
                            dayCell(day, maxBars: alloc.barsShown[weekIndex], rowHeight: alloc.rowHeights[weekIndex])
                        }
                    }
                    .frame(height: alloc.rowHeights[weekIndex])
                }
            }
        }
        // 水平 padding 用 xs（8）：七列格里中文条目宽度紧张（"要…"只能塞两三个字）,
        // 容器每侧 24pt padding 占去 ~12% 屏宽纯属浪费。降到 8pt 后每格多 ~4.5pt,
        // 中文条目大约能多塞一个字。格子本身已有白底 + 圆角 + 1px 描边,
        // 贴边视觉不会糊在一起。上方 headerView 仍保留水平 24pt padding（HomeView.swift:526）,
        // 形成"上呼吸、下铺满"的层次。
        .padding(.horizontal, HomeLayoutMetrics.monthGridPaddingHorizontal)
        .padding(.top, WarmSpacing.xxs)
        .padding(.bottom, WarmSpacing.sm)
        // 横向翻月：只识别水平主导（horizontal > vertical）且超过阈值的滑动。
        // 垂直方向的网格折叠由 monthHomeView 外层手势处理——
        // 两个手势都用 SimultaneousDragGesture(allow simultaneous)，可共存不互斥。
        .gesture(
            SimultaneousDragGesture(minimumDistance: HomeLayoutMetrics.periodDragThreshold) { drag in
                let vertical = abs(drag.translation.height)
                let horizontal = abs(drag.translation.width)
                guard horizontal > vertical,
                      horizontal > HomeLayoutMetrics.periodSwipeThreshold else { return }
                onShiftPeriod?(drag.translation.width < 0 ? 1 : -1)
            }
        )
    }

    /// 日期格:maxBars 由注水法分配器决定(忙周显示更多条),rowHeight 是该周行高。
    /// maxBars 在传入前夹紧到 [0...gridMaxBarsPerCell]:
    /// 分配器已保证不超过上限,但夹紧作为防御,防止未来分配器改动引入 >6 的值导致格子撑爆。
    /// 这是唯一调用 HomeMonthGridButton 的路径,clamping 集中在这里。
    @ViewBuilder
    private func dayCell(_ day: Date, maxBars: Int, rowHeight: CGFloat) -> some View {
        let dropCallback = onDropTodo.map { callback in { (id: UUID) in callback(id, day) } }
        let clampedBars = max(0, min(HomeLayoutMetrics.gridMaxBarsPerCell, maxBars))
        HomeMonthGridButton(
            dayState: state.dayState(for: day),
            onSelect: onSelectDay,
            onDropTodo: dropCallback,
            rowHeight: rowHeight,
            maxVisibleEvents: clampedBars
        )
    }
}

// MARK: - Home layout constants

enum HomeLayoutMetrics {
    /// 网格+月专属：网格占满几乎全部可用高度,留 5% 底部空白作为视觉缓冲。
    static let gridMonthFullHeightRatio: CGFloat = 0.95
    /// 网格+月单格最小行高。
    static let gridMonthMinRowHeight: CGFloat = 80
    /// 月历表头固定段高度（星期表头 + VStack spacing + padding）≈ 48pt。
    static let calendarFixedSectionHeight: CGFloat = 48
    /// 单行日期格最小高度。
    static let dayRowMinHeight: CGFloat = 22
    /// 底部 VoiceFAB 的可视高度：FAB 直径 + 底部 padding。
    static let bottomBarHeight: CGFloat = WarmSize.fab + WarmSpacing.md
    /// 底部列表渐隐只负责贴近底部浮动操作簇的过渡，不能覆盖到中部 todo 卡片。
    static let bottomListFadeHeight: CGFloat = 40
    /// 列表底部滚动留白。
    static let listBottomInset: CGFloat = bottomBarHeight + bottomListFadeHeight + WarmSpacing.xl
    /// 空状态 top inset。
    static let emptyStateTopInset: CGFloat = 80
    /// 网格折叠手势的最小跟踪距离(pt)。低于此值不派发 onChanged,防误触。
    static let collapseDragThreshold: CGFloat = 40
    /// 网格折叠的位移满量(pt):用户滑满此距离即 progress 0→1。
    /// 必须 > collapseDragThreshold,否则首帧 delta 立刻超 1。
    static let collapseTravelDistance: CGFloat = 80
    /// 松手时认定为"快速轻扫"的速度阈值(pt/s)。超过此值直接 snap 到目标端,
    /// 不走 progress>0.5 的位移判定。对齐 SwiftUI DragGesture 默认 minimumTouchDuration 语义。
    static let collapseFlickVelocity: CGFloat = 500
    /// 翻月水平滑动触发阈值(pt)。
    static let periodSwipeThreshold: CGFloat = 60
    /// 翻月手势的最小跟踪距离(pt)。略低于 periodSwipeThreshold,
    /// 保证达 60pt 触发前已开始跟踪,避免 UIKit 内置 ~10pt 阈值直接派发事件。
    static let periodDragThreshold: CGFloat = 40
    /// Calendar tab 列表可见/可点击的 progress 阈值:progress 高于此值才渲染
    /// HomeSelectedDayListView。opacity 与 allowsHitTesting 共用同一阈值,
    /// 避免"看得见但点不动"的交互死区。
    /// 0.3:对齐 opacity 视觉感受——progress<0.3 时网格几乎不透明(>70%),
    /// 列表即使渲染也基本不可见,提前挂载只浪费内存与初次 layout 开销。
    static let collapseListVisibleThreshold: CGFloat = 0.3

    // MARK: - Header 常量
    static let headerTitleRowHeight: CGFloat = 50
    static let viewSwitcherRowHeight: CGFloat = 38
    static let weeklySummaryRowHeight: CGFloat = 30

    // MARK: - MonthGrid(展开态月历网格)布局常量
    /// 月历网格容器水平 padding(= WarmSpacing.xs)。
    /// 刻意小于折叠态 WeekStripCard 的 24pt(xl)——此不对称是设计意图,不要为"对齐"改回 xl。
    /// 引用 WarmSpacing.xs 而非裸字面量,design system 调整 xs 时自动跟随。
    static let monthGridPaddingHorizontal: CGFloat = WarmSpacing.xs

    // MARK: - WeekStripCard(折叠态周条卡片)布局常量
    // 集中管理 WeekStripCard 内部布局字面量,调间距改这里,不散落在 View body 里。
    /// 卡片根 VStack spacing(7 天行 / 图例行 / 展开按钮)。
    static let weekStripSectionSpacing: CGFloat = 8
    /// 7 天行 HStack 列间距。
    static let weekStripDaySpacing: CGFloat = 4
    /// 单格 VStack(weekday / 圆 / 圆点)spacing。
    static let weekStripCellSpacing: CGFloat = 7
    /// 日期圆直径。
    static let weekStripCircleDiameter: CGFloat = 28
    /// 圆点直径(每个事件一个)。
    static let weekStripDotDiameter: CGFloat = 5
    /// 圆点行 spacing。
    static let weekStripDotSpacing: CGFloat = 3
    /// 圆点行区域固定高度(两行)。
    /// 2 * weekStripDotDiameter + 1 * weekStripDotSpacing = 2*5 + 3 = 13pt。
    /// 锁死高度避免完成/取消时 cell 高度抖动导致 HStack 内 7 天垂直对齐错位。
    /// 无论当天 1 个点还是 7 个点,都占这个高度——大多数天第二行会留空,换取视觉稳定。
    static let weekStripDotsAreaHeight: CGFloat = 13
    /// 图例 FlowLayout 横向间距(单项之间)。
    static let legendRowSpacing: CGFloat = 14
    /// 图例 FlowLayout 换行时的行间距。4pt 与 WarmSpacing.xxs 对齐,保持紧凑。
    static let legendRowVerticalSpacing: CGFloat = 4
    /// 图例单条(圆点 + 文字)spacing。
    static let legendItemSpacing: CGFloat = 5
    /// 图例圆点直径。
    static let legendDotDiameter: CGFloat = 6
    /// 图例文字字号。
    static let legendFontSize: CGFloat = 11
    /// 卡片 padding。
    static let weekStripPaddingHorizontal: CGFloat = 8
    static let weekStripPaddingTop: CGFloat = 12
    static let weekStripPaddingBottom: CGFloat = 10
    /// 展开按钮 HStack(文字 + chevron)spacing。
    static let weekStripExpandButtonSpacing: CGFloat = 5

    /// 月历展开态高度（容器封顶值）。
    static func calendarExpandedHeight(availableHeight: CGFloat, selectedTab: BottomTab) -> CGFloat {
        guard selectedTab == .calendar, availableHeight > 0 else { return 0 }
        return availableHeight * gridMonthFullHeightRatio
    }

    // MARK: - 注水法行高分配器常量
    /// 单条事件文字条高度(pt)。
    static let gridBarHeight: CGFloat = 14
    /// 事件条之间的垂直间距(pt)。
    static let gridBarSpacing: CGFloat = 2
    /// 每格固定开销(日数字行 + padding + border ≈ 20pt)。
    static let gridCellChrome: CGFloat = 20
    /// 网格行间距(pt)。
    static let gridRowSpacing: CGFloat = 2
    /// 网格列间距(pt)。
    static let gridColumnSpacing: CGFloat = 2
    /// 单格最多显示的事件条数上限(超出折叠为 +N)。
    static let gridMaxBarsPerCell: Int = 6

    /// 注水法行高分配(对齐 HTML month-view-allocator.html 的 allocate 函数)。
    ///
    /// 核心思路:忙的周行高更高,空的周更矮,但不会饿死任何一周。
    /// 1. 每周 demand = 该周最忙日的事件数(cap maxBarsPerCell)
    /// 2. 第一轮:给每个非空周分 1 条
    /// 3. 第二轮:反复提升"当前显示最少条数"的周(tie-break: 隐藏任务数更多优先)
    /// 4. 第三轮:剩余像素平均分给所有行,网格恰好填满
    static func allocateRowHeights(
        eventsPerDay: [[Int]],   // [周][日] = 事件数
        budgetHeight: CGFloat
    ) -> (rowHeights: [CGFloat], barsShown: [Int]) {
        let n = eventsPerDay.count
        guard n > 0 else { return ([], []) }

        let barH = gridBarHeight
        let gap = gridBarSpacing
        let chrome = gridCellChrome
        let rowGap = gridRowSpacing
        let cap = gridMaxBarsPerCell

        let avail = budgetHeight - rowGap * CGFloat(n - 1)

        // 每周 demand = 最忙日的事件数(上限 cap)
        let demand = eventsPerDay.map { week in
            min(cap, week.max() ?? 0)
        }

        var shown = Array(repeating: 0, count: n)

        func need(_ bars: Int) -> CGFloat {
            bars <= 0 ? chrome : chrome + CGFloat(bars) * barH + CGFloat(bars - 1) * gap
        }

        /// 从 shown[i] 到 shown[i]+1 的实际像素增量。
        /// 第 0→1 条:只加 barH(无前导 gap);后续每条:加 barH+gap。
        func increment(forCurrentShown cur: Int) -> CGFloat {
            cur == 0 ? barH : barH + gap
        }

        var used = need(0) * CGFloat(n)

        // Pass 1: 给每个非空周分 1 条
        for i in 0..<n {
            let inc = increment(forCurrentShown: shown[i])
            if demand[i] > 0 && used + inc <= avail {
                shown[i] = 1
                used += inc
            }
        }

        // Pass 2: 注水——反复提升当前最少条数的周
        while true {
            var best = -1
            var bestShown = Int.max
            var bestHidden = -1
            for j in 0..<n {
                if shown[j] >= demand[j] { continue }
                let inc = increment(forCurrentShown: shown[j])
                if used + inc > avail { continue }
                let hidden = eventsPerDay[j].reduce(0) { $0 + max(0, $1 - shown[j]) }
                if shown[j] < bestShown || (shown[j] == bestShown && hidden > bestHidden) {
                    bestShown = shown[j]
                    bestHidden = hidden
                    best = j
                }
            }
            if best < 0 { break }
            used += increment(forCurrentShown: shown[best])
            shown[best] += 1
        }

        // Pass 3: 剩余像素平均分,填满屏幕
        var rows = shown.map(need)
        let sum = rows.reduce(0, +)
        let slack = avail - sum
        if slack > 0 {
            let per = floor(slack / CGFloat(n))
            rows = rows.map { $0 + per }
            var rem = Int((slack - per * CGFloat(n)).rounded())
            var k = 0
            while rem > 0 {
                rows[k] += 1
                rem -= 1
                k = (k + 1) % n
            }
        }

        return (rows, shown)
    }

    static func dayRowHeight(availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return WarmSpacing.xxxl }
        let rows: CGFloat = 6
        let usable = max(0, availableHeight - calendarFixedSectionHeight - gridSpacing(forRows: rows))
        return max(dayRowMinHeight, max(usable / rows, gridMonthMinRowHeight))
    }

    private static func gridSpacing(forRows rows: CGFloat) -> CGFloat {
        WarmSpacing.xs * max(0, rows - 1)
    }
}

// MARK: - Week strip card (折叠态周条)

/// 折叠态的周条卡片:7 天 + 圆点 + 图例 + "展开整月"按钮。
/// 对齐竞品 HTML 参考稿:白色卡片容器 + border + 圆角,格子内用圆点不用横条。
struct WeekStripCard: View {
    let state: HomeCalendarState
    let onSelectDay: (Date) -> Void
    let onExpand: () -> Void

    /// 本周的 7 天(周一起始)。委托给 HomeCalendarState.weekDays 静态方法,单一来源。
    private var weekDays: [Date] {
        HomeCalendarState.weekDays(for: state.selectedDate, calendar: state.calendar)
    }

    /// 本周出现过的所有**未完成**分类(含昨天/前天等本周内任意一天的未完成项)。
    /// 委托给 HomeCalendarState.categoriesInWeek。与圆点行口径完全一致:
    /// 圆点行按天显示当天未完成类型的色,图例展示本周所有未完成类型,两者同步增减。
    private var weekCategories: [TodoCategory] {
        state.categoriesInWeek(of: state.selectedDate)
    }

    var body: some View {
        VStack(spacing: HomeLayoutMetrics.weekStripSectionSpacing) {
            // 7 天
            HStack(spacing: HomeLayoutMetrics.weekStripDaySpacing) {
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day)
                }
            }

            // 图例:本周出现过的所有分类。点其他周/切 backlog 会跟着变。
            // FlowLayout 换行 + 居中:5+ 项时自动换到第二行,每行在卡片宽度内水平居中。
            // 字体用 `.system` 而非 WarmFont.caption:后者底层是 Avenir Next(纯拉丁),
            // 中文回落到 PingFang SC 后视觉偏小;.system 在中英混排下 cap-height 对齐、视觉一致。
            if !weekCategories.isEmpty {
                FlowLayout(
                    horizontalSpacing: HomeLayoutMetrics.legendRowSpacing,
                    verticalSpacing: HomeLayoutMetrics.legendRowVerticalSpacing,
                    alignment: .center
                ) {
                    ForEach(weekCategories, id: \.self) { cat in
                        HStack(spacing: HomeLayoutMetrics.legendItemSpacing) {
                            Circle()
                                .fill(WarmTheme.color(for: cat))
                                .frame(width: HomeLayoutMetrics.legendDotDiameter,
                                       height: HomeLayoutMetrics.legendDotDiameter)
                            Text(cat.displayName)
                                .font(.system(size: HomeLayoutMetrics.legendFontSize, weight: .regular))
                                .foregroundColor(WarmTheme.textMuted)
                        }
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // 展开整月
            Button {
                onExpand()
            } label: {
                HStack(spacing: HomeLayoutMetrics.weekStripExpandButtonSpacing) {
                    Text(String(localized: "home.week.expand_month"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HomeLayoutMetrics.weekStripPaddingHorizontal)
        .padding(.top, HomeLayoutMetrics.weekStripPaddingTop)
        .padding(.bottom, HomeLayoutMetrics.weekStripPaddingBottom)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(WarmTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .stroke(WarmTheme.sketch.opacity(0.12), lineWidth: 1)
        )
        .accessibilityIdentifier("WeekStripCard")
    }

    private func dayCell(_ day: Date) -> some View {
        let dayState = state.dayState(for: day)
        let dayKey = TodoOccurrenceData.dayKey(for: day, calendar: state.calendar)
        let occurrences = state.occurrencesByDay[dayKey] ?? []
        return Button {
            onSelectDay(day)
        } label: {
            VStack(spacing: HomeLayoutMetrics.weekStripCellSpacing) {
                Text(state.weekdayTitle(for: day))
                    .font(WarmFont.caption(11))
                    .foregroundColor(dayState.isToday ? WarmTheme.primary : WarmTheme.textMuted)
                    .fixedSize()

                ZStack {
                    if dayState.isSelected {
                        Circle().fill(WarmTheme.primary)
                    } else if dayState.isToday {
                        Circle().fill(WarmTheme.primary.opacity(0.18))
                    }
                    Text("\(dayState.dayNumber)")
                        .font(WarmFont.mono(15))
                        .foregroundColor(
                            dayState.isSelected ? .white :
                            (dayState.isToday ? WarmTheme.primaryDark : WarmTheme.textPrimary)
                        )
                        .fixedSize()
                }
                .frame(width: HomeLayoutMetrics.weekStripCircleDiameter,
                       height: HomeLayoutMetrics.weekStripCircleDiameter)

                // 圆点:按"类型"去重,不是按每条待办。当天有哪几种未完成类型,就画哪几个对应颜色的点。
                // 同类型多条未完成只画一个点(丢失"同类型任务密度"信息,换取与图例口径一致)。
                // 顺序按 TodoCategory.allCases 固定排序,与图例一致——避免不同天同色点位置跳动。
                // FlowLayout 自适应换行:7 种类型全有时自动排成两行(一行约容 6 个点)。
                // 固定两行高度(weekStripDotsAreaHeight)锁死,即使当天只有 1 个点也留两行空间,
                // 避免完成/取消时 cell 高度抖动导致 HStack 内 7 天垂直对齐错位。
                let uncompletedCategories: [TodoCategory] = TodoCategory.allCases.filter { cat in
                    occurrences.contains { $0.todo.category == cat && !$0.isCompleted }
                }
                FlowLayout(
                    horizontalSpacing: HomeLayoutMetrics.weekStripDotSpacing,
                    verticalSpacing: HomeLayoutMetrics.weekStripDotSpacing,
                    alignment: .center
                ) {
                    ForEach(uncompletedCategories, id: \.self) { cat in
                        Circle()
                            .fill(WarmTheme.color(for: cat)
                                .opacity(WarmTheme.activeEventOpacity))
                            .frame(width: HomeLayoutMetrics.weekStripDotDiameter,
                                   height: HomeLayoutMetrics.weekStripDotDiameter)
                    }
                }
                .frame(height: HomeLayoutMetrics.weekStripDotsAreaHeight)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// VoiceOver 文案构造：把日历单元格的状态翻译成完整一句话。
/// 月视图单元格视觉信息（数字、点、底色）对低视力/盲人用户没用，必须用文字补全。
/// 顺序遵循可达性惯例：身份（日期）在前，状态（非当月/今天/待办数）在后。
/// 使用 app 当前本地化语言 + gregorian 日历格式化日期，避免系统区域语言与 app 文案混读。
