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

    func testWidgetInteractionErrorReadsWhenFreshAndExpiresAfterRetention() throws {
        let defaults = try makeTemporaryDefaults()
        let todoID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        AppGroupConfig.recordWidgetInteractionError(
            operation: .toggleTodo,
            todoID: todoID,
            date: timestamp,
            defaults: defaults
        )

        let fresh = try XCTUnwrap(AppGroupConfig.widgetInteractionError(
            from: defaults,
            now: timestamp.addingTimeInterval(WidgetConfig.interactionErrorRetention - 1)
        ))
        XCTAssertEqual(fresh.operation, .toggleTodo)
        XCTAssertEqual(fresh.todoID, todoID)
        XCTAssertEqual(fresh.messageKey, WidgetInteractionError.defaultMessageKey)
        XCTAssertNil(AppGroupConfig.widgetInteractionError(
            from: defaults,
            now: timestamp.addingTimeInterval(WidgetConfig.interactionErrorRetention + 1)
        ))
    }

    func testWidgetInteractionErrorCanBeCleared() throws {
        let defaults = try makeTemporaryDefaults()
        AppGroupConfig.recordWidgetInteractionError(
            operation: .toggleTodo,
            todoID: UUID(),
            defaults: defaults
        )

        AppGroupConfig.clearWidgetInteractionError(defaults: defaults)

        XCTAssertNil(AppGroupConfig.widgetInteractionError(from: defaults))
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

    func testVisibleTodosKeepsRecentlyCompletedNormalTodoForWidgetIntermediateAnimation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 12)))
        let cutoff = today.addingTimeInterval(-WidgetConfig.completionAnimationRetention)

        let recentlyCompleted = TodoItemData(
            title: "刚完成普通任务",
            dueDate: today,
            isCompleted: true,
            completedAt: today.addingTimeInterval(-0.1),
            createdAt: today,
            sortOrder: -3
        )
        let oldCompleted = TodoItemData(
            title: "旧完成普通任务",
            dueDate: today,
            isCompleted: true,
            completedAt: today.addingTimeInterval(-2),
            createdAt: today,
            sortOrder: -2
        )
        let uncompleted = TodoItemData(
            title: "未完成普通任务",
            dueDate: today,
            createdAt: today,
            sortOrder: -1
        )

        let result = WidgetTodoFilter.visibleTodos(
            from: [recentlyCompleted, oldCompleted, uncompleted],
            completionKeys: [],
            today: today,
            limit: 10,
            calendar: calendar,
            recentCompletionCutoff: cutoff
        )

        XCTAssertEqual(result.map(\.title), ["刚完成普通任务", "未完成普通任务"])
        XCTAssertTrue(try XCTUnwrap(result.first).isCompleted)
    }

    func testWidgetTodoFetchKeepsRecentlyCompletedRecurringOccurrenceForWidgetIntermediateAnimation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 12)))
        let cutoff = today.addingTimeInterval(-WidgetConfig.completionAnimationRetention)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TodoItem.self, TodoOccurrenceCompletion.self, configurations: config)
        let context = container.mainContext

        let recentlyCompleted = TodoItem(
            title: "刚完成规律任务",
            dueDate: today,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -2
        )
        let oldCompleted = TodoItem(
            title: "旧完成规律任务",
            dueDate: today,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )

        context.insert(recentlyCompleted)
        context.insert(oldCompleted)
        context.insert(TodoOccurrenceCompletion(
            todoId: recentlyCompleted.id,
            occurrenceDate: today,
            completedAt: today.addingTimeInterval(-0.1),
            calendar: calendar
        ))
        context.insert(TodoOccurrenceCompletion(
            todoId: oldCompleted.id,
            occurrenceDate: today,
            completedAt: today.addingTimeInterval(-2),
            calendar: calendar
        ))
        try context.save()

        let intermediateResult = try WidgetTodoFetch.recentTodos(
            context: context,
            today: today,
            limit: 10,
            calendar: calendar,
            recentCompletionCutoff: cutoff
        )
        let filteredResult = try WidgetTodoFetch.recentTodos(
            context: context,
            today: today,
            limit: 10,
            calendar: calendar
        )

        XCTAssertEqual(intermediateResult.map(\.title), ["刚完成规律任务"])
        XCTAssertTrue(try XCTUnwrap(intermediateResult.first).isCompleted)
        XCTAssertTrue(filteredResult.isEmpty)
    }

    func testToggleTodoMutationTogglesNormalTodoCompletionAndCompletedAt() throws {
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 12)))
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let todo = TodoItem(title: "普通任务", createdAt: now)
        context.insert(todo)
        try context.save()

        let completed = try ToggleTodoMutation.apply(todoID: todo.id, context: context, today: now, completedAt: now)
        XCTAssertEqual(completed, .toggled(recurrence: false, isCompleted: true))
        XCTAssertTrue(todo.isCompleted)
        XCTAssertEqual(todo.completedAt, now)

        let uncompleted = try ToggleTodoMutation.apply(
            todoID: todo.id,
            context: context,
            today: now.addingTimeInterval(1),
            completedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(uncompleted, .toggled(recurrence: false, isCompleted: false))
        XCTAssertFalse(todo.isCompleted)
        XCTAssertNil(todo.completedAt)
    }

    func testToggleTodoMutationTogglesTodayRecurringOccurrenceWithoutCompletingBaseTodo() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 12)))
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let todo = TodoItem(
            title: "规律任务",
            dueDate: today,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today
        )
        context.insert(todo)
        try context.save()

        let completed = try ToggleTodoMutation.apply(
            todoID: todo.id,
            context: context,
            today: today,
            calendar: calendar,
            completedAt: today
        )
        XCTAssertEqual(completed, .toggled(recurrence: true, isCompleted: true))
        XCTAssertFalse(todo.isCompleted)

        var descriptor = FetchDescriptor<TodoOccurrenceCompletion>()
        let completionsAfterComplete = try context.fetch(descriptor)
        XCTAssertEqual(completionsAfterComplete.count, 1)
        XCTAssertEqual(completionsAfterComplete.first?.todoId, todo.id)

        let uncompleted = try ToggleTodoMutation.apply(
            todoID: todo.id,
            context: context,
            today: today,
            calendar: calendar,
            completedAt: today.addingTimeInterval(1)
        )
        XCTAssertEqual(uncompleted, .toggled(recurrence: true, isCompleted: false))
        XCTAssertFalse(todo.isCompleted)

        descriptor = FetchDescriptor<TodoOccurrenceCompletion>()
        XCTAssertTrue(try context.fetch(descriptor).isEmpty)
    }

    func testToggleTodoMutationIgnoresRecurringTodoThatDoesNotOccurToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 21)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let todo = TodoItem(
            title: "未来规律任务",
            dueDate: tomorrow,
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today
        )
        context.insert(todo)
        try context.save()

        let result = try ToggleTodoMutation.apply(
            todoID: todo.id,
            context: context,
            today: today,
            calendar: calendar,
            completedAt: today
        )

        XCTAssertEqual(result, .nonOccurringToday)
        XCTAssertFalse(todo.isCompleted)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TodoOccurrenceCompletion>()).isEmpty)
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

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TodoItem.self, TodoOccurrenceCompletion.self, configurations: config)
    }

    private func makeTemporaryDefaults() throws -> UserDefaults {
        let suiteName = "VoiceTodoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
