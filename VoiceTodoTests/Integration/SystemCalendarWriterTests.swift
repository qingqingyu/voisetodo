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

    func testDraftUsesAllDayEventForDateWithFuzzyTimeBucket() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        let todo = TodoItemData(
            title: "去健身",
            dueDate: start,
            timeBucket: .evening,
            createdAt: start
        )

        let draft = try XCTUnwrap(SystemCalendarEventMapper.draft(from: todo, calendar: calendar))

        XCTAssertTrue(draft.isAllDay)
        XCTAssertTrue(calendar.isDate(draft.startDate, inSameDayAs: start))
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

    // MARK: - mirrorContentChanged（updateTodoDetail 的镜像重建门控）

    /// 只改不进镜像事件的字段（优先级/分类/提醒提前量/跨天结束日/完成态）→ 不重建。
    func testMirrorContentChangedReturnsFalseForNonEventFieldEdits() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        var old = TodoItemData(title: "买牛奶", dueDate: start, createdAt: start)
        old.systemCalendarEventIdentifier = "event-old"
        var new = old
        new.priority = .high
        new.category = .work
        new.reminderOffsetMinutes = 30
        new.eventEndDate = calendar.date(byAdding: .day, value: 1, to: start)
        new.isCompleted = true

        XCTAssertFalse(SystemCalendarEventMapper.mirrorContentChanged(from: old, to: new))
    }

    /// 改进镜像事件的字段（标题/钟点/日期删除）→ 重建。
    func testMirrorContentChangedReturnsTrueForEventFieldEdits() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        var old = TodoItemData(title: "买牛奶", dueDate: start, createdAt: start)
        old.systemCalendarEventIdentifier = "event-old"

        var retitled = old
        retitled.title = "买脱脂牛奶"
        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: old, to: retitled), "标题进事件，应重建")

        var timed = old
        timed.dueDate = calendar.date(byAdding: .hour, value: 9, to: start)
        timed.hasDueTime = true
        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: old, to: timed), "全天→定时，应重建")

        var undated = old
        undated.dueDate = nil
        undated.hasDueTime = false
        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: old, to: undated), "删掉日期草稿归 nil，应重建（走清残留路径）")
    }

    /// 两侧都无草稿（改前改后都无日期无重复）→ 不重建。
    func testMirrorContentChangedReturnsFalseWhenBothSidesHaveNoDraft() {
        let old = TodoItemData(title: "稍后再做")
        var new = old
        new.priority = .high

        XCTAssertFalse(SystemCalendarEventMapper.mirrorContentChanged(from: old, to: new))
    }

    /// 任一侧状态缺失 → 按有变化处理（宁可多重建不漏更新）。
    func testMirrorContentChangedTreatsMissingStateAsChanged() {
        let todo = TodoItemData(title: "买牛奶", dueDate: Date())

        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: nil, to: todo))
        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: todo, to: nil))
        XCTAssertTrue(SystemCalendarEventMapper.mirrorContentChanged(from: nil, to: nil))
    }
}
