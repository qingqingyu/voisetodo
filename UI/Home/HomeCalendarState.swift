import Foundation
import SwiftUI

struct HomeCalendarDayState {
    let date: Date
    /// 格子上显示的日数字。由 HomeCalendarState 用注入的 calendar 计算，
    /// 避免视图层用 Calendar.current 与状态层日历不一致的隐患。
    let dayNumber: Int
    let occurrences: [TodoOccurrenceData]
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
}

struct HomeCalendarState {
    let selectedDate: Date
    let visibleMonthAnchor: Date
    /// 当前模式下要渲染的日期：整月网格（42 天）。
    let visibleDays: [Date]
    let weekHeaderDays: [Date]
    let occurrencesByDay: [String: [TodoOccurrenceData]]
    /// 「未定时间」组:`.parsed` outcome + `dueDate==nil` + `recurrenceRule==nil`
    /// + 没有任何时间信号(timeBucket==nil && dueHint 为空)。
    /// 完全无时间信息的待排期货到这里——卡片不显示任何时间 chip,也没有「选日期」按钮。
    let unscheduledTodos: [TodoItemData]
    /// 「待定日期」组:`.parsed` outcome + `dueDate==nil` + `recurrenceRule==nil`
    /// + 有时间信号(timeBucket 或 dueHint 非空)。
    /// 卡片右侧带珊瑚色「选日期」按钮,chip 显示「时段 · 未定哪天」(HTML line 397-439)。
    let pendingDateTodos: [TodoItemData]
    /// 「没能识别」组:outcome != .parsed(.rawFallback 或 .unparsed) +
    /// `dueDate==nil` + `recurrenceRule==nil`。
    /// 卡片显示原文片段 + 「重新解析 / 删除」按钮(HTML line 442-458)。
    let unparsedTodos: [TodoItemData]
    /// 已完成的无安排任务(`dueDate==nil && recurrenceRule==nil && isCompleted`,
    /// 不分 outcome / 是否有时间信号)。按 completedAt 倒序——最近完成在上。
    /// 用于在底部「已完成」分区里和 occurrence 一起显示。
    /// 与三个未完成组不对称:已完成的不再细分原状态,统一进「已完成」。
    let completedUnscheduledTodos: [TodoItemData]
    let selectedOccurrences: [TodoOccurrenceData]
    let uncompletedOccurrences: [TodoOccurrenceData]
    let completedOccurrences: [TodoOccurrenceData]
    let hasTodos: Bool

    /// 状态层使用的 calendar 实例（注入时传入）。暴露给视图层
    /// 是为了确保 hour/minute 计算与 `occurrencesByDay` 的 dayKey 聚合口径一致——
    /// 若视图层自己用 `Calendar.current` 在非 gregorian locale 下会产生错位。
    let calendar: Calendar

    /// 页头大标题下方的小字说明：显示年份（大标题已有月份名）。
    static func periodCaption(anchor: Date, calendar: Calendar) -> String {
        anchor.formatted(.dateTime.year())
    }

    var selectedDateTitle: String {
        if calendar.isDateInToday(selectedDate) {
            return String(localized: "home.week.today")
        }
        if calendar.isDateInTomorrow(selectedDate) {
            return String(localized: "home.week.tomorrow")
        }
        return selectedDate.formatted(.dateTime.month().day().weekday(.wide))
    }

    static func make<Store: HomeTodoStore>(
        store: Store,
        selectedDate: Date,
        visibleMonthAnchor: Date,
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar,
        now: Date = Date()
    ) -> HomeCalendarState {
        let normalizedSelectedDate = calendar.startOfDay(for: selectedDate)
        let normalizedAnchor = calendar.startOfDay(for: visibleMonthAnchor)
        let visibleDays = monthDays(for: normalizedAnchor, calendar: calendar)

        return HomeCalendarState(
            todos: store.todos,
            selectedDate: normalizedSelectedDate,
            visibleMonthAnchor: normalizedAnchor,
            visibleDays: visibleDays,
            weekHeaderDays: weekHeaderDays(referenceDate: now, calendar: calendar),
            occurrencesByDay: occurrencesByDay,
            calendar: calendar
        )
    }

    /// 测试用工厂:绕开 `HomeTodoStore` 依赖,直接用 `[TodoItemData]` 构造状态。
    /// 生产代码用 `make(store:...)`,只有 `HomeCalendarStateGroupingTests` 等单测调用本方法。
    static func makeForTests(
        todos: [TodoItemData],
        selectedDate: Date,
        visibleMonthAnchor: Date? = nil,
        occurrencesByDay: [String: [TodoOccurrenceData]] = [:],
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date()
    ) -> HomeCalendarState {
        let normalizedSelectedDate = calendar.startOfDay(for: selectedDate)
        let anchor = visibleMonthAnchor ?? selectedDate
        let normalizedAnchor = calendar.startOfDay(for: anchor)
        let visibleDays = monthDays(for: normalizedAnchor, calendar: calendar)
        return HomeCalendarState(
            todos: todos,
            selectedDate: normalizedSelectedDate,
            visibleMonthAnchor: normalizedAnchor,
            visibleDays: visibleDays,
            weekHeaderDays: weekHeaderDays(referenceDate: now, calendar: calendar),
            occurrencesByDay: occurrencesByDay,
            calendar: calendar
        )
    }

    static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    func dayState(for day: Date) -> HomeCalendarDayState {
        let dayOccurrences = occurrences(on: day)
        return HomeCalendarDayState(
            date: day,
            dayNumber: calendar.component(.day, from: day),
            occurrences: dayOccurrences,
            isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
            isToday: calendar.isDateInToday(day),
            isCurrentMonth: calendar.isDate(day, equalTo: visibleMonthAnchor, toGranularity: .month)
        )
    }

    func weekdayTitle(for date: Date) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    private init(
        todos: [TodoItemData],
        selectedDate: Date,
        visibleMonthAnchor: Date,
        visibleDays: [Date],
        weekHeaderDays: [Date],
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) {
        self.selectedDate = selectedDate
        self.visibleMonthAnchor = visibleMonthAnchor
        self.visibleDays = visibleDays
        self.weekHeaderDays = weekHeaderDays
        self.occurrencesByDay = occurrencesByDay
        // 无安排任务(dueDate==nil + recurrenceRule==nil)按"时间信号 + outcome + 完成态"拆四路:
        //   未完成 + outcome != .parsed         → 「没能识别」(unparsedTodos)
        //   未完成 + .parsed + 有时间信号        → 「待定日期」(pendingDateTodos)
        //   未完成 + .parsed + 无时间信号        → 「未定时间」(unscheduledTodos)
        //   已完成(不分 outcome / 时间信号)    → 「已完成」(completedUnscheduledTodos)
        //
        // 「时间信号」= timeBucket != nil 或 dueHint 非空。
        // 之前版本只看 dueDate==nil 就归「未安排」,导致"下午/等会儿"标签的条目也撒谎成"未安排"。
        let noSchedule = todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
        self.unparsedTodos = noSchedule
            .filter { !$0.isCompleted && $0.extractionOutcome != .parsed }
        let parsedIncomplete = noSchedule.filter { !$0.isCompleted && $0.extractionOutcome == .parsed }
        let hasTimeSignal: (TodoItemData) -> Bool = { todo in
            if todo.timeBucket != nil { return true }
            let hint = todo.dueHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !hint.isEmpty
        }
        self.pendingDateTodos = parsedIncomplete.filter(hasTimeSignal)
        self.unscheduledTodos = parsedIncomplete.filter { !hasTimeSignal($0) }
        self.completedUnscheduledTodos = noSchedule
            .filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        self.hasTodos = !todos.isEmpty
        self.calendar = calendar

        let selectedOccurrences = Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)
        self.selectedOccurrences = selectedOccurrences
        self.uncompletedOccurrences = selectedOccurrences.filter { !$0.isCompleted }
        self.completedOccurrences = selectedOccurrences.filter { $0.isCompleted }
    }

    private func occurrences(on day: Date) -> [TodoOccurrenceData] {
        Self.occurrences(on: day, in: occurrencesByDay, calendar: calendar)
    }

    private static func occurrences(
        on day: Date,
        in occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) -> [TodoOccurrenceData] {
        occurrencesByDay[TodoOccurrenceData.dayKey(for: day, calendar: calendar)] ?? []
    }

    /// WeekStripCard 图例数据源:当前周 7 天内**未完成** occurrence 涉及的所有分类,
    /// 去重后按 TodoCategory.allCases 固定顺序返回。
    ///
    /// 与 WeekStripCard.dayCell 圆点行口径完全一致:都看"未完成 occurrence 的类型"。
    /// 圆点行出现的颜色,图例必然有对应项;本周某分类全完成,图例项随之消失,
    /// 传达"这周这类已全部搞定"的语义。
    /// 整周未完成分类合集可能 5+ 个,FlowLayout 会自动换行 + 居中。
    func categoriesInWeek(of anchor: Date) -> [TodoCategory] {
        let weekDays = Self.weekDays(for: anchor, calendar: calendar)
        let weekUsed = Set(weekDays.flatMap { day in
            Self.occurrences(on: day, in: occurrencesByDay, calendar: calendar)
                .filter { !$0.isCompleted }
                .map { $0.todo.category }
        })
        return TodoCategory.allCases.filter { weekUsed.contains($0) }
    }

    /// 今天内未完成 occurrence 的三层分组,按时间确定度递增排序:
    ///   1. **整天**:`hasDueTime == false && timeBucket == nil`(无钟点无时段)
    ///   2. **时段**:`hasDueTime == false && timeBucket != nil`,按 morning → afternoon → evening 聚合
    ///   3. **按时间**:`hasDueTime == true`,按 `dueDate` 升序
    ///
    /// 设计意图:时间标签本身是入口——整天的卡片完全不动(无 chip 无按钮),
    /// 时段用 `.soft` chip(灰底),精确时刻用 `.solid` chip(彩色底)。
    /// 三层之间用细分隔线 + 小标签(`tierLabelRow`)区分,不抢外层「今天 / 待定日期 / 没能识别」的层级。
    var tieredUncompletedOccurrences: [(tier: TodayTier, items: [TodoOccurrenceData])] {
        var allDay: [TodoOccurrenceData] = []
        var byBucket: [TimeBucket: [TodoOccurrenceData]] = [:]
        var timed: [TodoOccurrenceData] = []

        for occurrence in uncompletedOccurrences {
            let todo = occurrence.todo
            if todo.hasDueTime {
                timed.append(occurrence)
            } else {
                let bucket = TimeBucketResolver.effective(
                    explicitBucket: todo.timeBucket,
                    dueDate: todo.dueDate,
                    hasDueTime: todo.hasDueTime,
                    calendar: calendar
                )
                if bucket == .anytime {
                    allDay.append(occurrence)
                } else {
                    byBucket[bucket, default: []].append(occurrence)
                }
            }
        }

        // 时段内保持原 sortOrder 稳定;时段间按 chronologicalOrder 固定。
        timed.sort { lhs, rhs in
            let lhsDate = lhs.todo.dueDate ?? .distantFuture
            let rhsDate = rhs.todo.dueDate ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.todo.sortOrder < rhs.todo.sortOrder
        }

        var result: [(tier: TodayTier, items: [TodoOccurrenceData])] = []
        if !allDay.isEmpty {
            result.append((.allDay, allDay))
        }
        for bucket in TimeBucket.chronologicalOrder where bucket != .anytime {
            if let items = byBucket[bucket], !items.isEmpty {
                result.append((.period(bucket), items))
            }
        }
        if !timed.isEmpty {
            result.append((.timed, timed))
        }
        return result
    }

    static func monthDays(for visibleMonthAnchor: Date, calendar: Calendar) -> [Date] {
        let monthStart = startOfMonth(for: visibleMonthAnchor, calendar: calendar)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// 锚点所在周的 7 天(周一起始)。
    /// 单一来源:WeekStripCard.weekDays 共用,保证"本周是哪 7 天"的算法不分散在多处。
    /// 若未来支持 RTL 周日起始或 Calendar.firstWeekday 配置,只改这里。
    static func weekDays(for anchor: Date, calendar: Calendar) -> [Date] {
        let start = startOfWeek(for: anchor, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func weekHeaderDays(referenceDate: Date, calendar: Calendar) -> [Date] {
        let monday = startOfWeek(for: referenceDate, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
    }
}

/// 今天内未完成 occurrence 的三档时间分层,对应 HTML 设计稿 line 326-367
/// 的细分隔线 + 小标签 tier 行。
enum TodayTier: Equatable, Sendable {
    /// 有日期,无钟点无时段(留空就是「不挑时间」,不写「未定时间」那种暗示缺信息的词)。
    case allDay
    /// 有日期,有时段(morning/afternoon/evening)但无钟点。`.soft` chip 样式。
    case period(TimeBucket)
    /// 有日期有钟点,按 dueDate 升序排列。`.solid` chip 样式。
    case timed

    /// tier-label 小标签的本地化文案(「整天」/「上午」/「下午」/「晚上」/「按时间」)。
    var localizedLabel: String {
        switch self {
        case .allDay:
            return String(localized: "home.tier.all_day")
        case .period(let bucket):
            switch bucket {
            case .morning: return String(localized: "home.tier.period.morning")
            case .afternoon: return String(localized: "home.tier.period.afternoon")
            case .evening: return String(localized: "home.tier.period.evening")
            case .anytime: return String(localized: "home.tier.all_day")
            }
        case .timed:
            return String(localized: "home.tier.timed")
        }
    }
}

enum HomeCalendarLoadState {
    case loading
    case empty
    case error
    case success
}

struct CalendarRefreshKey: Hashable {
    let anchor: Date
    let todos: [TodoItemData]
    let revision: Int
}
