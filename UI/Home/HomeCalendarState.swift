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

    /// WeekStripCard 图例数据源:当前周 7 天内 occurrence 涉及的所有分类,去重后按
    /// TodoCategory.allCases 固定顺序返回。
    ///
    /// 算法:收集本周 7 天所有 occurrence 的分类合集,不做任何减法。
    /// 早期版本曾与 unscheduledTodos 做减法(只显示"本周独占"分类)以控制项数避免一行排不下,
    /// 但用户反馈:图例应反映"本周出现了哪些分类"——昨天/前天的项目也算本周,不应被 backlog
    /// 抵消掉。整周分类合集可能 5+ 个,FlowLayout 会自动换行 + 居中,不再需要靠减法省空间。
    func categoriesInWeek(of anchor: Date) -> [TodoCategory] {
        let weekDays = Self.weekDays(for: anchor, calendar: calendar)
        let weekUsed = Set(weekDays.flatMap { day in
            Self.occurrences(on: day, in: occurrencesByDay, calendar: calendar).map { $0.todo.category }
        })
        return TodoCategory.allCases.filter { weekUsed.contains($0) }
    }

    /// 未完成 occurrence 按时间排序:有钟点的按 dueDate 升序,无钟点的排最后(保持原 sortOrder)。
    /// 用于扁平化列表渲染——替代旧的 TimeBucket 分组,消除半空时段子标题。
    var sortedUncompletedOccurrences: [TodoOccurrenceData] {
        uncompletedOccurrences.sorted { lhs, rhs in
            let lhsHasTime = lhs.todo.hasDueTime && lhs.todo.dueDate != nil
            let rhsHasTime = rhs.todo.hasDueTime && rhs.todo.dueDate != nil
            if lhsHasTime != rhsHasTime {
                return lhsHasTime  // 有钟点的排前面
            }
            if lhsHasTime, let lhsDue = lhs.todo.dueDate, let rhsDue = rhs.todo.dueDate {
                return lhsDue < rhsDue
            }
            return lhs.todo.sortOrder < rhs.todo.sortOrder
        }
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
