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

    func testUITestLaunchOptionsDecodesPresetTodos() throws {
        let todo = TodoItemData(title: "Preset todo", hasDueTime: true)
        let data = try JSONEncoder().encode([todo])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let options = UITestLaunchOptions(arguments: ["--ui-testing", "--todos-data=\(json)"])

        XCTAssertNil(options.presetTodosDecodeError)
        XCTAssertEqual(options.presetTodos.map(\.title), ["Preset todo"])
        XCTAssertEqual(options.presetTodos.first?.hasDueTime, true)
    }

    func testUITestLaunchOptionsRecordsPresetTodoDecodeFailure() {
        let options = UITestLaunchOptions(arguments: ["--ui-testing", "--todos-data=not-json"])

        XCTAssertTrue(options.presetTodos.isEmpty)
        XCTAssertNotNil(options.presetTodosDecodeError)
    }

    func testUITestLaunchOptionsRequiresDataWhenPresetTodosRequested() {
        let options = UITestLaunchOptions(arguments: ["--ui-testing", "--preset-todos"])

        XCTAssertTrue(options.presetTodos.isEmpty)
        XCTAssertNotNil(options.presetTodosDecodeError)
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

    // MARK: - P2: 容错解码

    func testPriorityTolerant() {
        XCTAssertEqual(Priority.tolerant("high"), .high)
        XCTAssertEqual(Priority.tolerant("High"), .high)       // 大小写不敏感
        XCTAssertEqual(Priority.tolerant(" NORMAL "), .normal) // 去空格
        XCTAssertEqual(Priority.tolerant("urgent"), .normal)   // 未知回落
        XCTAssertEqual(Priority.tolerant(nil), .normal)        // 缺失回落
    }

    func testTodoCategoryTolerant() {
        XCTAssertEqual(TodoCategory.tolerant("work"), .work)
        XCTAssertEqual(TodoCategory.tolerant("WORK"), .work)   // 大小写不敏感
        XCTAssertEqual(TodoCategory.tolerant("travel"), .other) // 未知回落
        XCTAssertEqual(TodoCategory.tolerant(nil), .other)      // 缺失回落
    }

    /// AI 返回表外的 priority/category 值时，不应让整次解码失败，而是回落默认值。
    func testExtractedTodoDecodesUnknownEnumsToDefaults() throws {
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000003", "title": "任务", "detail": "", "priority": "urgent", "categoryHint": "travel"}],
            "ignored": ""
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].priority, .normal)
        XCTAssertEqual(result.todos[0].categoryHint, .other)
    }

    /// 缺失 title 时从 detail 派生，而不是让整批 ExtractionResult 解码失败。
    func testExtractedTodoDerivesTitleFromDetailWhenMissing() throws {
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000007", "detail": "买牛奶和鸡蛋", "priority": "normal", "categoryHint": "life"}],
            "ignored": ""
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "买牛奶和鸡蛋", "缺 title 应从 detail 派生")
    }

    /// priority/categoryHint 缺失时回落默认值，不抛错。
    func testExtractedTodoDecodesMissingEnums() throws {
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000004", "title": "无枚举任务"}],
            "ignored": ""
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertEqual(result.todos[0].priority, .normal)
        XCTAssertEqual(result.todos[0].categoryHint, .other)
    }

    // MARK: - P5: 统一序列化

    func testResponseDecoderConvertsSnakeCase() throws {
        let json = """
        {"todos":[{"id":"00000000-0000-0000-0000-000000000006","title":"复盘","due_hint":"明天","priority":"normal","category_hint":"work"}],"ignored":""}
        """
        let result = try JSONCoding.makeResponseDecoder().decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(result.todos[0].dueHint, "明天")
        XCTAssertEqual(result.todos[0].categoryHint, .work)
    }

    func testRequestEncoderUsesMillisecondsEpochDateAndCamelCaseKeys() throws {
        struct Box: Codable { let createdAt: Date }
        let data = try JSONCoding.makeRequestEncoder().encode(Box(createdAt: Date(timeIntervalSince1970: 1.5)))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"createdAt\""), "请求编码应保持 camelCase key，不转 snake_case")
        XCTAssertTrue(text.contains("1500"), "日期应编码为 epoch 毫秒")
    }

    /// 异常超长标题应被截断到合理上限。
    func testExtractedTodoTruncatesLongTitle() throws {
        let longTitle = String(repeating: "字", count: 500)
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000005", "title": "\(longTitle)", "priority": "normal", "categoryHint": "work"}],
            "ignored": ""
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertLessThanOrEqual(result.todos[0].title.count, 200)
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

    func testRecurrenceRuleResolverParsesBoundedDailyDuration() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))

        let rule = RecurrenceRuleResolver.resolve(
            dueHint: "未来的 7 天",
            title: "小单元测试",
            detail: "未来的 7 天，每天都要做一个小单元测试",
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(rule?.frequency, .daily)
        XCTAssertEqual(rule?.endDate, expectedEnd)
    }

    func testExtractionResultDecodesDateStringEndDate() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000004",
                "title": "小单元测试",
                "detail": "未来的 7 天，每天都要做一个小单元测试",
                "due_hint": "未来的 7 天",
                "recurrence_rule": {
                    "frequency": "daily",
                    "weekdays": [],
                    "day_of_month": null,
                    "end_date": "2026-05-10"
                },
                "priority": "normal",
                "category_hint": "study"
            }],
            "ignored": ""
        }
        """
        let calendar = Calendar(identifier: .gregorian)
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule?.frequency, .daily)
        XCTAssertEqual(result.todos[0].recurrenceRule?.endDate, expectedEnd)
    }

    func testExtractionResultInfersEndDateWhenDailyRuleHasNullEndDate() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000005",
                "title": "小单元测试",
                "detail": "未来的 7 天，每天都要做一个小单元测试",
                "due_hint": "未来的 7 天",
                "recurrence_rule": {
                    "frequency": "daily",
                    "weekdays": [],
                    "day_of_month": null,
                    "end_date": null
                },
                "priority": "normal",
                "category_hint": "study"
            }],
            "ignored": ""
        }
        """
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.userInfo[.recurrenceReferenceDate] = reference
        decoder.userInfo[.recurrenceCalendar] = calendar

        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule?.frequency, .daily)
        XCTAssertEqual(result.todos[0].recurrenceRule?.endDate, expectedEnd)
    }

    func testExtractionResultInfersBoundedDailyWhenRecurrenceRuleIsMissing() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000006",
                "title": "小单元测试",
                "detail": "未来的 7 天，每天都要做一个小单元测试",
                "due_hint": "未来的 7 天",
                "priority": "normal",
                "category_hint": "study"
            }],
            "ignored": ""
        }
        """
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.userInfo[.recurrenceReferenceDate] = reference
        decoder.userInfo[.recurrenceCalendar] = calendar

        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule?.frequency, .daily)
        XCTAssertEqual(result.todos[0].recurrenceRule?.endDate, expectedEnd)
    }

    func testExtractionResultResolvesStructuredRecurrenceEnd() throws {
        let json = """
        {
            "todos": [{
                "id": "00000000-0000-0000-0000-000000000009",
                "title": "接小孩",
                "detail": "未来7天每天下午5点去幼儿园接小孩",
                "due_hint": "每天下午5点",
                "due_time": "17:00",
                "recurrence_rule": { "frequency": "daily", "weekdays": [], "day_of_month": null, "end_date": null },
                "recurrence_end": { "kind": "after_count", "count": 7, "unit": "day" },
                "priority": "normal",
                "category_hint": "life"
            }],
            "ignored": ""
        }
        """
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.userInfo[.recurrenceReferenceDate] = reference
        decoder.userInfo[.recurrenceCalendar] = calendar

        let result = try decoder.decode(ExtractionResult.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(result.todos[0].recurrenceRule?.frequency, .daily)
        XCTAssertEqual(result.todos[0].recurrenceRule?.endDate, expectedEnd)
        XCTAssertEqual(result.todos[0].dueTime, "17:00")
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
