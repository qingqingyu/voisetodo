import XCTest
@testable import VoiceTodo

/// `HomeCalendarState` 的分组不变量测试。
///
/// 覆盖四个 bug 的回归:
/// 1. 「未安排」不再撒谎:有 `timeBucket` 或 `dueHint` 的条目不应进 `unscheduledTodos`。
/// 2. `.rawFallback` 条目路由到 `unparsedTodos`,不混进 Today。
/// 3. 今天内部三层 tier(allDay → period → timed)顺序与 HTML 设计稿一致。
/// 4. 完成反馈「原地保留」:deferred 集合内的已完成条目留在原分区,不进「已完成」。
final class HomeCalendarStateGroupingTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var today: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 保险：清掉共享 startHour，避免上一条用例残留污染本类的 hour=0 前提。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24))
        )
    }

    override func tearDownWithError() throws {
        // 与 setUp 对称：清掉本类可能 set 过的 startHour，避免影响后续测试类。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        try super.tearDownWithError()
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

    // MARK: - 复盘批量出口的落点回归(2026-09-01 拍板 3,docs/todo-review-flow-v2.md)

    /// 批量出口写出的**精确字段组合**:dueDate=nil + timeBucket=nil + dueHint=""
    /// (空串,不是 nil——updateFull 的三态语义里空串才是清除)→ 必须落
    /// 「稍后」(unscheduledTodos)。空串路径与 nil 不同,单独锁住。
    func testBatchExitClearedFieldsLandInUnscheduled() throws {
        let todo = makeTodo(title: "批量推后的老任务", dueHint: "", dueDate: nil)
        let state = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )

        XCTAssertTrue(state.unscheduledTodos.contains { $0.id == todo.id })
        XCTAssertFalse(state.pendingDateTodos.contains { $0.id == todo.id },
                       "只清日期不清时段信号会落「待定日期」——批量出口最大的坑")
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

    // MARK: - 已完成无日期任务在 startHour>0 下与回顾页同源

    /// 缺陷 3 回归：startHour=3 时，凌晨 1:30 完成的无日期任务属于前一用户日。
    /// 修复前 `calendar.isDate(completedAt, inSameDayAs: selectedDate)` 把它归到完成当天的
    /// 自然日（3/16），与 ReviewAggregator 的用户日归档（3/15）分裂。
    /// 修复后用 `isSameUserDay(completedAt, userDayStart(onNaturalDay: selectedDate))`，
    /// 首页应把这条任务归到「3/15 已完成」分区，与回顾页一致。
    ///
    /// 时区用 Asia/Shanghai 显式注入，避免本类默认 calendar（无时区设置）在
    /// bySettingHour 上产生歧义。
    func testCompletedUnscheduledTodoAt1AMHour3_belongsToPreviousUserDay() throws {
        DayClock.setStartHour(3)
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let completedAt = try XCTUnwrap(shanghaiCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 16, hour: 1, minute: 30)
        ))
        let todo = TodoItemData(
            title: "凌晨做完的无日期任务",
            dueDate: nil,
            isCompleted: true,
            completedAt: completedAt
        )

        // selectedDate = 3/15 自然日 0 点（用户日 3/15 的自然日锚）。
        let selectedDay = try XCTUnwrap(shanghaiCalendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let statePrev = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: selectedDay, calendar: shanghaiCalendar
        )
        // selectedDate = 3/16 自然日 0 点（用户日 3/16 的自然日锚）。
        let selectedDayNext = try XCTUnwrap(shanghaiCalendar.date(from: DateComponents(year: 2026, month: 3, day: 16)))
        let stateNext = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: selectedDayNext, calendar: shanghaiCalendar
        )

        XCTAssertTrue(
            statePrev.completedUnscheduledTodos.contains { $0.id == todo.id },
            "凌晨 1:30 完成的任务应归到前一用户日 3/15（与回顾页同源）"
        )
        XCTAssertFalse(
            stateNext.completedUnscheduledTodos.contains { $0.id == todo.id },
            "凌晨 1:30 完成的任务不应归到完成当天的自然日 3/16（修复前的 bug）"
        )

        // 闸门：与 ReviewAggregator 的归属必须一致。
        let aggregatorExpected = DayClock.startOfUserDay(for: completedAt, calendar: shanghaiCalendar)
        let homeAssigned = statePrev.selectedDate // 已归一化的自然日 0 点
        XCTAssertTrue(
            DayClock.isSameUserDay(aggregatorExpected, DayClock.userDayStart(onNaturalDay: homeAssigned, calendar: shanghaiCalendar), calendar: shanghaiCalendar),
            "首页归到的日子必须与 ReviewAggregator 同源"
        )
    }

    /// 零回归闸门：startHour=0 时本类原有 13 条用例的口径不变。
    /// 凌晨 1:30 完成的任务在 hour=0 下仍归到完成当天的自然日（与修复前一致）。
    func testCompletedUnscheduledTodoAt1AMHour0_belongsToSameNaturalDay() throws {
        // hour=0 是默认（setUp 已清），不显式 setStartHour。
        let completedAt = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 24, hour: 1, minute: 30)
        ))
        let todo = TodoItemData(
            title: "凌晨做完的无日期任务",
            dueDate: nil,
            isCompleted: true,
            completedAt: completedAt
        )

        let stateToday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: today, calendar: calendar
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let stateYesterday = HomeCalendarState.makeForTests(
            todos: [todo], selectedDate: yesterday, calendar: calendar
        )

        XCTAssertTrue(
            stateToday.completedUnscheduledTodos.contains { $0.id == todo.id },
            "hour=0 时凌晨 1:30 完成应归到当自然日（零回归）"
        )
        XCTAssertFalse(
            stateYesterday.completedUnscheduledTodos.contains { $0.id == todo.id },
            "hour=0 时不应归到昨天"
        )
    }

    // MARK: - 完成反馈原地保留(deferredCompletionIDs)

    /// 「原地保留」修订:deferred 集合内的已完成条目留在原分区(当日 tier /
    /// 稍后 / 待定日期),「已完成」分区到点前不含它(防同一行双处渲染)。
    /// 回归 bug:完成当拍行即被移进底部已完成区,0.22s 后爆花在空槽上"凭空"炸开,
    /// 勾号 trim 描画也从未在原位播过。同一份数据 + 空 deferred 集合 = 旧归档行为。
    func testDeferredCompletionStaysInPlaceAndOutOfCompletedSection() throws {
        let timed = TodoOccurrenceData(
            todo: makeTodo(
                title: "带钟点的",
                dueDate: makeDate(hour: 9, minute: 0),
                hasDueTime: true,
                isCompleted: true,
                completedAt: today
            ),
            occurrenceDate: today,
            isCompleted: true
        )
        let later = makeTodo(title: "稍后任务", dueDate: nil)
        let completedUnscheduled = makeTodo(
            title: "完成的稍后任务", dueDate: nil, isCompleted: true, completedAt: today
        )
        let completedPendingDate = makeTodo(
            title: "完成的待定日期", timeBucket: .afternoon, dueDate: nil,
            isCompleted: true, completedAt: today
        )
        let deferred: Set<UUID> = [timed.todo.id, completedUnscheduled.id, completedPendingDate.id]

        let state = HomeCalendarState.makeForTests(
            todos: [later, completedUnscheduled, completedPendingDate],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [timed]
            ],
            calendar: calendar,
            deferredCompletionIDs: deferred
        )

        // 当日 tier:deferred 已完成 occurrence 留在原 tier。
        let timedTier = state.tieredUncompletedOccurrences.first { $0.tier == .timed }
        XCTAssertEqual(timedTier?.items.map(\.todo.id), [timed.todo.id])
        // 稍后 / 待定日期:deferred 已完成条目各留原分区。
        XCTAssertTrue(state.unscheduledTodos.contains { $0.id == completedUnscheduled.id })
        XCTAssertTrue(state.pendingDateTodos.contains { $0.id == completedPendingDate.id })
        // 「已完成」分区到点前不含 deferred 条目。
        XCTAssertTrue(state.completedOccurrences.isEmpty)
        XCTAssertTrue(state.completedUnscheduledTodos.isEmpty)

        // 空 deferred 集合(到点移出后)= 旧归档行为,零回归。
        let archived = HomeCalendarState.makeForTests(
            todos: [later, completedUnscheduled, completedPendingDate],
            selectedDate: today,
            occurrencesByDay: [
                TodoOccurrenceData.dayKey(for: today, calendar: calendar): [timed]
            ],
            calendar: calendar
        )
        XCTAssertEqual(archived.completedOccurrences.map(\.todo.id), [timed.todo.id])
        XCTAssertEqual(
            Set(archived.completedUnscheduledTodos.map(\.id)),
            [completedUnscheduled.id, completedPendingDate.id]
        )
        XCTAssertTrue(archived.unscheduledTodos.contains { $0.id == later.id })
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
