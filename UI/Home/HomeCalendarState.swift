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

/// 首页日历视图模式：整月网格 / 单周一行。
enum CalendarViewMode: String {
    case month
    case week
}

/// 首页日历显示样式：与 `CalendarViewMode` 正交。
/// - `.list`：每个日期格只渲染数字 + 圆点（旧版默认）
/// - `.grid`：每个日期格渲染数字 + ≤2 个事件条 + `+N`（网格+月）；
///            或单周 7 天横排时间轴（网格+周）。
/// 手势只切 `viewMode`，与 `displayMode` 完全独立——4 种组合全部成立。
/// 通过 `@AppStorage("calendarDisplayMode")` 持久化，与 `calendarViewMode` 同套机制。
enum CalendarDisplayMode: String {
    case list
    case grid
}

struct HomeCalendarState {
    let selectedDate: Date
    let visibleMonthAnchor: Date
    let viewMode: CalendarViewMode
    /// 当前模式下要渲染的日期：月视图为整月网格（42 天），周视图为所在周 7 天。
    let visibleDays: [Date]
    let weekHeaderDays: [Date]
    let occurrencesByDay: [String: [TodoOccurrenceData]]
    let unscheduledTodos: [TodoItemData]
    /// 已完成的无安排任务（dueDate==nil && recurrenceRule==nil && isCompleted）。
    /// 按 completedAt 倒序——最近完成在上。用于在底部「已完成」分区里和 occurrence 一起显示。
    /// 与 `unscheduledTodos` 对称：那个只留未完成（留在「未安排」分区），
    /// 这个只留已完成（下移到「已完成」分区），让无安排任务的完成行为和有安排任务对齐。
    let completedUnscheduledTodos: [TodoItemData]
    let selectedOccurrences: [TodoOccurrenceData]
    let uncompletedOccurrences: [TodoOccurrenceData]
    let completedOccurrences: [TodoOccurrenceData]
    let hasTodos: Bool

    /// 状态层使用的 calendar 实例（注入时传入）。暴露给视图层（如 `WeekTimelineView.position`）
    /// 是为了确保 hour/minute 计算与 `occurrencesByDay` 的 dayKey 聚合口径一致——
    /// 若视图层自己用 `Calendar.current` 在非 gregorian locale 下会产生错位。
    let calendar: Calendar

    /// 页头大标题下方的小字说明：月视图显示年份（大标题已有月份名），周视图显示周范围。
    /// 静态方法——页头（HomeView.headerView）没有完整的 HomeCalendarState，只有 anchor + viewMode。
    static func periodCaption(anchor: Date, viewMode: CalendarViewMode, calendar: Calendar) -> String {
        switch viewMode {
        case .month:
            return anchor.formatted(.dateTime.year())
        case .week:
            let visibleDays = days(for: viewMode, anchor: anchor, calendar: calendar)
            guard let first = visibleDays.first, let last = visibleDays.last else {
                return anchor.formatted(.dateTime.year())
            }
            // 去掉 zh/ja locale 下 `.dateTime.month().day()` 默认追加的"日"后缀，
            // 保留 locale-aware 的月份/日表达。en/等无此后缀的语言 hasSuffix 不命中即 no-op。
            // 注意：ko locale 的"일"后缀未在此处理——若后续要支持 ko，需扩展 stripDaySuffix
            // 并按字符（而非字节）dropLast；当前目标用户语言为 zh/en，ko 不在范围内。
            return "\(stripDaySuffix(first.formatted(.dateTime.month().day()))) – \(stripDaySuffix(last.formatted(.dateTime.month().day())))"
        }
    }

    /// 去掉 `.formatted(.dateTime.day())` 在 zh/ja locale 末尾产生的"日"后缀。
    /// 仅当以单字符"日"结尾时删除——避免误伤含"日"的星期或更复杂文案（此处 month().day() 不会出现）。
    /// ko locale 的"일"后缀不在处理范围（见 periodCaption 上方注释）。
    private static func stripDaySuffix(_ formatted: String) -> String {
        guard formatted.hasSuffix("日") else { return formatted }
        return String(formatted.dropLast())
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
        viewMode: CalendarViewMode,
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar,
        now: Date = Date()
    ) -> HomeCalendarState {
        let normalizedSelectedDate = calendar.startOfDay(for: selectedDate)
        let normalizedAnchor = calendar.startOfDay(for: visibleMonthAnchor)
        let visibleDays = days(for: viewMode, anchor: normalizedAnchor, calendar: calendar)

        return HomeCalendarState(
            todos: store.todos,
            selectedDate: normalizedSelectedDate,
            visibleMonthAnchor: normalizedAnchor,
            viewMode: viewMode,
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
            // 周视图 7 天等权重，不按"当月"置灰；月视图保留跨月补齐日的弱化样式。
            isCurrentMonth: viewMode == .week
                ? true
                : calendar.isDate(day, equalTo: visibleMonthAnchor, toGranularity: .month)
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
        viewMode: CalendarViewMode,
        visibleDays: [Date],
        weekHeaderDays: [Date],
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) {
        self.selectedDate = selectedDate
        self.visibleMonthAnchor = visibleMonthAnchor
        self.viewMode = viewMode
        self.visibleDays = visibleDays
        self.weekHeaderDays = weekHeaderDays
        self.occurrencesByDay = occurrencesByDay
        // 无安排任务（无 dueDate + 无 recurrenceRule）按完成态拆两路：
        // 未完成 → 留在「未安排」分区（可重排/可拖月历）
        // 已完成 → 下移到底部「已完成」分区，跟 occurrence 的完成行为对齐
        let unscheduled = todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
        self.unscheduledTodos = unscheduled.filter { !$0.isCompleted }
        self.completedUnscheduledTodos = unscheduled
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

    func indexedUncompletedOccurrences(in timeBucket: TimeBucket) -> [(Int, TodoOccurrenceData)] {
        uncompletedOccurrences.enumerated().compactMap { index, occurrence in
            let effectiveBucket = TimeBucketResolver.effective(
                explicitBucket: occurrence.todo.timeBucket,
                dueDate: occurrence.todo.dueDate,
                hasDueTime: occurrence.todo.hasDueTime,
                calendar: calendar
            )
            return effectiveBucket == timeBucket ? (index, occurrence) : nil
        }
    }

    /// 按模式返回要渲染/加载的日期集合。月视图 42 天网格；周视图所在周 7 天。
    static func days(for viewMode: CalendarViewMode, anchor: Date, calendar: Calendar) -> [Date] {
        switch viewMode {
        case .month:
            return monthDays(for: anchor, calendar: calendar)
        case .week:
            return weekDays(for: anchor, calendar: calendar)
        }
    }

    static func monthDays(for visibleMonthAnchor: Date, calendar: Calendar) -> [Date] {
        let monthStart = startOfMonth(for: visibleMonthAnchor, calendar: calendar)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// 锚点所在周的 7 天（与月视图同为周一起始，复用 startOfWeek）。
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

enum HomeCalendarLoadState {
    case loading
    case empty
    case error
    case success
}

struct CalendarRefreshKey: Hashable {
    let anchor: Date
    let mode: CalendarViewMode
    let todos: [TodoItemData]
    let revision: Int
}
