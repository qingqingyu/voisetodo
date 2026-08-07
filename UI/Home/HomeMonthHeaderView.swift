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
    /// 点击月格事件条 → 打开 todo 详情。nil = 事件条不可点。
    /// 透传给 HomeMonthGridButton.onOpenTodo。
    var onOpenTodo: ((TodoItemData) -> Void)? = nil
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
            // weekday 标签行:居中对齐,与下方日期格内居中的日数字对齐(Apple Calendar 式布局:
            // 日数字居中在格子顶部,事件条左对齐填满宽度)。weekday 中心和日数字中心都在列中心。
            // spacing 必须与下方格子行 (gridColumnSpacing=2) 一致:7 列等宽分配,
            // spacing 不同会逐位累积偏移,weekday 不在对应格子正上方。
            HStack(spacing: HomeLayoutMetrics.gridColumnSpacing) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(9))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
        // 水平 padding 用 xxs(4):七列格里中文条目宽度紧张("要…"只能塞两三个字),
        // 容器每侧 24pt padding 占去 ~12% 屏宽纯属浪费。从 24pt 一路降到 4pt 后,
        // 相比 8pt 再多 ~4pt 可用宽度(每格 +0.57pt,中文条目约多塞 0.5 个字)。
        // 留 4pt 不归零:防边格被 iPhone 屏幕圆角裁切、避免格子贴屏幕边显得溢出。
        // 纯留白方案:格子无独立白底/描边,贴边靠 4pt 边距 + 事件条自身圆角区分。
        // 上方 headerView 仍保留水平 24pt padding(WarmSpacing.xl),形成"上呼吸、下铺满"的层次。
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

    /// 日期格:maxBars 由注水法分配器决定(动态 cap,跟着每行物理高度走),rowHeight 是该周行高。
    /// maxBars 在传入前夹紧到 [0...gridMaxBarsPerCellHardLimit]:
    /// 分配器已保证不超过上限,但夹紧作为防御,防止未来分配器改动引入超大的值导致格子撑爆。
    /// 这是唯一调用 HomeMonthGridButton 的路径,clamping 集中在这里。
    @ViewBuilder
    private func dayCell(_ day: Date, maxBars: Int, rowHeight: CGFloat) -> some View {
        let dropCallback = onDropTodo.map { callback in { (id: UUID) in callback(id, day) } }
        let clampedBars = max(0, min(HomeLayoutMetrics.gridMaxBarsPerCellHardLimit, maxBars))
        HomeMonthGridButton(
            dayState: state.dayState(for: day),
            onSelect: onSelectDay,
            onDropTodo: dropCallback,
            rowHeight: rowHeight,
            maxVisibleEvents: clampedBars,
            onOpenTodo: onOpenTodo
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
    /// 悬浮 FAB 的实心占地(不含柔性光晕)。
    /// 组成:WarmSize.fab(按钮直径) + WarmSpacing.md * 2
    ///   - 一份 md = VoiceFAB 自身 .padding(.bottom),让按钮浮在 home indicator 上方
    ///   - 一份 md = 最后一张卡底边到 FAB 按钮顶边的可读间隙
    /// 2026-07-27 注:VoiceFAB 改为悬浮 overlay 后,光晕不占 safeAreaInset,
    /// 此值仅用于:1) List contentMargins 底部留白;2) 渐隐带高度;3) 月网格 expand 态扣减。
    static let bottomBarHeight: CGFloat = WarmSize.fab + WarmSpacing.md * 2
    /// 底部列表渐隐高度:独立常量,用于 LinearGradient 遮罩高度。
    /// 需覆盖整个悬浮 FAB,卡片才能从按钮背后穿过并溶入背景,
    /// 而不是从按钮左右两侧半露出来。当前与 bottomBarHeight 等值。
    static let bottomListFadeHeight: CGFloat = bottomBarHeight
    /// 列表底部滚动留白:静止滚到底时,最后一张卡完整可读,不被 FAB 遮。
    /// 悬浮改造后此值 = bottomBarHeight(fadeHeight 不再叠加进 inset,
    /// 渐隐只负责视觉过渡,不负责推高列表最后一项的位置)。
    static let listBottomInset: CGFloat = bottomBarHeight
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
    /// 月历网格容器水平 padding(= WarmSpacing.xxs = 4pt)。
    /// 刻意小于折叠态 WeekStripCard 的外层 20pt(HomeView 里 .padding(.horizontal, .lg))——
    /// 此不对称是设计意图,不要为"对齐"改回 lg。
    /// 4pt 比原来 8pt(xs)再多 ~4pt 可用宽度(每格 +0.57pt,7 列中文条目约多塞 0.5 个字),
    /// 同时仍留极少边距,避免边格被 iPhone 屏幕圆角裁切、不让格子贴屏幕边显得溢出。
    /// 引用 WarmSpacing.xxs 而非裸字面量,design system 调整 xxs 时自动跟随。
    static let monthGridPaddingHorizontal: CGFloat = WarmSpacing.xxs

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

    /// 月历展开态高度（容器封顶值）。
    /// 2026-07-27 注:VoiceFAB 改为悬浮 overlay 后,root ZStack 不再被 safeAreaInset
    /// 砍掉底部 144pt(旧 bottomBarHeight),传给本函数的 availableHeight 相应变大。
    /// 需先扣掉 listBottomInset 再取比例,否则月网格底行会伸进 FAB 区域。
    /// 当 availableHeight ≤ listBottomInset(极小窗口/横屏小高度)时返回 0,
    /// 月网格让位给列表 —— 由调用方决定是否回退到周视图。
    static func calendarExpandedHeight(availableHeight: CGFloat, selectedTab: BottomTab) -> CGFloat {
        guard selectedTab == .calendar, availableHeight > listBottomInset else { return 0 }
        return (availableHeight - listBottomInset) * gridMonthFullHeightRatio
    }

    // MARK: - 注水法行高分配器常量
    /// 单条事件文字条高度(pt),容纳两行 9pt 标题。
    static let gridBarHeight: CGFloat = 24
    /// 事件条之间的垂直间距(pt)。
    static let gridBarSpacing: CGFloat = 2
    /// 每格固定开销(日数字行 + padding ≈ 20pt)。
    static let gridCellChrome: CGFloat = 20
    /// 网格行间距(pt)。
    /// 纯留白方案:去卡片描边后唯一分隔手段是间距。8pt(= WarmSpacing.xs)对齐 Notion Calendar
    /// 周间留白感;再大会吃掉预算导致 barsShown 减少,再小则周与周贴在一起失去层级。
    /// 列间用 gridColumnSpacing(2pt),不改——列宽紧张(中文事件条),2pt 已够。
    static let gridRowSpacing: CGFloat = 8
    /// 网格列间距(pt)。
    static let gridColumnSpacing: CGFloat = 2
    /// 单格事件条数的**硬上限**(防极端屏幕尺寸导致 cap 过大)。
    /// 实际显示上限由下方 `allocateRowHeights` 内的 `estimatedCap` 根据每行物理高度反推,
    /// 这里只作为天花板。15 对应格子高度 408pt(need(15) = gridCellChrome + 15*gridBarHeight + 14*gridBarSpacing
    /// = 20 + 360 + 28 = 408),仅在超大屏 + 1~2 周的极端月份下被命中。正常月份下 estimatedCap 才是实际生效值。
    static let gridMaxBarsPerCellHardLimit: Int = 15

    /// 注水法行高分配(对齐 HTML month-view-allocator.html 的 allocate 函数)。
    ///
    /// 核心思路:忙的周行高更高,空的周更矮,但不会饿死任何一周。
    /// 1. **估算 cap**:用平均行高(avail/n)反推能容几条事件条,作为 Pass 1+2 注水的
    ///    `initialDemand` 上限。用途:防止单周抢光预算(一个 15 条事件的周不该饿死其他周)。
    /// 2. **真实 demand**:每周最忙日的事件数,只受 `gridMaxBarsPerCellHardLimit` 截断。
    ///    不被估算 cap 砍——Pass 3a 直接按 realDemand 继续,避免"行高被撑高后却仍卡在估算上限"。
    /// 3. Pass 1:给每个非空周分 1 条
    /// 4. Pass 2:注水,受 initialDemand 约束,反复提升"当前显示最少条数"的周
    ///    (tie-break: 隐藏任务数更多优先)
    /// 5. Pass 3a (新增):剩余像素优先给还有真实隐藏事件的周继续加条,不受 initialCap 砍
    /// 6. Pass 3b:Pass 3a 因 slack 不够一条完整 bar 中断时,把剩余 slack 平均分给
    ///    还有隐藏事件的周(空周不参与,保持自然高度)。所有周都已满足时退化为平均分,保证网格填满屏幕
    /// 7. Pass 4 (新增):按 Pass 3 最终行高回补 shown——Pass 3b 给的 slack 可能让某周
    ///    正好多装一条,这里按真实 rows[i] 反推 actualCap 把 shown 拉满
    ///
    /// 修复历史:原算法 Pass 3 平均撒 slack,出现"格子高度够装 4 条却只显示 2 条"的视觉 bug
    /// (估算 cap 把 demand 砍到 2,Pass 3 撑高行高却没回头加条),用户 2026-07-26 反馈。
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

        let avail = budgetHeight - rowGap * CGFloat(n - 1)

        // 真实需求:每周最忙日的事件数,只受 hardCap 截断(防极端屏幕 15 条以上)。
        // 这是 Pass 3a / Pass 4 用的 demand——不受估算 cap 砍。
        let realDemand = eventsPerDay.map { week in
            min(gridMaxBarsPerCellHardLimit, week.max() ?? 0)
        }

        // 估算 cap:用平均行高反推,作为 Pass 1+2 注水的 demand 上限。
        // need(N) = chrome + N*barH + (N-1)*gap = (chrome - gap) + N*(barH + gap)
        // 反推 N = (rowHeight - chrome + gap) / (barH + gap)
        // 4 周的月每行高度大 → cap 大,6 周的月 → cap 小。
        // 估算 cap 只用于防止 Pass 2 注水阶段一忙周抢光预算;Pass 3a 之后用 realDemand 不再受此约束。
        let estimatedRowHeight = avail / CGFloat(n)
        let estimatedCap = max(0, Int((estimatedRowHeight - chrome + gap) / (barH + gap)))
        let initialDemand = realDemand.map { min(estimatedCap, $0) }

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

        // Pass 1: 给每个非空周分 1 条(受 initialDemand 约束)
        for i in 0..<n {
            let inc = increment(forCurrentShown: shown[i])
            if initialDemand[i] > 0 && used + inc <= avail {
                shown[i] = 1
                used += inc
            }
        }

        // Pass 2: 注水——反复提升当前最少条数的周(受 initialDemand 约束)
        while true {
            var best = -1
            var bestShown = Int.max
            var bestHidden = -1
            for j in 0..<n {
                if shown[j] >= initialDemand[j] { continue }
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

        // 计算进入 Pass 3 的初始 rows 和 slack
        var rows = shown.map(need)
        var slack = avail - rows.reduce(0, +)

        // Pass 3a (新增): slack 优先给还有真实隐藏事件的周继续加条。
        // 这里是「高度够却显示少」bug 的核心修复:Pass 2 因 estimatedCap 估算偏低
        // 导致 initialDemand 被砍,这里用 realDemand 把条数补回来。
        // 同时实现「忙的周高、空的周矮」——空周(realDemand=0)没隐藏事件,
        // 自然不参与加条,它们的 slack 流向忙周。
        //
        // 复杂度:O(n × Σ realDemand),n≤6 且 Σ realDemand ≤ 6*hardCap=90 → 最坏 540 步,可接受。
        //
        // 两个 break 出口:
        //   (a) best<0 —— 所有周吃满 realDemand,后续 Pass 3b 的 weeksWithHidden 必为空,走平摊 fallback
        //   (b) slack<inc —— slack 不够一条完整 bar,但仍有周 realDemand>shown,Pass 3b 的 weeksWithHidden 非空
        while slack > 0 {
            // 选当前隐藏事件最多的周;tie-break:shown 最少优先(与 Pass 2 注水哲学一致),
            // 仍并列时取 index 最小(稳定排序)
            var best = -1
            var bestHidden = 0
            var bestShown = Int.max
            for j in 0..<n {
                let hidden = realDemand[j] - shown[j]
                if hidden <= 0 { continue }
                if hidden > bestHidden
                    || (hidden == bestHidden && shown[j] < bestShown) {
                    bestHidden = hidden
                    bestShown = shown[j]
                    best = j
                }
            }
            if best < 0 { break }  // 出口 (a)

            let inc = increment(forCurrentShown: shown[best])
            guard slack >= inc else { break }  // 出口 (b)
            shown[best] += 1
            rows[best] = need(shown[best])
            slack -= inc
        }

        // Pass 3b: Pass 3a 出口 (b) 时,把剩余 slack 平均分给还有隐藏事件的周——
        // 它们行高再补一点,Pass 4 可能正好够多装一条。
        // 没有隐藏事件的周不参与分配(空周保持 need(shown) 自然高度)。
        // 极端 fallback(出口 a):所有周都已满足时,slack 平摊到所有周,保证网格仍填满屏幕
        // (此时多余空间无法转化为条,平摊是最不破坏视觉的选择)。
        if slack > 0 {
            let weeksWithHidden = (0..<n).filter { realDemand[$0] > shown[$0] }
            let recipients = weeksWithHidden.isEmpty ? Array(0..<n) : weeksWithHidden
            let per = floor(slack / CGFloat(recipients.count))
            for i in recipients {
                rows[i] += per
            }
            var rem = Int((slack - per * CGFloat(recipients.count)).rounded())
            var k = 0
            while rem > 0 {
                rows[recipients[k % recipients.count]] += 1
                rem -= 1
                k += 1
            }
        }

        // Pass 4 (新增): 按真实行高回补 shown。
        // Pass 3b 给的 slack 可能让某周正好多装一条(实际高度 ≥ need(shown+1)),
        // 这里按真实 rows[i] 反推 actualCap 把 shown 拉满。
        // 数学保证安全:need(actualCap) ≤ rows[i] 恒成立。
        // 证明:actualCap = floor((rows[i] - chrome + gap) / (barH + gap))
        //      ≤ (rows[i] - chrome + gap) / (barH + gap)
        //   ⇒ need(actualCap) = chrome + actualCap*barH + (actualCap-1)*gap
        //                      = (chrome - gap) + actualCap*(barH + gap)
        //                      ≤ (chrome - gap) + (rows[i] - chrome + gap) = rows[i]  ∎
        for i in 0..<n where realDemand[i] > shown[i] {
            let actualCap = max(0, Int((rows[i] - chrome + gap) / (barH + gap)))
            // precondition(而非 assert):Release build 也守护不变量。
            // 不变量被破坏 = 算法逻辑错误,应当显式崩溃而非静默错排版本。
            precondition(need(actualCap) <= rows[i], "Pass 4 invariant violated: need(\(actualCap))=\(need(actualCap)) > rows[\(i)]=\(rows[i])")
            shown[i] = min(actualCap, realDemand[i])
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
        gridRowSpacing * max(0, rows - 1)
    }
}

/// 测量 WeekStripCard 的实际渲染高度,上报给父容器(HomeView 的折叠态 ZStack)。
/// 折叠态容器高度(collapsedHeight)原本按"月网格表头 + 单行图例"预估,固定为
/// calendarFixedSectionHeight + actualRowHeight。当本周 7 种类型齐全、图例 FlowLayout
/// 换到第二行时,卡片实际高度会超出该固定值,被外层 .clipped() 裁切——表现为最后一项
/// ("Other")被盖住、卡片底部圆角被直角框切平。父容器取 max(原值, 实测高度) 即可容纳。
/// 跟 `UI/ConfirmSheet/ConfirmSheetView.swift` 的 `SheetContentHeightKey` 同套路。
struct WeekStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Week strip card (折叠态周条)

/// 折叠态的周条卡片:7 天 + 圆点 + 图例。
/// 对齐竞品 HTML 参考稿:白色卡片容器 + border + 圆角,格子内用圆点不用横条。
///
/// **展开整月入口**:可见按钮已删除(用户通过下拉手势展开,首次由 `ExpandMonthHintView` 引导)。
/// `onExpand` 保留——仅供 VoiceOver `accessibilityAction` 兜底使用,盲人用户仍可通过
/// 双击"展开整月"动作触发展开,避免动画引导对 VoiceOver 不可见导致的可达性回退。
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

            // "展开整月"按钮已删除:可见入口由下拉手势承担,首次由 ExpandMonthHintView 引导。
            // onExpand 保留作为 VoiceOver 兜底入口(accessibilityAction)——盲人用户无法看到引导动画,
            // 仍需一个语义化动作触发展开。
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
        .accessibilityAction(named: String(localized: "a11y.action.expand_month")) {
            onExpand()
        }
        .accessibilityHint(String(localized: "a11y.week_strip.hint"))
        .accessibilityIdentifier("WeekStripCard")
        // 测量卡片实际高度上报父容器。放在所有修饰符最外层,
        // 测的是经过 padding/background/overlay 后的最终渲染高度,
        // 与父容器 .frame(height:).clipped() 看到的尺寸一致。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: WeekStripHeightKey.self, value: proxy.size.height)
            }
        )
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
                    .font(WarmFont.caption(9))
                    .foregroundColor(dayState.isToday ? WarmTheme.primary : WarmTheme.textMuted)
                    .fixedSize()

                ZStack {
                    if dayState.isSelected {
                        Circle().fill(WarmTheme.primary)
                    } else if dayState.isToday {
                        Circle().fill(WarmTheme.primary.opacity(0.18))
                    }
                    Text(verbatim: "\(dayState.dayNumber)")
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
                // 双层防御竖排回归 —— FlowLayout 内部已对 < 1pt / nil 宽度 proposal 做兜底
                // (sizeThatFits 把 < 1pt 视为 .infinity;placeSubviews 检测 cache 与 bounds
                // 不一致时重算),不需要外层撑宽。此处 .frame(maxWidth: .infinity) 仍保留
                // 作为冗余:SwiftUI Layout 协议在不同 iOS 版本下 cache 复用行为不稳定,
                // 任何一层失效时另一层兜底,避免再次回归(commit 6a3564b 单层修法已回归过)。
                .frame(height: HomeLayoutMetrics.weekStripDotsAreaHeight)
                .frame(maxWidth: .infinity)
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
