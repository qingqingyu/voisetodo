import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// 阶段 0 数据体检纯函数用例(docs/todo-review-flow-design.md「阶段 0 · 数据体检」)。
/// 日期/周数断言按项目惯例用 `Calendar.current`。
final class DataHealthDiagnosticsTests: XCTestCase {
    private var calendar: Calendar { .current }

    private func daysAgo(_ n: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: -n, to: now)!
    }

    // MARK: - 空库

    func testEmptyLibraryReturnsAllZeros() {
        let stats = DataHealthAnalyzer.analyze([], asOf: Date(), calendar: calendar)
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.highPriorityCount, 0)
        XCTAssertEqual(stats.highPriorityCompletedCount, 0)
        XCTAssertEqual(stats.highPriorityRatio, 0)
        XCTAssertEqual(stats.hasDueTimeRatio, 0)
        XCTAssertEqual(stats.completedCount, 0)
        XCTAssertEqual(stats.completedWithDueDateCount, 0)
        XCTAssertTrue(stats.completedByCategory.isEmpty)
        XCTAssertEqual(stats.libraryAgeWeeks, 0)
    }

    // MARK: - 全 high

    func testAllHighPriority() {
        let now = Date()
        let items = [
            TodoItemData(title: "a", priority: .high, isCompleted: true, completedAt: now),
            TodoItemData(title: "b", priority: .high),
            TodoItemData(title: "c", priority: .high),
            TodoItemData(title: "d", priority: .high)
        ]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.totalCount, 4)
        XCTAssertEqual(stats.highPriorityCount, 4)
        XCTAssertEqual(stats.highPriorityCompletedCount, 1)
        XCTAssertEqual(stats.highPriorityRatio, 1.0, accuracy: 0.0001)
    }

    // MARK: - 混合优先级

    func testMixedPriorityRatios() {
        let now = Date()
        let items = [
            TodoItemData(title: "high-done", priority: .high, isCompleted: true, completedAt: now),
            TodoItemData(title: "high-todo", priority: .high),
            TodoItemData(title: "normal", priority: .normal),
            TodoItemData(title: "low", priority: .low),
            TodoItemData(title: "normal-2", priority: .normal),
            TodoItemData(title: "normal-done", priority: .normal, isCompleted: true, completedAt: now),
            TodoItemData(title: "low-done", priority: .low, isCompleted: true, completedAt: now),
            TodoItemData(title: "normal-3", priority: .normal)
        ]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.totalCount, 8)
        XCTAssertEqual(stats.highPriorityCount, 2)
        XCTAssertEqual(stats.highPriorityCompletedCount, 1)
        XCTAssertEqual(stats.highPriorityRatio, 0.25, accuracy: 0.0001)
        XCTAssertEqual(stats.completedCount, 3)
    }

    // MARK: - hasDueTime 混合

    func testHasDueTimeMixedRatio() {
        let now = Date()
        let items = [
            TodoItemData(title: "timed", dueDate: now, hasDueTime: true),
            TodoItemData(title: "timed-done", dueDate: now, hasDueTime: true, isCompleted: true, completedAt: now),
            TodoItemData(title: "allday", dueDate: now, hasDueTime: false),
            TodoItemData(title: "nodate", hasDueTime: false)
        ]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.hasDueTimeRatio, 0.5, accuracy: 0.0001)
    }

    // MARK: - 已完成 + dueDate + 分类分布

    func testCompletedDistributionAndCategories() {
        let now = Date()
        let items = [
            TodoItemData(title: "done-with-date", dueDate: daysAgo(1, from: now), category: .work, isCompleted: true, completedAt: now),
            TodoItemData(title: "done-no-date", category: .work, isCompleted: true, completedAt: now),
            TodoItemData(title: "done-with-date-2", dueDate: now, category: .study, isCompleted: true, completedAt: now),
            TodoItemData(title: "todo-with-date", dueDate: now, category: .life),
            TodoItemData(title: "todo-no-date", category: .other)
        ]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.completedCount, 3)
        XCTAssertEqual(stats.completedWithDueDateCount, 2)
        XCTAssertEqual(stats.completedByCategory[.work], 2)
        XCTAssertEqual(stats.completedByCategory[.study], 1)
        XCTAssertNil(stats.completedByCategory[.life])
        XCTAssertEqual(stats.completedByCategory.count, 2)
    }

    // MARK: - 库龄周数

    func testLibraryAgeExactlyFourWeeks() {
        let now = Date()
        let items = [TodoItemData(title: "oldest", createdAt: daysAgo(28, from: now))]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.libraryAgeWeeks, 4)
    }

    func testLibraryAgeJustUnderFourWeeks() {
        let now = Date()
        let items = [TodoItemData(title: "oldest", createdAt: daysAgo(27, from: now))]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.libraryAgeWeeks, 3)
    }

    func testLibraryAgeUsesEarliestCreatedAtAndIgnoresFuture() {
        let now = Date()
        let items = [
            TodoItemData(title: "newer", createdAt: daysAgo(10, from: now)),
            TodoItemData(title: "oldest", createdAt: daysAgo(63, from: now)),
            TodoItemData(title: "future-clock-skew", createdAt: calendar.date(byAdding: .hour, value: 1, to: now)!)
        ]
        let stats = DataHealthAnalyzer.analyze(items, asOf: now, calendar: calendar)
        XCTAssertEqual(stats.libraryAgeWeeks, 9)
    }
}
