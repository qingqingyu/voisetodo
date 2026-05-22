import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class ProtocolsTests: XCTestCase {

    func testPriorityRawValue() {
        XCTAssertEqual(Priority.high.rawValue, "high")
        XCTAssertEqual(Priority.normal.rawValue, "normal")
    }

    func testTodoCategoryEmoji() {
        XCTAssertEqual(TodoCategory.work.emoji, "💼")
        XCTAssertEqual(TodoCategory.study.emoji, "📚")
        XCTAssertEqual(TodoCategory.life.emoji, "🏠")
    }

    func testExtractedTodoCreation() {
        let todo = ExtractedTodo(title: "测试任务")
        XCTAssertEqual(todo.title, "测试任务")
        XCTAssertEqual(todo.priority, .normal)
        XCTAssertEqual(todo.categoryHint, .other)
    }

    func testTodoItemDataCreation() {
        let item = TodoItemData(title: "测试")
        XCTAssertEqual(item.title, "测试")
        XCTAssertFalse(item.isCompleted)
    }

    func testTodoItemDataFromExtracted() {
        let extracted = ExtractedTodo(title: "测试", detail: "详情")
        let item = TodoItemData(from: extracted)
        XCTAssertEqual(item.title, "测试")
        XCTAssertEqual(item.detail, "详情")
    }

    func testExtractionResultDecoding() throws {
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000001", "title": "任务", "detail": "", "priority": "normal", "categoryHint": "work"}],
            "ignored": ""
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "任务")
    }

    func testExtractionResultDecodesRecurrenceRule() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "title": "每周复盘",
                "detail": "每周五复盘",
                "due_hint": "每周五",
                "recurrence_rule": {
                    "frequency": "weekly",
                    "weekdays": [6],
                    "day_of_month": null,
                    "end_date": null
                },
                "priority": "normal",
                "category_hint": "work"
            }],
            "ignored": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule, RecurrenceRule(frequency: .weekly, weekdays: [6]))
    }

    func testExtractionResultHonorsExplicitNullRecurrenceRule() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000002",
                "title": "review",
                "detail": "every Friday review",
                "due_hint": "every Friday",
                "recurrence_rule": null,
                "priority": "normal",
                "category_hint": "work"
            }],
            "ignored": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertNil(result.todos[0].recurrenceRule)
    }

    func testExtractionResultInfersRecurrenceOnlyWhenFieldIsMissing() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000003",
                "title": "review",
                "detail": "every Friday review",
                "due_hint": "every Friday",
                "priority": "normal",
                "category_hint": "work"
            }],
            "ignored": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule, RecurrenceRule(frequency: .weekly, weekdays: [6]))
    }

    func testVoiceTodoErrorEquality() {
        XCTAssertEqual(VoiceTodoError.networkUnavailable, .networkUnavailable)
        XCTAssertEqual(VoiceTodoError.apiTimeout, .apiTimeout)
    }

    func testRecurrenceRuleResolverParsesChineseAndEnglishRules() throws {
        XCTAssertEqual(
            ExtractedTodo(title: "喝水", detail: "每天喝水").recurrenceRule,
            RecurrenceRule(frequency: .daily)
        )
        XCTAssertEqual(
            ExtractedTodo(title: "开会", detail: "每周一开会").recurrenceRule,
            RecurrenceRule(frequency: .weekly, weekdays: [2])
        )
        XCTAssertEqual(
            ExtractedTodo(title: "review", detail: "every Friday review").recurrenceRule,
            RecurrenceRule(frequency: .weekly, weekdays: [6])
        )
        XCTAssertEqual(
            ExtractedTodo(title: "交房租", detail: "每月1号交房租").recurrenceRule,
            RecurrenceRule(frequency: .monthly, dayOfMonth: 1)
        )
    }

    func testDueDateResolverParsesEnglishRelativeDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))

        let tomorrow = TodoDueDateResolver.resolve(
            dueHint: "tomorrow",
            referenceDate: reference,
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(tomorrow),
            inSameDayAs: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5)))
        ))

        let dayAfterTomorrow = TodoDueDateResolver.resolve(
            dueHint: "day after tomorrow",
            referenceDate: reference,
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(dayAfterTomorrow),
            inSameDayAs: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6)))
        ))
    }

    func testDueDateResolverParsesEnglishWeekdays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))

        let thisFriday = TodoDueDateResolver.resolve(
            dueHint: "by Friday",
            referenceDate: reference,
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(thisFriday),
            inSameDayAs: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 8)))
        ))

        let nextFriday = TodoDueDateResolver.resolve(
            dueHint: "by next Friday",
            referenceDate: reference,
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(
            try XCTUnwrap(nextFriday),
            inSameDayAs: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15)))
        ))
    }
}
