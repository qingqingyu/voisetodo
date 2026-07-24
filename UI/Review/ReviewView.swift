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
struct ReviewView: View {
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

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                if summary.total == 0 {
                    emptyState
                } else {
                    content
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            stickyPeriodHeader
        }
        .navigationTitle(String(localized: "review.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
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

        // 完成率分母:区间内 dueDate ≤ 今天的待办数。
        // 未来到期的任务不计入分母,避免月中显示"10%"这种打击人的数字。
        // 规律任务父任务只算一次(item-based,与历史 createdCount 风格一致);
        // 不展开 occurrence,v2 若要精确可用 RecurrenceRule.occurs(on:) 改算法。
        let dueByTodayCount = allTodos.filter { item in
            guard let due = item.dueDate else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay >= start && dueDay <= todayStart
        }.count

        // 未来 7 天到期数:用作完成率副文案,提示用户接下来要做什么。
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
            dueByTodayCount: dueByTodayCount > 0 ? dueByTodayCount : nil,
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount
        )
        return ReviewSummary(
            periodLabel: label,
            total: result.total,
            byCategory: result.byCategory,
            byDay: result.byDay,
            streakDays: result.streakDays,
            busiestDay: result.busiestDay,
            busiestDayCount: result.busiestDayCount,
            completionRate: result.completionRate,
            dueByTodayCount: result.dueByTodayCount,
            upcomingDueIn7DaysCount: result.upcomingDueIn7DaysCount,
            daysWithCompletion: result.daysWithCompletion
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
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.bottom, WarmSpacing.xxl)
    }

    /// 空态说明卡——告诉用户累计数据后会看到什么,把空白变成期待,
    /// 而不是只摆一个图标让人觉得「这个 app 啥也没有」。
    private var emptyPreviewCard: some View {
        reviewCard {
            Text(String(localized: "review.empty.preview"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(spacing: WarmSpacing.lg) {
            heroSection

            statsRow

            categoryChartSection

            dailyTrendSection

            if let busiest = summary.busiestDay {
                busiestDaySection(busiest)
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.bottom, WarmSpacing.xxl)
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

    // MARK: Hero

    private var heroSection: some View {
        VStack(spacing: WarmSpacing.xs) {
            Text(String(localized: "review.hero.count_\(summary.total)"))
                .font(WarmFont.display(40))
                .foregroundColor(WarmTheme.primary)
                .accessibilityIdentifier("ReviewHeroCount")

            Text(summary.periodLabel)
                .font(WarmFont.caption(14))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarmSpacing.lg)
    }

    // MARK: Stats Row

    /// 完成率卡片只有在分母>0(dueByTodayCount>0)时才显示。
    /// 分母=0 意味着区间内还没到期项,显示「0%」或「--」都是噪音。
    /// 副文案「未来 7 天还有 N 项」在 N>0 时才显示,避免空文案占位。
    private var statsRow: some View {
        HStack(spacing: WarmSpacing.md) {
            statCard(
                icon: "flame.fill",
                value: "\(summary.streakDays)",
                label: String(localized: "review.stat.streak")
            )

            if summary.completionRate != nil {
                completionRateCard
            }
        }
    }

    private var completionRateCard: some View {
        let rate = summary.completionRate ?? 0
        return VStack(spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(WarmTheme.primary)

                Text(percentageString(rate))
                    .font(WarmFont.headline(22))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Text(String(localized: "review.stat.completion_rate"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)

            if summary.upcomingDueIn7DaysCount > 0 {
                Text(String(localized: "review.stat.upcoming_7d_\(summary.upcomingDueIn7DaysCount)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
        )
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(WarmTheme.primary)

                Text(value)
                    .font(WarmFont.headline(22))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Text(label)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
        )
    }

    // MARK: Category Chart

    /// 旧版用 SectorMark(甜甜圈)。问题:2 类各 1 件时画成半圆纯属装饰,
    /// 类别超过 4 个色块也没法读。换横条——任何数量下都准确可读,数量直接标在条尾。
    private var categoryChartSection: some View {
        reviewCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.category"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)

                VStack(spacing: WarmSpacing.sm) {
                    let data = categoryChartData
                    let maxCount = max(data.first?.count ?? 1, 1)
                    ForEach(data, id: \.category) { entry in
                        categoryBarRow(entry, maxCount: maxCount)
                    }
                }
            }
        }
    }

    private var categoryChartData: [(category: TodoCategory, count: Int)] {
        summary.byCategory
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, count: $0.value) }
    }

    /// 单行横条:标签 + 条 + 数量。条宽相对最大值归一化,最长那条占满。
    /// maxCount 由调用方算好传入,避免每行都重新构造 categoryChartData(O(n^2))。
    private func categoryBarRow(_ entry: (category: TodoCategory, count: Int), maxCount: Int) -> some View {
        let ratio = Double(entry.count) / Double(maxCount)

        return HStack(spacing: WarmSpacing.sm) {
            Text("\(entry.category.emoji) \(entry.category.displayName)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 110, alignment: .leading)

            GeometryReader { proxy in
                let barWidth = proxy.size.width * ratio
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(WarmTheme.color(for: entry.category))
                    .frame(width: barWidth, height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text("\(entry.count)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .frame(minWidth: 24, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: Daily Trend

    /// 数据稀疏(<3 天有完成)时换文本态,避免画一堆空柱子观感像「这月啥也没干」。
    /// 文本态直接用一句话告诉用户「7月24日完成 2 项,其余日期无记录」。
    /// 图表态再画 BarMark,X 轴刻度按周/月差异化(月=每 7 天一标,周=全标)。
    private var dailyTrendSection: some View {
        reviewCard {
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
        reviewCard {
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

    // MARK: - Helpers

    /// 卡片容器——统一圆角、背景、阴影。
    @ViewBuilder
    private func reviewCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(WarmSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
            )
    }

    private func busiestDayOneLiner(_ date: Date) -> String {
        // 星期恒用 `.abbreviated`:英文 "Monday" → "Mon",中文 "星期一" → "周一"。
        // 与 HomeView todayWeekdayTitle 保持一致。
        let dateText = date.formatted(.dateTime.month().day().weekday(.abbreviated))
        return String(localized: "review.busiest.oneline_\(dateText)_\(summary.busiestDayCount)")
    }

    private func percentageString(_ value: Double) -> String {
        // clamp 已在 ReviewAggregator 里完成,这里防御性再夹一次,
        // 避免未来调用方直接传未 clamp 的值进来。
        let pct = Int((min(max(value, 0), 1) * 100).rounded())
        return "\(pct)%"
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
        // 同时给 dueDate(也设在同一天),让完成率分母非零,验证 statsRow 副文案显示。
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
    // Category 也走横条(2 类各 1 件)。完成率分母 2(今天到期的 2 项)。
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
