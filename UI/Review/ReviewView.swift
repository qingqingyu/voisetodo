import SwiftUI
import Charts
import SwiftData

// MARK: - Period

/// 回顾页可选的时间跨度。
private enum ReviewPeriod: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .week:
            return String(localized: "review.period.week")
        case .month:
            return String(localized: "review.period.month")
        }
    }

    /// 从今天往回推算的起始日（用户日归一化）。
    func startDay(from today: Date, calendar: Calendar) -> Date {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        switch self {
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
        }
    }

    /// 区间结束日（明天用户日起点，开区间——对齐 ReviewAggregator `[start, end)` 约定）。
    /// ReviewAggregator 内部会对 endDay 再做用户日归一化，
    /// 因此传入明天起点后归一化仍为明天，确保今天被包含在区间内。
    func endDay(from today: Date, calendar: Calendar) -> Date {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
    }

    /// 用于展示的周期标签（如 "2026年7月" / "第29周"）。
    /// 月份恒用 `.abbreviated`:英文 "September 2026" → "Sep 2026",中文 "2026年9月" 不变。
    /// 与 HomeView calendarMonthTitle 保持一致,避免英文长月份名挤爆标题行。
    func periodLabel(for today: Date, calendar: Calendar) -> String {
        switch self {
        case .week:
            let weekOfYear = calendar.component(.weekOfYear, from: today)
            let year = calendar.component(.yearForWeekOfYear, from: today)
            return String(localized: "review.label.week_\(year)_\(weekOfYear)")
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return monthStart.formatted(.dateTime.year().month(.abbreviated))
        }
    }
}

// MARK: - ReviewView

/// 回顾页面——展示周/月切换的完成统计摘要。
///
/// 使用 Swift Charts 绘制分类占比饼图和每日趋势条形图。
/// 数据通过 `@Query` 从 SwiftData 查询已完成 TodoItem，
/// 转换为 `CompletionEvent` 数组后调 `ReviewAggregator.summarize`。
///
/// 阶段 3 增补:复盘入口卡(2026-08-23 拍板改版为「N 件事等你决定」一行动作行,
/// 点击 fullScreenCover 呈现五步流程 `ReviewFlowView`)——有数据时位于 `content`
/// 统计行之后,空态置顶。日常随手看统计和郑重坐下来复盘是两种心智,不混。
struct ReviewView: View {
    /// 复盘流程需要的 store 能力。nil(默认)时入口卡隐藏——settings 深链与
    /// preview 不注入也能编译渲染;HomeView 的两处 sheet 注入真实 store。
    var store: (any ReviewFlowStore)? = nil
    /// 拆小 sheet 的 AI 候选源(2026-08-23 拆小改版)。nil → sheet 直接手写降级。
    var splitter: (any TodoSplitterProtocol)? = nil
    /// 拆小 sheet 的麦克风(与首页共用同一实例)。nil → 「说一句」行隐藏。
    var voiceInput: (any VoiceInputProtocol)? = nil

    @Query(
        filter: #Predicate<TodoItem> { $0.isCompleted },
        sort: [SortDescriptor(\TodoItem.completedAt, order: .reverse)]
    )
    private var completedTodos: [TodoItem]

    /// 规律任务某天的完成记录(与 completedTodos union,避免漏算重复任务)
    @Query(sort: [SortDescriptor(\TodoOccurrenceCompletion.completedAt, order: .reverse)])
    private var recurringCompletions: [TodoOccurrenceCompletion]

    /// 全部待办(不过滤 isCompleted)——用于给规律任务完成记录查父任务分类。
    /// 规律任务父 TodoItem 永远 isCompleted==false(完成落在 TodoOccurrenceCompletion),
    /// 故不能用 completedTodos 建分类表,否则规律完成全部 fallback 成 .other。
    @Query private var allTodos: [TodoItem]

    @State private var selectedPeriod: ReviewPeriod = .month
    /// 入口卡点击 → fullScreenCover 呈现五步复盘流程。
    @State private var showReviewFlow = false

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                // 顺序(2026-08-23 拍板):有数据时先情绪回报(Hero/统计)再派活
                // (入口卡在 `content` 内、统计行之后);空态仍入口卡置顶——
                // 新用户没有完成记录,行动入口必须第一眼可见。
                VStack(spacing: WarmSpacing.lg) {
                    if summary.total == 0 {
                        if store != nil {
                            reviewFlowEntryCard
                        }

                        emptyState
                    } else {
                        content
                    }
                }
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.bottom, WarmSpacing.xxl)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            stickyPeriodHeader
        }
        .fullScreenCover(isPresented: $showReviewFlow) {
            if let store {
                ReviewFlowView(store: store, splitter: splitter, voiceInput: voiceInput)
            }
        }
        .navigationTitle(String(localized: "review.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Review Flow Entry

    /// 复盘入口卡(2026-08-23 拍板改版):一行动作行——icon + 「N 件事等你决定」
    /// + 尾部胶囊「开始 →」。N = 未完成 && abandonedAt == nil && recurrenceRule == nil
    /// 的一次性任务数(与第 2 步卡片堆输入同一口径,拍板 4)。
    ///
    /// 改版动机:旧三行卡(title/pending/scope)读起来像信息展示,且「一次性任务」
    /// 是内部模型泄漏(用户没有这个分类);「回顾近 30 天」消歧义移进流程第 1 步;
    /// 「上次复盘日期」也移第 1 步(从 previousSessions 取,不再外部注入)。
    /// N == 0 时空态文案「都清完了,看看这一个月」——卡不消失,回顾本身仍有价值。
    @ViewBuilder
    private var reviewFlowEntryCard: some View {
        let pendingCount = allTodos.filter { item in
            !item.isCompleted && item.abandonedAt == nil && item.recurrenceRule == nil
        }.count
        let hasPending = pendingCount > 0

        Button {
            showReviewFlow = true
        } label: {
            RecapCard {
                HStack(spacing: WarmSpacing.md) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 22))
                        .foregroundColor(WarmTheme.primary)

                    Text(String(localized: hasPending
                        ? "review.flow.entry.pending_\(pendingCount)"
                        : "review.flow.entry.empty"))
                        .font(WarmFont.headline(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: WarmSpacing.xs)

                    // 尾部胶囊是动作暗示:这一行是「进去做事」,不是信息展示。
                    HStack(spacing: WarmSpacing.xxs) {
                        Text(String(localized: "review.flow.entry.action"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .font(WarmFont.headline(13))
                    .foregroundColor(.white)
                    .padding(.horizontal, WarmSpacing.md)
                    .padding(.vertical, WarmSpacing.xs)
                    .background(
                        Capsule().fill(hasPending ? WarmTheme.primary : WarmTheme.primary.opacity(0.75))
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ReviewFlowEntryCard")
    }

    // MARK: Sticky Header

    /// 周/月切换器吸顶——滚动后仍能看到当前在看哪个范围。
    /// 只放 Picker(32pt),Hero 区已经有周期标签,重复会拥挤。
    private var stickyPeriodHeader: some View {
        periodPicker
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.vertical, WarmSpacing.sm)
            .background(WarmTheme.cardBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(WarmTheme.divider)
                    .frame(height: 1)
            }
    }

    // MARK: - Computed

    /// 将已完成 TodoItem + 规律任务完成记录 union 成 CompletionEvent 数组。
    private var completionEvents: [CompletionEvent] {
        // 一次性待办完成
        var events = completedTodos.compactMap { item -> CompletionEvent? in
            guard let completedAt = item.completedAt else { return nil }
            return CompletionEvent(
                id: item.id,
                completedAt: completedAt,
                category: item.category
            )
        }
        // 规律任务完成(union,分类取父任务)。用 allTodos 建表——规律父任务 isCompleted==false,
        // 不在 completedTodos 里,只有全量表才能查到它的分类。父任务被删则 fallback .other。
        let categoryById = Dictionary(allTodos.map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        for completion in recurringCompletions {
            events.append(CompletionEvent(
                id: completion.id,
                completedAt: completion.completedAt,
                category: categoryById[completion.todoId] ?? .other
            ))
        }
        return events
    }

    /// 当前选中周期的聚合摘要。
    private var summary: ReviewSummary {
        let today = Date()
        let start = selectedPeriod.startDay(from: today, calendar: calendar)
        let end = selectedPeriod.endDay(from: today, calendar: calendar)
        let label = selectedPeriod.periodLabel(for: today, calendar: calendar)
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart

        // 未来 7 天到期数:统计卡副文案(完成率分母链路随完成率下岗移除,2026-08-23)。
        let upcomingDueIn7DaysCount = allTodos.filter { item in
            guard let due = item.dueDate else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay > todayStart && dueDay <= weekEnd
        }.count

        let result = ReviewAggregator.summarize(
            events: completionEvents,
            from: start,
            to: end,
            calendar: calendar,
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount
        )
        // 「当天记当天做完」按周/月各自区间算(一次性任务口径)。
        let sameDayCount = ReviewAggregator.sameDayCompletions(
            completedTodos.map { $0.toData() },
            from: start,
            to: end,
            calendar: calendar
        )
        return ReviewSummary(
            periodLabel: label,
            total: result.total,
            byCategory: result.byCategory,
            byDay: result.byDay,
            streakDays: result.streakDays,
            busiestDay: result.busiestDay,
            busiestDayCount: result.busiestDayCount,
            upcomingDueIn7DaysCount: result.upcomingDueIn7DaysCount,
            daysWithCompletion: result.daysWithCompletion,
            sameDayCount: sameDayCount
        )
    }

    // MARK: - Views

    private var emptyState: some View {
        VStack(spacing: WarmSpacing.lg) {
            Spacer()

            EmptyStateView(
                icon: "chart.pie",
                message: String(localized: "review.empty.message"),
                iconSize: 44,
                opacity: 0.6
            )

            emptyPreviewCard

            Spacer()
        }
    }

    /// 空态说明卡——告诉用户累计数据后会看到什么,把空白变成期待,
    /// 而不是只摆一个图标让人觉得「这个 app 啥也没有」。
    private var emptyPreviewCard: some View {
        RecapCard {
            Text(String(localized: "review.empty.preview"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(spacing: WarmSpacing.lg) {
            RecapHeroSection(summary: summary)

            RecapStatsRow(summary: summary)

            if store != nil {
                reviewFlowEntryCard
            }

            RecapCategoryChartSection(byCategory: summary.byCategory)

            dailyTrendSection

            if let busiest = summary.busiestDay {
                busiestDaySection(busiest)
            }
        }
    }

    // MARK: Period Picker

    private var periodPicker: some View {
        Picker(String(localized: "review.period.title"), selection: $selectedPeriod) {
            ForEach(ReviewPeriod.allCases) { period in
                Text(period.displayText)
                    .tag(period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ReviewPeriodPicker")
    }

    // MARK: Daily Trend

    /// 数据稀疏(<3 天有完成)时换文本态,避免画一堆空柱子观感像「这月啥也没干」。
    /// 文本态直接用一句话告诉用户「7月24日完成 2 项,其余日期无记录」。
    /// 图表态再画 BarMark,X 轴刻度按周/月差异化(月=每 7 天一标,周=全标)。
    private var dailyTrendSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.daily_trend"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)

                if summary.daysWithCompletion < 3 {
                    sparseTrendText
                } else {
                    dailyTrendChart
                    trendConclusion
                }
            }
        }
    }

    /// 稀疏态文本:把所有有完成的天按日期顺序列出,以「,」分隔,末尾接「其余日期无记录」。
    /// 阈值 <3 天意味着最多 2 天需要描述,句子不会过长。
    private var sparseTrendText: some View {
        let activeDays = summary.byDay
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
        let segments: [String] = activeDays.map { day, count in
            let dateText = day.formatted(.dateTime.month().day())
            return String(localized: "review.sparse.day_\(dateText)_\(count)")
        }
        let joined = segments.joined(separator: String(localized: "review.sparse.separator"))
        let sentence = joined + String(localized: "review.sparse.tail")

        return Text(sentence)
            .font(WarmFont.body(14))
            .foregroundColor(WarmTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dailyTrendChart: some View {
        Chart {
            ForEach(dailyTrendData, id: \.day) { entry in
                BarMark(
                    x: .value(String(localized: "review.chart.day"), entry.day, unit: .day),
                    y: .value(String(localized: "review.chart.count"), entry.count)
                )
                .foregroundStyle(WarmTheme.primary)
                .cornerRadius(4)
            }

            // 灰点:过去但 count=0 的日子(不含今天,今天没完成不算「没做」)。
            // 区分「没做」和「还没到」——未来日本来就没柱子,过去日没柱子会显灰点。
            ForEach(pastZeroDays, id: \.day) { entry in
                PointMark(
                    x: .value(String(localized: "review.chart.day"), entry.day, unit: .day),
                    y: .value(String(localized: "review.chart.mark"), 0)
                )
                .foregroundStyle(WarmTheme.textMuted.opacity(0.35))
                .symbolSize(14)
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisDates) { _ in
                AxisValueLabel(format: .dateTime.day(.defaultDigits))
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 160)
    }

    /// 图表下方一行结论:本月/本周共完成 N 项,最忙那天 M 项。
    /// 仅在图表态显示(稀疏态已有自己的替代文案,不重复堆叠)。
    @ViewBuilder
    private var trendConclusion: some View {
        if let busiest = summary.busiestDay, summary.busiestDayCount > 0 {
            let dateText = busiest.formatted(.dateTime.month().day())
            let sentence = String(localized: "review.trend.summary_\(summary.total)_\(dateText)_\(summary.busiestDayCount)")
            Text(sentence)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dailyTrendData: [(day: Date, count: Int)] {
        let today = Date()
        let start = selectedPeriod.startDay(from: today, calendar: calendar)

        var result: [(day: Date, count: Int)] = []
        var cursor = start
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)

        while cursor <= todayStart {
            let count = summary.byDay[cursor] ?? 0
            result.append((day: cursor, count: count))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        return result
    }

    /// 过去(不含今天)且 count=0 的日子——给图表画灰点用。
    private var pastZeroDays: [(day: Date, count: Int)] {
        let todayStart = DayClock.startOfUserDay(for: Date(), calendar: calendar)
        return dailyTrendData.filter { entry in
            entry.count == 0 && entry.day < todayStart
        }
    }

    /// X 轴刻度日期。
    /// 月视图:每 7 天一标(起始日 + 7/14/21/28 日,过滤掉超过今天的),
    /// 避免 31 格全标导致数字叠成「2456789012345...」。
    /// 周视图:7 天全标,空间够。
    private var xAxisDates: [Date] {
        let today = Date()
        let start = selectedPeriod.startDay(from: today, calendar: calendar)
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)

        switch selectedPeriod {
        case .week:
            var dates: [Date] = []
            var cursor = start
            while cursor <= todayStart {
                dates.append(cursor)
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            return dates
        case .month:
            return [0, 7, 14, 21, 28]
                .compactMap { offset in
                    calendar.date(byAdding: .day, value: offset, to: start)
                }
                .filter { $0 <= todayStart }
        }
    }

    // MARK: Busiest Day

    /// 单行布局,修复旧版「·」孤立断行的问题。
    /// 旧布局:VStack { Text("最活跃的一天 · 完成 N 件") + Text("7月24日 周三") } —
    /// 当 headline 强制换行时,「·」会留在第一行末尾,看起来像个孤立符号。
    /// 新布局:整句一个 Text,文案是「最忙的一天:7月24日 周三 · 完成 2 项」,
    /// 让 SwiftUI 整行排版,「·」前后都有内容,不会孤立。
    private func busiestDaySection(_ date: Date) -> some View {
        RecapCard {
            HStack(spacing: WarmSpacing.md) {
                Image(systemName: "star.fill")
                    .font(.system(size: 28))
                    .foregroundColor(WarmTheme.warning)

                Text(busiestDayOneLiner(date))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
        }
    }

    private func busiestDayOneLiner(_ date: Date) -> String {
        // 星期恒用 `.abbreviated`:英文 "Monday" → "Mon",中文 "星期一" → "周一"。
        // 与 HomeView todayWeekdayTitle 保持一致。
        let dateText = date.formatted(.dateTime.month().day().weekday(.abbreviated))
        return String(localized: "review.busiest.oneline_\(dateText)_\(summary.busiestDayCount)")
    }
}

// MARK: - Preview

#Preview("With Data") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)

    let now = Date()
    let cal = Calendar.current
    let categories: [TodoCategory] = [.work, .study, .life, .health, .other]
    for i in 0..<15 {
        let dayOffset = -(i % 10)
        let date = cal.date(byAdding: .day, value: dayOffset, to: now)!
        // 给 dueDate(与完成同一天),保持与真实数据形状一致。
        let item = TodoItem(
            title: "Preview item \(i)",
            dueDate: date,
            category: categories[i % categories.count],
            isCompleted: true,
            completedAt: date
        )
        container.mainContext.insert(item)
    }
    // 加一个未来 7 天到期的待办,验证「未来 7 天还有 N 项」副文案。
    let futureDate = cal.date(byAdding: .day, value: 3, to: now)!
    container.mainContext.insert(TodoItem(
        title: "Upcoming item",
        dueDate: futureDate,
        category: .work
    ))

    return NavigationStack {
        ReviewView()
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Sparse") {
    // 整月只有今天完成 2 项,触发稀疏文本态:Daily Trend 切到一句话,
    // Category 也走横条(2 类各 1 件)。两件都到期于今天。
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)

    let now = Date()
    container.mainContext.insert(TodoItem(
        title: "Item A",
        dueDate: now,
        category: .work,
        isCompleted: true,
        completedAt: now
    ))
    container.mainContext.insert(TodoItem(
        title: "Item B",
        dueDate: now,
        category: .life,
        isCompleted: true,
        completedAt: now
    ))

    return NavigationStack {
        ReviewView()
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)

    return NavigationStack {
        ReviewView()
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}
