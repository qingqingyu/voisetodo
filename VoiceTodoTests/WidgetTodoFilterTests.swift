import XCTest
import SwiftData
@testable import VoiceTodo

@MainActor
final class WidgetTodoFilterTests: XCTestCase {
    func testAppGroupIdentifierMatchesWidgetConfig() {
        XCTAssertEqual(AppGroupConfig.identifier, WidgetConfig.appGroupIdentifier)
    }

    func testExternalChangeVersionCanBeMarkedWhenSharedDefaultsIsAvailable() throws {
        guard AppGroupConfig.sharedDefaults() != nil else {
            throw XCTSkip("App Group defaults are unavailable without the test host entitlement.")
        }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        AppGroupConfig.markExternalDataChanged(date: date)

        XCTAssertEqual(AppGroupConfig.currentExternalChangeVersion(), date.timeIntervalSince1970)
    }

    func testVisibleTodosShowsTodayRecurringAndFiltersFutureAndCompletedOccurrences() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)

        let todayRecurring = TodoItemData(
            title: "今天规律任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -4
        )
        let futureRecurring = TodoItemData(
            title: "未来规律任务",
            dueDate: tomorrow,
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today,
            sortOrder: -3
        )
        let completedRecurring = TodoItemData(
            title: "今天已完成规律任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -2
        )
        let todayNormal = TodoItemData(
            title: "今天普通任务",
            dueDate: today,
            createdAt: today,
            sortOrder: -1
        )
        let completedNormal = TodoItemData(
            title: "已完成普通任务",
            dueDate: today,
            isCompleted: true,
            createdAt: today,
            sortOrder: 0
        )
        let completionKeys = Set([
            TodoOccurrenceCompletion.key(
                todoId: completedRecurring.id,
                occurrenceDate: today,
                calendar: calendar
            )
        ])

        let result = WidgetTodoFilter.visibleTodos(
            from: [todayRecurring, futureRecurring, completedRecurring, todayNormal, completedNormal],
            completionKeys: completionKeys,
            today: today,
            limit: 10,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), ["今天规律任务", "今天普通任务"])
    }

    func testVisibleTodosPrioritizesTodayItemsBeforeUnscheduledSupplement() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))

        let unscheduled = TodoItemData(
            title: "无日期补充任务",
            createdAt: today,
            sortOrder: -2
        )
        let todayNormal = TodoItemData(
            title: "今天任务",
            dueDate: today,
            createdAt: today,
            sortOrder: -1
        )

        let result = WidgetTodoFilter.visibleTodos(
            from: [unscheduled, todayNormal],
            completionKeys: [],
            today: today,
            limit: 1,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), ["今天任务"])
    }

    func testWidgetTodoFetchReadsSwiftDataAndFiltersTodayOccurrences() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TodoItem.self, TodoOccurrenceCompletion.self, configurations: config)
        let context = container.mainContext

        let unscheduled = TodoItem(title: "无日期补充任务", createdAt: today, sortOrder: -4)
        let todayRecurring = TodoItem(
            title: "今天规律任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -3
        )
        let futureRecurring = TodoItem(
            title: "未来规律任务",
            dueDate: tomorrow,
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today,
            sortOrder: -2
        )
        let completedRecurring = TodoItem(
            title: "今天已完成规律任务",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )

        context.insert(unscheduled)
        context.insert(todayRecurring)
        context.insert(futureRecurring)
        context.insert(completedRecurring)
        context.insert(TodoOccurrenceCompletion(todoId: completedRecurring.id, occurrenceDate: today, calendar: calendar))
        try context.save()

        let result = try WidgetTodoFetch.recentTodos(
            context: context,
            today: today,
            limit: 2,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), ["今天规律任务", "无日期补充任务"])
    }

    func testWidgetTodoFetchHonorsCandidateScanLimit() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TodoItem.self, TodoOccurrenceCompletion.self, configurations: config)
        let context = container.mainContext

        for index in 0..<5 {
            context.insert(TodoItem(
                title: "未来任务 \(index)",
                dueDate: tomorrow,
                createdAt: today,
                sortOrder: index
            ))
        }
        context.insert(TodoItem(
            title: "候选范围外的今天任务",
            dueDate: today,
            createdAt: today,
            sortOrder: 6
        ))
        try context.save()

        let result = try WidgetTodoFetch.recentTodos(
            context: context,
            today: today,
            limit: 1,
            maxCandidateScan: 5,
            calendar: calendar
        )

        XCTAssertTrue(result.isEmpty)
    }
}
