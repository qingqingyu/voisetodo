import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// dayStartHour 自定义一天起始时刻的边界测试。
/// 集中验证 hour=3 时，TodoDueDateResolver / ReviewAggregator / WidgetTodoFilter
/// 在凌晨 0–3 点的语义归属是否符合用户预期（路线 A：UI 边界用 userDay，
/// occurrenceKey / RecurrenceRule.occurs 保留自然日）。
final class DayStartHourBoundaryTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    override func tearDown() {
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    private func makeCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: - TodoDueDateResolver

    func testResolverHour3_oneAM_saysToday_returnsPreviousUserDay() throws {
        // hour=3，凌晨 1 点说"今天"，应该返回前一日 03:00（用户日"今天"）
        DayClock.setStartHour(3)
        let calendar = makeCalendar(timeZone: shanghai)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1)))

        let result = try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "今天", referenceDate: reference, calendar: calendar))

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testResolverHour3_fourAM_saysToday_returnsCurrentUserDay() throws {
        // hour=3，凌晨 4 点说"今天"，应该返回当日 03:00
        DayClock.setStartHour(3)
        let calendar = makeCalendar(timeZone: shanghai)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 4)))

        let result = try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "今天", referenceDate: reference, calendar: calendar))

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testResolverHour3_oneAM_saysTomorrow_returnsTodayUserDay() throws {
        // hour=3，凌晨 1 点说"明天"，应该是用户日的明天 = 当前用户日 + 1 天
        DayClock.setStartHour(3)
        let calendar = makeCalendar(timeZone: shanghai)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1)))

        let result = try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "明天", referenceDate: reference, calendar: calendar))

        // 用户日"今天" = 2026-03-14 03:00；明天 = 2026-03-15 03:00
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testResolverHour0_behaviorUnchanged() throws {
        // hour=0 时与历史行为一致：自然日 0 点
        DayClock.setStartHour(0)
        let calendar = makeCalendar(timeZone: shanghai)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)))

        let result = try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "今天", referenceDate: reference, calendar: calendar))

        XCTAssertEqual(result, calendar.startOfDay(for: reference))
    }

    // MARK: - ReviewAggregator

    func testAggregatorHour3_completionAt1AM_belongsToPreviousUserDay() throws {
        // hour=3，凌晨 1:30 完成的 event 归属"用户日 3/14"（= 3/14 03:00 起）
        // ReviewAggregator 会把 startDay/endDay 用 userDay 归一化，
        // 所以传入时直接用 userDay 起点（3/14 03:00、3/15 03:00）。
        DayClock.setStartHour(3)
        let calendar = makeCalendar(timeZone: shanghai)

        let startDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 3)))
        let endDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        let completedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)))

        let event = CompletionEvent(id: UUID(), completedAt: completedAt, category: .life)
        let summary = ReviewAggregator.summarize(events: [event], from: startDay, to: endDay, calendar: calendar)

        // 该 event 归属于 [startDay, endDay) 区间内的"用户日 3/14"
        XCTAssertEqual(summary.total, 1)
        let expectedDayKey = DayClock.startOfUserDay(for: completedAt, calendar: calendar)
        XCTAssertEqual(summary.byDay[expectedDayKey], 1)
    }

    func testAggregatorHour0_completionAt1AM_belongsToSameNaturalDay() throws {
        // hour=0 时，凌晨 1:30 完成的 event 归属当日（自然日语义，零回归）
        DayClock.setStartHour(0)
        let calendar = makeCalendar(timeZone: shanghai)

        let startDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let endDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 16)))
        let completedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)))

        let event = CompletionEvent(id: UUID(), completedAt: completedAt, category: .life)
        let summary = ReviewAggregator.summarize(events: [event], from: startDay, to: endDay, calendar: calendar)

        XCTAssertEqual(summary.total, 1)
        let expectedDayKey = calendar.startOfDay(for: completedAt)
        XCTAssertEqual(summary.byDay[expectedDayKey], 1)
    }

    // MARK: - WidgetTodoFilter

    func testWidgetFilterHour3_oneAM_showsTasksFromPreviousUserDay() throws {
        // hour=3，凌晨 1:30 打开 Widget。用户日"今天"= 前一日 03:00 起。
        // 应显示：
        //   - 每日任务（自然日"前一日"出现，路线 A 下 occurs 判断前一日）
        //   - 非重复任务 dueDate 在前一日（自然日）的
        DayClock.setStartHour(3)
        let calendar = makeCalendar(timeZone: shanghai)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)))

        // 每日任务
        let daily = TodoItemData(
            title: "每日任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: calendar.date(byAdding: .day, value: -10, to: today)!,
            sortOrder: -3
        )
        // dueDate 在前一日（自然日 2026-03-14）的非重复任务
        let yesterdayDue = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))
        let yesterdayTask = TodoItemData(
            title: "昨日截止任务",
            dueDate: yesterdayDue,
            createdAt: calendar.date(byAdding: .day, value: -10, to: today)!,
            sortOrder: -2
        )
        // dueDate 在今日（自然日 2026-03-15）的非重复任务
        let todayDue = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let todayTask = TodoItemData(
            title: "今日截止任务",
            dueDate: todayDue,
            createdAt: calendar.date(byAdding: .day, value: -10, to: today)!,
            sortOrder: -1
        )

        let result = WidgetTodoFilter.visibleTodos(
            from: [daily, yesterdayTask, todayTask],
            completionKeys: [],
            today: today,
            limit: 10,
            calendar: calendar
        )

        // 每日任务在自然日"前一日"出现（occurs 判断），应显示。
        // 昨日截止任务 dueDate=前一日 0 点，跟 day（前一日 03:00）同自然日，应显示。
        // 今日截止任务 dueDate=今日 0 点，跟 day（前一日 03:00）不同自然日，不应显示。
        let titles = result.map(\.title)
        XCTAssertTrue(titles.contains("每日任务"))
        XCTAssertTrue(titles.contains("昨日截止任务"))
        XCTAssertFalse(titles.contains("今日截止任务"))
    }

    func testWidgetFilterHour0_behaviorUnchanged() throws {
        // hour=0 时，凌晨 1:30 打开 Widget，行为同历史
        DayClock.setStartHour(0)
        let calendar = makeCalendar(timeZone: shanghai)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)))

        let todayDue = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let todayTask = TodoItemData(
            title: "今日任务",
            dueDate: todayDue,
            createdAt: calendar.date(byAdding: .day, value: -10, to: today)!,
            sortOrder: 0
        )

        let result = WidgetTodoFilter.visibleTodos(
            from: [todayTask],
            completionKeys: [],
            today: today,
            limit: 10,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), ["今日任务"])
    }
}
