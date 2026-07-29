import XCTest
@testable import VoiceTodo

/// `HomeCalendarState` 的分组不变量测试。
///
/// 覆盖三个 bug 的回归:
/// 1. 「未安排」不再撒谎:有 `timeBucket` 或 `dueHint` 的条目不应进 `unscheduledTodos`。
/// 2. `.rawFallback` 条目路由到 `unparsedTodos`,不混进 Today。
/// 3. 今天内部三层 tier(allDay → period → timed)顺序与 HTML 设计稿一致。
final class HomeCalendarStateGroupingTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var today: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24))
        )
    }

    // MARK: - 分组不再撒谎

    /// timeBucket=.afternoon + dueDate=nil → 进 pendingDateTodos,不进 unscheduledTodos。
    /// 回归用户报告的 bug:「下午寄快递」被错归到 Unscheduled。
    func testTimeBucketOnlyGoesToPendingDateNotUnscheduled() throws {
        let todo = makeTodo(title: "搬箱子", timeBucket: .afternoon, dueDate: nil)
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.pendingDateTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.unscheduledTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.unparsedTodos.contains { $0.id == todo.id })
    }

    /// dueHint="等会儿" + dueDate=nil → 进 pendingDateTodos(AI 返回了 hint 但没结构化日期)。
    func testDueHintOnlyGoesToPendingDateNotUnscheduled() throws {
        let todo = makeTodo(title: "拿咖啡", dueHint: "等会儿", dueDate: nil)
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.pendingDateTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.unscheduledTodos.contains { $0.id == todo.id })
    }

    /// 既无 timeBucket 也无 dueHint + dueDate=nil → 进 unscheduledTodos(「未定时间」组)。
    func testNoTimeSignalStaysInUnscheduled() throws {
        let todo = makeTodo(title: "要去重庆", dueDate: nil)
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.unscheduledTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.pendingDateTodos.contains { $0.id == todo.id })
    }

    /// extractionOutcome=.rawFallback → 进 unparsedTodos,不进其他三个组。
    func testRawFallbackOutcomeGoesToUnparsed() throws {
        let todo = makeTodo(
            title: "下午3:00开会下午4:00有用下午6:",
            dueDate: nil,
            extractionOutcome: .rawFallback
        )
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.unparsedTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.unscheduledTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.pendingDateTodos.contains { $0.id == todo.id })
    }

    /// 已完成的 rawFallback 条目进 completedUnscheduledTodos,不进 unparsedTodos。
    /// 已完成 Section 不分原 outcome,统一归档。
    /// 注:`completedAt: today` 必传——`completedUnscheduledTodos` 自 bug 修复后
    /// 按「完成日」归档,无 completedAt 的条目不进任何一天(详见下方边界测试)。
    func testCompletedRawFallbackGoesToCompletedSection() throws {
        let todo = makeTodo(
            title: "原文片段",
            dueDate: nil,
            extractionOutcome: .rawFallback,
            isCompleted: true,
            completedAt: today
        )
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.completedUnscheduledTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.unparsedTodos.contains { $0.id == todo.id })
    }

    // MARK: - 已完成无日期任务按「完成日」归档

    /// 主 bug 修复:无日期任务完成 → 只出现在「完成那天」的已完成区,
    /// 不再撒谎成「每一天都有」。回归 docs/completed-unscheduled-todo-placement.md。
    func testCompletedUnscheduledTodoOnlyShownOnCompletionDay() throws {
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let todo = makeTodo(
            title: "随手记的事",
            dueDate: nil,
            isCompleted: true,
            completedAt: today
        )

        let stateToday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )
        let stateYesterday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: yesterday, calendar: calendar
        )

        XCTAssertTrue(stateToday.completedUnscheduledTodos.contains { $0.id == todo.id },
                      "完成当天应出现在已完成区")
        XCTAssertFalse(stateYesterday.completedUnscheduledTodos.contains { $0.id == todo.id },
                       "其他日期不应出现——修复前 bug 是每一天都出现")
    }

    /// 回看历史日:文档第 110 行验收项「次日再打开 App 看昨天 → 确认条目仍在昨天的
    /// 已完成区」。若把 filter 退化成 `calendar.isDateInToday(completedAt)` 此测试会失败。
    func testCompletedUnscheduledTodoVisibleOnPastCompletionDay() throws {
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let todo = makeTodo(
            title: "昨天做完的",
            dueDate: nil,
            isCompleted: true,
            completedAt: yesterday
        )

        let stateLookingAtYesterday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: yesterday, calendar: calendar
        )
        let stateLookingAtToday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(stateLookingAtYesterday.completedUnscheduledTodos.contains { $0.id == todo.id },
                      "回看完成日当天应能看到该条目(历史不断层)")
        XCTAssertFalse(stateLookingAtToday.completedUnscheduledTodos.contains { $0.id == todo.id },
                       "完成日的次日不应再看到该条目")
    }

    /// 边界 1:历史数据 `completedAt == nil`(模型字段补全前完成的老条目)
    /// 不显示在任何一天。不兜底塞进今天,避免陈年条目涌入。
    func testCompletedUnscheduledTodoNilCompletedAtShownNowhere() throws {
        let todo = makeTodo(
            title: "上古时代完成的",
            dueDate: nil,
            isCompleted: true,
            completedAt: nil
        )

        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertFalse(state.completedUnscheduledTodos.contains { $0.id == todo.id },
                       "completedAt=nil 的历史数据不应进任何一天")
    }

    /// 边界 2:取消完成(uncheck)→ 自动离开已完成区,回到未完成分区。
    /// filter 结构上天然成立(未完成组都 !$0.isCompleted),测试兜底验证。
    func testUncheckRemovesFromCompletedSection() throws {
        let completed = makeTodo(
            title: "做完了又取消",
            dueDate: nil,
            isCompleted: true,
            completedAt: today
        )
        let unchecked = makeTodo(
            title: "做完了又取消",
            dueDate: nil,
            isCompleted: false,
            completedAt: nil
        )

        let stateCompleted = HomeCalendarState.makeForTests(
            todos: [completed], selectedDate: today, calendar: calendar
        )
        let stateUnchecked = HomeCalendarState.makeForTests(
            todos: [unchecked], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(stateCompleted.completedUnscheduledTodos.contains { $0.id == completed.id })
        XCTAssertFalse(stateUnchecked.completedUnscheduledTodos.contains { $0.id == unchecked.id },
                       "uncheck 后不应再出现在已完成区")
        XCTAssertTrue(stateUnchecked.unscheduledTodos.contains { $0.id == unchecked.id },
                      "uncheck 后回到未完成分区(此处无 timeBucket/dueHint → unscheduled)")
    }

    // MARK: - 今天内三层 tier 顺序

    /// 顺序必须与 HTML 设计稿 line 326-367 一致:整天 → 时段(chronological)→ 按时间(asc)。
    func testTierOrderAllDayFirstThenPeriodThenTimed() throws {
        let timed = makeOccurrence(
            title: "去游泳",
            dueDate: makeDate(hour: 18, minute: 0),
            hasDueTime: true
        )
        let allDay = makeOccurrence(title: "去学车", dueDate: today, hasDueTime: false)
        let afternoon = makeOccurrence(
            title: "寄快递",
            dueDate: today,
            hasDueTime: false,
            timeBucket: .afternoon
        )

        let state = HomeCalendarState.makeForTests(
            todos: [],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [timed, allDay, afternoon]
            ],
            calendar: calendar
        )

        let tiers = state.tieredUncompletedOccurrences.map(\.tier)
        XCTAssertEqual(tiers, [.allDay, .period(.afternoon), .timed])
    }

    /// 多个时段按 TimeBucket.chronologicalOrder 聚合:morning → afternoon → evening。
    func testPeriodTiersInChronologicalOrder() throws {
        let evening = makeOccurrence(
            title: "看剧", dueDate: today, hasDueTime: false, timeBucket: .evening
        )
        let morning = makeOccurrence(
            title: "晨跑", dueDate: today, hasDueTime: false, timeBucket: .morning
        )
        let afternoon = makeOccurrence(
            title: "寄快递", dueDate: today, hasDueTime: false, timeBucket: .afternoon
        )

        let state = HomeCalendarState.makeForTests(
            todos: [],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [evening, morning, afternoon]
            ],
            calendar: calendar
        )

        let tiers = state.tieredUncompletedOccurrences.map(\.tier)
        XCTAssertEqual(tiers, [.period(.morning), .period(.afternoon), .period(.evening)])
    }

    /// 同一 tier 内,timed 按 dueDate 升序。
    func testTimedTierSortedByDueDateAscending() throws {
        let early = makeOccurrence(
            title: "早饭", dueDate: makeDate(hour: 7, minute: 30), hasDueTime: true
        )
        let late = makeOccurrence(
            title: "晚饭", dueDate: makeDate(hour: 19, minute: 0), hasDueTime: true
        )
        let noon = makeOccurrence(
            title: "午饭", dueDate: makeDate(hour: 12, minute: 0), hasDueTime: true
        )

        let state = HomeCalendarState.makeForTests(
            todos: [],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [late, early, noon]
            ],
            calendar: calendar
        )

        let timed = state.tieredUncompletedOccurrences.first { $0.tier == .timed }
        XCTAssertEqual(timed?.items.map(\.todo.title), ["早饭", "午饭", "晚饭"])
    }

    /// allDay tier 完全不出现(没有 hasDueTime==false && timeBucket==nil 的 occurrence 时)。
    func testAllDayTierOmittedWhenEmpty() throws {
        let timed = makeOccurrence(
            title: "去游泳", dueDate: makeDate(hour: 18, minute: 0), hasDueTime: true
        )
        let state = HomeCalendarState.makeForTests(
            todos: [],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [timed]
            ],
            calendar: calendar
        )

        let tiers = state.tieredUncompletedOccurrences.map(\.tier)
        XCTAssertEqual(tiers, [.timed])
    }

    // MARK: - Helpers

    private func makeDate(hour: Int, minute: Int) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: today
        )!
    }

    private func makeTodo(
        title: String,
        timeBucket: TimeBucket? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        extractionOutcome: ExtractionOutcome = .parsed,
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) -> TodoItemData {
        TodoItemData(
            title: title,
            dueHint: dueHint,
            dueDate: dueDate,
            hasDueTime: hasDueTime,
            timeBucket: timeBucket,
            isCompleted: isCompleted,
            completedAt: completedAt,
            extractionOutcome: extractionOutcome
        )
    }

    private func makeOccurrence(
        title: String,
        dueDate: Date?,
        hasDueTime: Bool,
        timeBucket: TimeBucket? = nil
    ) -> TodoOccurrenceData {
        TodoOccurrenceData(
            todo: makeTodo(
                title: title,
                timeBucket: timeBucket,
                dueDate: dueDate,
                hasDueTime: hasDueTime
            ),
            occurrenceDate: dueDate ?? today!,
            isCompleted: false
        )
    }
}
