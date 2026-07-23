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

            if summary.total == 0 {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(String(localized: "review.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
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
        let createdCount = allTodos.filter { item in
            let created = DayClock.startOfUserDay(for: item.createdAt, calendar: calendar)
            return created >= start && created < end
        }.count
        let result = ReviewAggregator.summarize(
            events: completionEvents,
            from: start,
            to: end,
            calendar: calendar,
            createdCount: createdCount > 0 ? createdCount : nil
        )
        return ReviewSummary(
            periodLabel: label,
            total: result.total,
            byCategory: result.byCategory,
            byDay: result.byDay,
            streakDays: result.streakDays,
            busiestDay: result.busiestDay,
            busiestDayCount: result.busiestDayCount,
            completionRate: result.completionRate
        )
    }

    // MARK: - Views

    private var emptyState: some View {
        VStack(spacing: WarmSpacing.md) {
            periodPicker

            Spacer()

            EmptyStateView(
                icon: "chart.pie",
                message: String(localized: "review.empty.message"),
                iconSize: 44,
                opacity: 0.6
            )

            Spacer()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                periodPicker

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

    private var statsRow: some View {
        HStack(spacing: WarmSpacing.md) {
            statCard(
                icon: "flame.fill",
                value: "\(summary.streakDays)",
                label: String(localized: "review.stat.streak")
            )

            if let rate = summary.completionRate {
                statCard(
                    icon: "checkmark.circle.fill",
                    value: percentageString(rate),
                    label: String(localized: "review.stat.completion_rate")
                )
            }
        }
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

    private var categoryChartSection: some View {
        reviewCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.category"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)

                Chart(categoryChartData, id: \.category) { entry in
                    SectorMark(
                        angle: .value(String(localized: "review.chart.count"), entry.count),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(WarmTheme.color(for: entry.category))
                    .opacity(0.85)
                }
                .frame(height: 180)

                categoryLegend
            }
        }
    }

    private var categoryChartData: [(category: TodoCategory, count: Int)] {
        summary.byCategory
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, count: $0.value) }
    }

    private var categoryLegend: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: WarmSpacing.xs) {
            ForEach(categoryChartData, id: \.category) { entry in
                HStack(spacing: WarmSpacing.xxs) {
                    Circle()
                        .fill(WarmTheme.color(for: entry.category))
                        .frame(width: 10, height: 10)

                    Text("\(entry.category.emoji) \(entry.category.displayName)")
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(entry.count)")
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Daily Trend

    private var dailyTrendSection: some View {
        reviewCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.daily_trend"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)

                Chart(dailyTrendData, id: \.day) { entry in
                    BarMark(
                        x: .value(String(localized: "review.chart.day"), entry.day, unit: .day),
                        y: .value(String(localized: "review.chart.count"), entry.count)
                    )
                    .foregroundStyle(WarmTheme.primary)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.day(.defaultDigits))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 160)
            }
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

    // MARK: Busiest Day

    private func busiestDaySection(_ date: Date) -> some View {
        reviewCard {
            HStack(spacing: WarmSpacing.md) {
                Image(systemName: "star.fill")
                    .font(.system(size: 28))
                    .foregroundColor(WarmTheme.warning)

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    Text(String(localized: "review.busiest.day_\(summary.busiestDayCount)"))
                        .font(WarmFont.headline(16))
                        .foregroundColor(WarmTheme.textPrimary)

                    Text(busiestDayString(date))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                }

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

    private func busiestDayString(_ date: Date) -> String {
        // 星期恒用 `.abbreviated`:英文 "Monday" → "Mon",中文 "星期一" → "周一"。
        // 与 HomeView todayWeekdayTitle 保持一致。
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private func percentageString(_ value: Double) -> String {
        // 夹逼到 [0,100]：分子是完成事件数(含规律任务多次完成)、分母是区间内创建数,
        // 人群不一致时比率可能 >100%,显示成 "150%" 观感像 bug。夹逼避免误解。
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
        let item = TodoItem(
            title: "Preview item \(i)",
            category: categories[i % categories.count],
            isCompleted: true,
            completedAt: date
        )
        container.mainContext.insert(item)
    }

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
}
