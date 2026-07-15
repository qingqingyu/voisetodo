import Foundation
import SwiftUI

struct HomeCalendarDayState {
    let date: Date
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

struct HomeCalendarState {
    let selectedDate: Date
    let visibleMonthAnchor: Date
    let viewMode: CalendarViewMode
    /// 当前模式下要渲染的日期：月视图为整月网格（42 天），周视图为所在周 7 天。
    let visibleDays: [Date]
    let weekHeaderDays: [Date]
    let occurrencesByDay: [String: [TodoOccurrenceData]]
    let unscheduledTodos: [TodoItemData]
    let selectedOccurrences: [TodoOccurrenceData]
    let uncompletedOccurrences: [TodoOccurrenceData]
    let completedOccurrences: [TodoOccurrenceData]
    let hasTodos: Bool

    private let calendar: Calendar

    var monthTitle: String {
        switch viewMode {
        case .month:
            return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
        case .week:
            guard let first = visibleDays.first, let last = visibleDays.last else {
                return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
            }
            // 去掉 zh/ja locale 下 `.dateTime.month().day()` 默认追加的"日"后缀，
            // 保留 locale-aware 的月份/日表达。en/等无此后缀的语言 hasSuffix 不命中即 no-op。
            // 注意：ko locale 的"일"后缀未在此处理——若后续要支持 ko，需扩展 stripDaySuffix
            // 并按字符（而非字节）dropLast；当前目标用户语言为 zh/en，ko 不在范围内。
            return "\(Self.stripDaySuffix(first.formatted(.dateTime.month().day()))) – \(Self.stripDaySuffix(last.formatted(.dateTime.month().day())))"
        }
    }

    /// 去掉 `.formatted(.dateTime.day())` 在 zh/ja locale 末尾产生的"日"后缀。
    /// 仅当以单字符"日"结尾时删除——避免误伤含"日"的星期或更复杂文案（此处 month().day() 不会出现）。
    /// ko locale 的"일"后缀不在处理范围（见 monthTitle 上方注释）。
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
        self.unscheduledTodos = todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
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
