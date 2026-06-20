import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class DomainModuleTests: XCTestCase {
    func testRecurrenceRuleNormalizesInputsAndChecksOccurrences() throws {
        let calendar = Calendar(identifier: .gregorian)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 8)))
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 9)))

        let rule = RecurrenceRule(
            frequency: .weekly,
            weekdays: [6, 2, 2, 0, 8],
            endDate: friday
        )

        XCTAssertEqual(rule.weekdays, [2, 6])
        XCTAssertTrue(rule.occurs(on: monday, startDate: monday, calendar: calendar))
        XCTAssertTrue(rule.occurs(on: friday, startDate: monday, calendar: calendar))
        XCTAssertFalse(rule.occurs(on: saturday, startDate: monday, calendar: calendar))
    }

    func testTodoDueDateResolverParsesRelativeDaysAndExplicitWeekdays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5)))
        let nextFriday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15)))

        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "tomorrow", referenceDate: reference, calendar: calendar)),
            inSameDayAs: tomorrow
        ))
        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(TodoDueDateResolver.resolve(dueHint: "by next Friday", referenceDate: reference, calendar: calendar)),
            inSameDayAs: nextFriday
        ))
    }

    func testRecurrenceRuleResolverParsesRulesAndInferredEndDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))

        XCTAssertEqual(
            RecurrenceRuleResolver.resolve(dueHint: "每周五", title: "复盘", calendar: calendar),
            RecurrenceRule(frequency: .weekly, weekdays: [6])
        )
        XCTAssertEqual(
            RecurrenceRuleResolver.resolve(dueHint: "每月1号", title: "交房租", calendar: calendar),
            RecurrenceRule(frequency: .monthly, dayOfMonth: 1)
        )

        let boundedDaily = RecurrenceRuleResolver.resolve(
            dueHint: "未来的 7 天",
            title: "小单元测试",
            detail: "未来的 7 天，每天都要做一个小单元测试",
            referenceDate: reference,
            calendar: calendar
        )
        XCTAssertEqual(boundedDaily?.frequency, .daily)
        XCTAssertEqual(boundedDaily?.endDate, expectedEnd)
    }

    func testWidgetTodoFilterKeepsTodayAndUnscheduledItemsOnly() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))

        let todayRecurring = TodoItemData(
            title: "今天规律任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -3
        )
        let todayNormal = TodoItemData(
            title: "今天普通任务",
            dueDate: today,
            createdAt: today,
            sortOrder: -2
        )
        let tomorrowNormal = TodoItemData(
            title: "明天任务",
            dueDate: tomorrow,
            createdAt: today,
            sortOrder: -1
        )
        let unscheduled = TodoItemData(
            title: "无日期任务",
            createdAt: today,
            sortOrder: 0
        )

        let result = WidgetTodoFilter.visibleTodos(
            from: [todayRecurring, todayNormal, tomorrowNormal, unscheduled],
            completionKeys: [],
            today: today,
            limit: 10,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), ["今天规律任务", "今天普通任务", "无日期任务"])
    }
}
