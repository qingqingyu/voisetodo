import SwiftUI
import UIKit

struct HomeMonthHeaderView: View {
    let state: HomeCalendarState
    let onSelectDay: (Date) -> Void
    /// 从 Unscheduled 拖任务到日期格时触发（UUID = 任务，Date = 格子日期）。
    var onDropTodo: ((UUID, Date) -> Void)? = nil
    /// 左右滑翻月/翻周回调：参数 +1 = 下一月/周，-1 = 上一月/周。
    /// 手势挂在本视图（日历区域）本身——挂在这里的 recognizer，
    /// 其 host view 的 bounds 只覆盖日历区，起点天然在日历区，不需要 startLocation 判定。
    /// 历史：原手势挂在 monthHomeView 外层 VStack 上，用 `drag.startLocation.y <= calendarHeight`
    /// 做起点门控，但 host view 实际覆盖整个屏幕（随机型变化，典型值 ~800pt），startLocation.y
    /// 是屏幕坐标，与基于 monthHomeView 高度算出的 calendarHeight 不可比，导致判定永远 false、左右滑失效。
    ///
    /// 调用方契约：本视图自带手势在 `onShiftPeriod != nil` 时始终激活,Header **不做 tab 守卫**——
    /// 外层(HomeView.monthHomeView)必须仅在 `selectedBottomTab == .calendar` 时渲染本视图,
    /// 否则「今日」tab 误挂载时左右滑仍会触发翻月。
    var onShiftPeriod: ((Int) -> Void)? = nil
    /// 可用高度（来自 GeometryReader）。0 = 不约束，用默认行高。
    var availableHeight: CGFloat = 0
    /// 显示样式：`.list` 用 `HomeMonthDayButton`（数字+圆点），`.grid` 用 `HomeMonthGridButton`（数字+事件条）。
    /// 默认 `.list` 保持现有调用方零改动。
    var displayMode: CalendarDisplayMode = .list
    /// Header 收起进度,由 HomeView.headerCollapseProgress 注入(0=全展开、1=全收)。
    /// 作用范围仅 list+week 分支:weekday 标签行淡出+收缩、日期圆行轻微压扁(48→44)。
    /// grid 模式和 month 模式短路(不收),与 `calendarHeight` 的分支策略一致。
    var collapseProgress: Double = 0

    /// 根据可用高度计算日期格行高。
    /// 固定段（星期表头 + spacing + padding）≈ 48pt（见 calendarFixedSectionHeight）；
    /// 剩余空间平分给网格行（月视图 6 行 / 周视图 1 行）。
    /// availableHeight = 0 时回退到默认 WarmSpacing.xxxl（48pt）。
    /// 注：月份标题 + 翻月按钮已合并进页头（HomeView.headerView），卡片内不再有导航行。
    /// week 模式下随 collapseProgress 轻微压扁(48→44),配合 calendarHeight 96→44 的插值;
    /// month 模式不压(日历网格用户要看)。
    private var dayRowHeight: CGFloat {
        let base = HomeLayoutMetrics.dayRowHeight(availableHeight: availableHeight, viewMode: state.viewMode, displayMode: displayMode)
        guard state.viewMode == .week else { return base }
        return base - HomeLayoutMetrics.weekCollapseRowShrink * CGFloat(collapseProgress)
    }

    var body: some View {
        VStack(spacing: WarmSpacing.xs * (1 - CGFloat(collapseProgress))) {
            // weekday 标签行(周一/周二/...):拖拽时整体淡出 + 高度收缩到 0。
            // 用户原话「周日期条吸顶变成一个紧凑的 44pt 条」= 只留日期圆,weekday 行消失。
            HStack(spacing: WarmSpacing.xs) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .opacity(1 - CGFloat(collapseProgress))
            .frame(height: HomeLayoutMetrics.calendarFixedSectionHeight * (1 - CGFloat(collapseProgress)), alignment: .top)
            .clipped()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: WarmSpacing.xs), count: 7), spacing: WarmSpacing.xs) {
                ForEach(state.visibleDays, id: \.self) { day in
                    dayCell(for: day)
                }
            }
        }
        // 水平 padding 用 xl（24）与页头对齐——旧值 lg（20）导致网格与大标题左缘错位 4pt。
        // 导航行删除后卡片直接坐在纸纹背景上，不再需要垫底色。
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.xxs)
        .padding(.bottom, WarmSpacing.sm)
        // 横向翻月/翻周：只识别水平主导（horizontal > vertical）且超过阈值的滑动。
        // 垂直方向的月/周视图切换由 monthHomeView 外层 VStack 上的另一个手势处理——
        // 两个手势都用 SimultaneousDragGesture(allow simultaneous)，可共存不互斥。
        // 用 SimultaneousDragGesture 而非原生 .simultaneousGesture 的原因见
        // SimultaneousDragGesture.swift 头注释（iOS 26+ FB18199844 回归）。
        .gesture(
            SimultaneousDragGesture(minimumDistance: HomeLayoutMetrics.viewModeDragThreshold) { drag in
                let vertical = abs(drag.translation.height)
                let horizontal = abs(drag.translation.width)
                guard horizontal > vertical,
                      horizontal > HomeLayoutMetrics.periodSwipeThreshold else { return }
                onShiftPeriod?(drag.translation.width < 0 ? 1 : -1)
            }
        )
    }

    /// 根据 displayMode 选格子：list=数字+圆点 / grid=数字+事件条。
    /// 两种 button 共用相同的 onSelect/onDropTodo/rowHeight 契约，调用方无需感知。
    @ViewBuilder
    private func dayCell(for day: Date) -> some View {
        let dropCallback = onDropTodo.map { callback in { (id: UUID) in callback(id, day) } }
        switch displayMode {
        case .list:
            HomeMonthDayButton(
                dayState: state.dayState(for: day),
                onSelect: onSelectDay,
                onDropTodo: dropCallback,
                rowHeight: dayRowHeight
            )
        case .grid:
            HomeMonthGridButton(
                dayState: state.dayState(for: day),
                onSelect: onSelectDay,
                onDropTodo: dropCallback,
                rowHeight: dayRowHeight
            )
        }
    }
}

// MARK: - Home layout constants

enum HomeLayoutMetrics {
    /// 月历区域目标上限比例。改版从 0.38 提到 0.44：导航行合并进页头后卡片内容变少，
    /// 多出的比例全部转成日期格行高（典型机型 ~19pt → ~32pt），圆形高亮和待办圆点有了呼吸空间。
    /// 不超过 ~0.46——列表仍是主界面，保住 ≥56% 高度。
    static let calendarTargetHeightRatio: CGFloat = 0.44
    /// 网格模式（displayMode == .grid）月历区目标上限比例。
    /// 比列表模式（0.44）高，因为每格要容纳「数字 + ≤2 事件条 + `+N`」结构，至少 ~80pt 行高 × 6 行 ≈ 480pt。
    /// 不超过 0.72——给底部输入面板/列表留 ≥28% 高度，避免完全无空间。
    /// 网格+周（WeekTimelineView）也走这个比例：时间轴需要垂直滚动空间。
    static let gridCalendarTargetHeightRatio: CGFloat = 0.70
    /// 网格+月专属：网格下方不渲染列表(HomeSelectedDayListView 跳过),
    /// 月历可占满几乎全部可用高度,留 5% 底部空白作为视觉缓冲
    /// (避免紧贴底部 safe area / FAB 区域)。
    static let gridMonthFullHeightRatio: CGFloat = 0.95
    /// 网格+月单格最小行高。每格内容预算：数字(14pt) + 2×事件条(14pt + spacing 2pt) + `+N`(10pt) ≈ 70pt + 余量。
    /// 取 80pt 作为舒适下限；极矮屏算出的可用高度不足时按此兜底，宁可底部裁切也不压扁事件条。
    static let gridMonthMinRowHeight: CGFloat = 80
    /// 月历表头固定段高度（星期表头 + VStack spacing + padding）。
    /// 拆解：weekday(16) + VStack spacing(WarmSpacing.xs≈8)
    ///       + top/bottom padding(xxs+sm≈16) + 动态字体浮动余量(~8) ≈ 48pt 保守上限。
    /// （导航行已删除：月份标题居中在页头，翻页改为日历区域左右横滑。）
    /// 低估会导致 calendarHeight 算出比实际小，底部日期行被 `.clipped()` 裁切（Bug 1 根因）。
    static let calendarFixedSectionHeight: CGFloat = 48
    /// 单行日期格最小高度：保证 14pt 日期数字 + 缩小后的选中圆可读（旧值 14 只顾数字）。
    static let dayRowMinHeight: CGFloat = 22
    /// 底部 VoiceFAB 的可视高度：FAB 直径 + 底部 padding。
    static let bottomBarHeight: CGFloat = WarmSize.fab + WarmSpacing.md
    /// 底部列表渐隐只负责贴近底部浮动操作簇的过渡，不能覆盖到中部 todo 卡片。
    static let bottomListFadeHeight: CGFloat = 40
    /// 列表底部滚动留白，用 contentMargins 作用在真实 scroll content 上，而不是追加假 Section。
    /// 组成：底部操作簇高度 + 渐隐区 + 额外呼吸空间，确保最后一项能完整停在按钮上方。
    /// 调参规则：
    /// - 改 VoiceFAB 布局（直径、padding）时必须重新测量 safeAreaInset 实占高度。
    static let listBottomInset: CGFloat = bottomBarHeight + bottomListFadeHeight + WarmSpacing.xl
    /// 空状态 top inset：加大让内容接近屏幕视觉中心（~40-45% 高度）。
    static let emptyStateTopInset: CGFloat = 80
    /// 月/周视图切换的拖拽阈值（pt）。手势 minimumDistance 用此值——超过才开始跟踪。
    /// 避免点击按钮或日期格时的轻微滑动误触发。
    static let viewModeDragThreshold: CGFloat = 40
    /// 月/周视图切换的实际触发阈值（pt）。必须明显高于此值才算"有意切换"而非"普通滚动"。
    /// 全屏手势下列表也在同一个 VStack——80pt 区分有意切换和普通列表滚动。
    static let viewModeSwitchThreshold: CGFloat = 80
    /// 翻月/翻周的水平滑动触发阈值（pt）。
    /// 低于 viewModeSwitchThreshold(80)：水平方向与列表滚动（垂直）不冲突，无需同等防误触余量；
    /// 高于 viewModeDragThreshold(40)：避免点按日期格时的斜向抖动误翻页。
    /// 注：位移取原始视图坐标，未按 layoutDirection 翻转——app 目前只有 zh/en（均 LTR）；
    /// 将来支持 RTL 语言时需按 @Environment(\.layoutDirection) 翻转符号。
    static let periodSwipeThreshold: CGFloat = 60

    // MARK: - Header 收起(抽屉拖拽驱动)
    // 以下高度都是经验估算,后续视觉微调集中改这里。详见 HomeView.headerCollapseProgress。

    /// 标题行自然高度:serifDisplay(30) 文本 + 垂直 padding 余量。
    /// 用于 headerView 标题行 `.frame(height:)` 随 progress 收缩。
    static let headerTitleRowHeight: CGFloat = 50
    /// Today/Calendar tab 切换行自然高度。
    static let viewSwitcherRowHeight: CGFloat = 38
    /// 本周小结行自然高度:小图标 + caption(13) 文本 + padding。
    static let weeklySummaryRowHeight: CGFloat = 30
    /// Header 完全收起后,周日期条吸顶保留的总高度。
    /// = 日期圆 26pt + 上下各 9pt padding ≈ 44pt(对齐 iOS 44pt 触控区惯例)。
    /// 用户原话:「周日期条吸顶变成一个紧凑的 44pt 条」。
    static let collapsedWeekStripHeight: CGFloat = 44
    /// week 模式下日期圆行随 collapseProgress 的压扁量(48→44)。
    /// 4pt 是经验值:再大会裁切圆点槽位(6pt),再小则视觉上「没收回」。
    static let weekCollapseRowShrink: CGFloat = 4

    /// 圆点直径跟 rowHeight 自适应：
    /// 改版后圆点移到选中圆下方的固定槽位（不再与数字底部 overlay 挤压），
    /// 阈值相应放宽——行高 ≥22 即可容纳「圆 + 6pt 槽位」结构。
    /// - rowHeight < 22：返回 nil（极矮屏，圆点省略保数字清爽）
    /// - 22-28：返回 3
    /// - 29-40：返回 3.5（月视图典型 ~32pt 落在这档）
    /// - >40：返回 4（周视图典型）
    ///
    /// **不变量**:任何修改本函数分档的改动,必须同步更新 `recurringRingSize(for:)`——
    /// 两个函数的分档必须一致(对同一 rowHeight,要么都返回 nil 要么都返回非 nil),
    /// 否则 HomeMonthDayButton 的 `if hasRecurring, let ringSize = ...` 会落到 else 分支,
    /// 让规律任务日误渲染为实心点。
    static func dotSize(for rowHeight: CGFloat) -> CGFloat? {
        switch rowHeight {
        case ..<22: return nil
        case 22...28: return 3
        case 29...40: return 3.5
        default: return 4
        }
    }

    /// 规律任务的空心环直径,跟 `dotSize(for:)` 同档位但略大(+2pt)——
    /// 空心环需要包住实心点的视觉权重,周视图下也要跟实心点形成清晰对比。
    /// 返回 nil 表示该行高下不渲染规律环(极矮屏,跟 dotSize=nil 对齐)。
    /// - rowHeight < 22：返回 nil（极矮屏,规律信号也省略,保数字清爽）
    /// - 22-28：返回 5
    /// - 29-40：返回 5.5（月视图典型）
    /// - >40：返回 6（周视图）
    ///
    /// **不变量**:分档必须跟 `dotSize(for:)` 镜像(见其文档)。
    static func recurringRingSize(for rowHeight: CGFloat) -> CGFloat? {
        switch rowHeight {
        case ..<22: return nil
        case 22...28: return 5
        case 29...40: return 5.5
        default: return 6
        }
    }

    /// 空心环描边宽度。1pt 在 5-6pt 直径下足够清晰,再细则抗锯齿糊边。
    static let recurringRingStrokeWidth: CGFloat = 1

    /// 选中/今天高亮圆直径：正常行高下用固定 WarmSize.calendarDayCircle（30pt），
    /// 矮行自适应缩小。扣除量 8 = 圆点槽位(6) + VStack spacing(2)，
    /// 保证「圆 + 间距 + 圆点槽」恰好装进 rowHeight 不溢出。
    ///
    /// 下限 18pt（而非放任缩到 dayRowMinHeight-8=14pt）：14pt fixed 字号的两位数日期
    /// （如 "28"）在 14pt 容器里会被挤压到接近 0 宽——这类瞬时挤压会触发 SwiftUI/iOS 17
    /// 的已知渲染缓存 bug（同类根因见 HomeView.swift 页头月份标题的 "..." 冻结注释）：
    /// Text 一旦某一帧被压到极小尺寸，即使之后空间恢复也会永久卡死显示 "..."。
    /// LazyVGrid 懒加载下只有恰好在那一帧被创建的格子会中招，表现为"部分格子变省略号"。
    /// 18pt 留够两位数的安全边界，从根上不让 Text 进入这个退化尺寸。
    static func selectionCircleDiameter(for rowHeight: CGFloat) -> CGFloat {
        max(18, min(WarmSize.calendarDayCircle, rowHeight - 8))
    }
    /// 周视图单行期望高度（舒适触摸目标 + 视觉留白）。
    /// 周视图只有 1 行，若套用高度 cap 会把单行撑得过高；
    /// 这里用固定 48pt 让周视图紧凑，腾出更多空间给列表。
    static let weekDesiredRowHeight: CGFloat = 48

    /// 月历区域高度（容器封顶值，不直接决定行高）。
    /// 设计意图（`max-height + overflow:hidden` 的 SwiftUI 等价）：
    ///   - **月视图**：6 行内容通常接近 44% cap，直接用 cap 让 dayRowHeight 自适应撑满。
    ///   - **周视图**：1 行内容远低于 cap，若套用 cap 会把单行撑得过高；
    ///     改用 content-driven（表头 48 + 1 行 48 = 96pt），列表获得更多空间。
    /// 与 `dayRowHeight` 的契约：本函数返回容器高度，`dayRowHeight` 在容器内独立计算行高
    /// （`max(dayRowMinHeight, (container - fixedSection - spacing) / rows)`）。
    /// 极矮屏（maxCap < 96）下周视图 dayRowHeight 会 < 48，容器底部可能被 `.clipped()` 裁切，
    /// 这是已知取舍（与月视图一致）：列表区至少 56% 不可妥协。
    ///
    /// `displayMode` 参数：
    ///   - `.list`：用 `calendarTargetHeightRatio`（0.44），list+week 走 content-driven 96pt 封顶。
    ///   - `.grid`（month/week 共用）：用 `gridCalendarTargetHeightRatio`（0.70），网格行更高
    ///     / 周时间轴需垂直滚动空间。列表区在 grid 模式下剩 30%，对月视图够用，
    ///     对周视图因时间轴内部还自带 ScrollView 故不会挤压任务列表交互。
    ///     若未来发现 grid+week 列表可滚动空间不足，调高 `gridCalendarTargetHeightRatio`
    ///     到 0.80+（不超过 0.85，必须给底部输入面板/voice FAB 至少 15%）。
    static func calendarHeight(
        availableHeight: CGFloat,
        selectedTab: BottomTab,
        viewMode: CalendarViewMode,
        displayMode: CalendarDisplayMode = .list,
        collapseProgress: Double = 0
    ) -> CGFloat {
        guard selectedTab == .calendar, availableHeight > 0 else { return 0 }
        switch displayMode {
        case .list:
            let maxCap = availableHeight * calendarTargetHeightRatio
            switch viewMode {
            case .month:
                // 月视图不插值:占 44% 屏高的日历网格用户仍要看,只收 headerView 标题/tab/summary。
                return maxCap
            case .week:
                // 抽屉拖拽驱动:
                // - weekday 标签行(calendarFixedSectionHeight=48)随 progress 线性归零
                // - 日期圆行 48→44(轻微压扁,保住圆点不被裁切)
                // 总高 96 → 44,释放 52pt 给 timeline。
                let p = CGFloat(collapseProgress)
                let weekday = calendarFixedSectionHeight * (1 - p)
                let weekRow = weekDesiredRowHeight - weekCollapseRowShrink * p
                let contentHeight = weekday + weekRow
                return min(maxCap, contentHeight)
            }
        case .grid:
            // 网格+月:网格已显示事件概览(数字 + ≤2 事件条 + +N),
            // 下方不再渲染 HomeSelectedDayListView(见 HomeView.monthHomeView),
            // 网格可占满几乎全部高度,留小底部空白作为视觉缓冲。
            // 网格+周:仍需保留 30% 给列表(时间轴下方显示选中日任务)。
            // grid 模式不参与 header collapse(WeekTimelineView 是独立组件,本次不动)。
            if viewMode == .month {
                return availableHeight * gridMonthFullHeightRatio
            }
            return availableHeight * gridCalendarTargetHeightRatio
        }
    }

    static func dayRowHeight(
        availableHeight: CGFloat,
        viewMode: CalendarViewMode,
        displayMode: CalendarDisplayMode = .list
    ) -> CGFloat {
        guard availableHeight > 0 else { return WarmSpacing.xxxl }
        let rows = rowCount(for: viewMode)
        let usable = max(0, availableHeight - calendarFixedSectionHeight - gridSpacing(forRows: rows))
        let computed = max(dayRowMinHeight, usable / rows)
        // 网格+月：每格至少要放数字 + ≤2 事件条 + `+N`，目标 ~80pt 起步。
        // 极矮屏算出的 computed 不足时也按 gridMinRowHeight 兜底，宁可裁切也不压扁。
        if displayMode == .grid && viewMode == .month {
            return max(computed, gridMonthMinRowHeight)
        }
        return computed
    }

    private static func rowCount(for viewMode: CalendarViewMode) -> CGFloat {
        switch viewMode {
        case .month:
            return 6
        case .week:
            return 1
        }
    }

    private static func gridSpacing(forRows rows: CGFloat) -> CGFloat {
        WarmSpacing.xs * max(0, rows - 1)
    }
}

struct HomeMonthDayButton: View {
    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void
    /// 拖拽 drop 回调——从 Unscheduled 拖任务到日期格时触发。
    var onDropTodo: ((UUID) -> Void)? = nil
    var rowHeight: CGFloat = WarmSpacing.xxxl

    @State private var isDropTargeted = false

    /// 圆点尺寸跟 rowHeight 自适应：
    /// 月视图 ~32pt 行高下返回 3.5pt，周视图 48pt 行高下返回 4pt。
    /// 极矮屏（< 22pt）返回 nil，不渲染圆点。
    private var dotSize: CGFloat? {
        HomeLayoutMetrics.dotSize(for: rowHeight)
    }

    /// 选中/今天高亮圆直径（正常 30pt，矮行自适应缩小）。
    private var circleDiameter: CGFloat {
        HomeLayoutMetrics.selectionCircleDiameter(for: rowHeight)
    }

    var body: some View {
        Button {
            onSelect(dayState.date)
        } label: {
            // TickTick 式圆形高亮：数字 + 高亮圆组成固定尺寸的居中单元，
            // 圆点在其下方的固定 6pt 槽位（无圆点时占位，保证各格数字垂直对齐）。
            // 点击热区仍是整格（外层 maxWidth: .infinity × rowHeight）。
            VStack(spacing: 2) {
                ZStack {
                    // - 选中：实心 primary 圆 + 白字
                    // - 今天未选中：primary 0.18 浅圆 + primaryDark 数字（"今天永远有标记"）
                    // - 其他：无背景；跨月补齐日弱化为 textMuted
                    if dayState.isSelected {
                        Circle().fill(WarmTheme.primary)
                    } else if dayState.isToday {
                        Circle().fill(WarmTheme.primary.opacity(0.18))
                    }

                    // 纯数字（5/29 等），不用 .formatted(.dateTime.day(.twoDigits))
                    // 后者在 zh locale 下产生"29日"，与日期格上下文冲突显冗余。
                    // VoiceOver 文案仍走 VoiceOverLabel.monthDayText（带"6月29日"完整表达），
                    // 视觉显示与无障碍朗读职责分离。
                    //
                    // fixedSize:headlineFixed 字号本身不缩放,但 SwiftUI 对固定字号 Text 在
                    // ZStack + .frame 里仍会按 sizeCategory 加 layout 补偿(AX 档位下 ×2~3),
                    // 把 Text 请求的 intrinsic width 撑到超过 circleDiameter → .tail truncation →
                    // 显示「…」。fixedSize 让 Text 按字体本身算宽度(两位数 ~16pt),退出这个补偿。
                    // 同类根因见 HomeMonthGridButton.dayNumberView / WeekTimelineView.dayHeaderColumn。
                    Text("\(dayState.dayNumber)")
                        .font(WarmFont.headlineFixed(14))
                        .foregroundColor(
                            dayState.isSelected ? .white :
                            (dayState.isToday ? WarmTheme.primaryDark :
                            (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))
                        )
                        .fixedSize()
                }
                .frame(width: circleDiameter, height: circleDiameter)
                // 选中态放大只作用于圆+数字单元：30pt 圆放大 1.05 不会碰到相邻格。
                // Reduce Motion 时 animation 会被系统忽略。
                .scaleEffect(dayState.isSelected ? WarmAnimation.monthDaySelectedScale : WarmAnimation.monthDayDefaultScale)
                .animation(WarmAnimation.springSmooth, value: dayState.isSelected)

                // 圆点槽位：固定 6pt 高。圆点在页面底色上（不再被选中圆覆盖），
                // 颜色按完成态：primary（有未完成）/ textMuted（全完成）。
                // 形态按是否含规律任务：空心环（有重复）/ 实心点（纯单次）——
                // 区分信号避免用户翻日历看到"每天有点"误以为排满，
                // 重复任务的"完成"只算当次,日历上仍需持续提示"这天还有规律任务"。
                // 混合日(同时有重复 + 单次)按"有重复"算:重复任务需要持续可见,
                // 单次任务的实心信号会丢失,但当天点的颜色(primary=有未完成)仍能反映"有事未做完"。
                ZStack {
                    if let dotSize, !dayState.occurrences.isEmpty {
                        let hasUncompletedOccurrence = dayState.occurrences.contains { !$0.isCompleted }
                        let hasRecurringOccurrence = dayState.occurrences.contains { $0.isRecurring }
                        let dotColor = hasUncompletedOccurrence ? WarmTheme.primary : WarmTheme.textMuted
                        if hasRecurringOccurrence, let ringSize = HomeLayoutMetrics.recurringRingSize(for: rowHeight) {
                            // 空心环：直径跟 rowHeight 自适应,1pt 描边
                            Circle()
                                .stroke(dotColor, lineWidth: HomeLayoutMetrics.recurringRingStrokeWidth)
                                .frame(width: ringSize, height: ringSize)
                        } else {
                            Circle()
                                .fill(dotColor)
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceOverLabel.build(for: dayState))
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthDay_\(dayState.date.formatted(.dateTime.year().month().day()))")
        // 拖拽：从 Unscheduled 拖任务到日期格 → 赋日期
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            onDropTodo?(id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            // 拖拽目标提示：与高亮同语言的圆形描边，比高亮圆大一圈（d+6）居中。
            if isDropTargeted {
                Circle()
                    .stroke(WarmTheme.primary, lineWidth: 2)
                    .frame(width: circleDiameter + 6, height: circleDiameter + 6)
            }
        }
        .animation(WarmAnimation.springFast, value: isDropTargeted)
    }
}

/// VoiceOver 文案构造：把日历单元格的状态翻译成完整一句话。
/// 月视图单元格视觉信息（数字、点、底色）对低视力/盲人用户没用，必须用文字补全。
/// 顺序遵循可达性惯例：身份（日期）在前，状态（非当月/今天/待办数）在后。
/// 使用 app 当前本地化语言 + gregorian 日历格式化日期，避免系统区域语言与 app 文案混读。
