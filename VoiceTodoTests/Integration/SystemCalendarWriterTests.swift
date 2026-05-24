import XCTest
@testable import VoiceTodo

final class SystemCalendarWriterTests: XCTestCase {
    func testDraftUsesAllDayEventForDateOnlyTodo() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        let todo = TodoItemData(
            title: "完成英语背诵",
            detail: "今天完成英语背诵",
            dueHint: "今天",
            dueDate: start,
            createdAt: start
        )

        let draft = try XCTUnwrap(SystemCalendarEventMapper.draft(from: todo, calendar: calendar))

        XCTAssertTrue(draft.isAllDay)
        XCTAssertTrue(calendar.isDate(draft.startDate, inSameDayAs: start))
        XCTAssertEqual(calendar.dateComponents([.day], from: draft.startDate, to: draft.endDate).day, 1)
        XCTAssertEqual(draft.title, "完成英语背诵")
    }

    func testDraftKeepsBoundedDailyRecurrenceForSystemCalendarWrite() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 28)))
        let todo = TodoItemData(
            title: "听写100个单词",
            detail: "未来 7 天每天听写 100 个单词",
            dueHint: "未来 7 天",
            dueDate: start,
            recurrenceRule: RecurrenceRule(frequency: .daily, endDate: end),
            createdAt: start
        )

        let draft = try XCTUnwrap(SystemCalendarEventMapper.draft(from: todo, calendar: calendar))

        XCTAssertEqual(draft.recurrenceRule?.frequency, .daily)
        XCTAssertTrue(calendar.isDate(try XCTUnwrap(draft.recurrenceRule?.endDate), inSameDayAs: end))
    }

    func testDraftSkipsUndatedNonRecurringTodo() {
        let calendar = Calendar(identifier: .gregorian)
        let todo = TodoItemData(
            title: "买牛奶",
            detail: "路过超市时买",
            dueDate: nil,
            recurrenceRule: nil
        )

        XCTAssertNil(SystemCalendarEventMapper.draft(from: todo, calendar: calendar))
    }

    func testDraftUsesCreatedAtForUndatedRecurringTodo() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        let todo = TodoItemData(
            title: "听写100个单词",
            detail: "每天听写 100 个单词",
            dueDate: nil,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: start
        )

        let draft = try XCTUnwrap(SystemCalendarEventMapper.draft(from: todo, calendar: calendar))

        XCTAssertTrue(calendar.isDate(draft.startDate, inSameDayAs: start))
        XCTAssertEqual(draft.recurrenceRule?.frequency, .daily)
    }
}
