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

    func testTodoDueTimeResolverCombinesClockTimeWithDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 9)))

        // 有日期 + 合法钟点 → 带时分、hasTime = true
        let combined = TodoDueTimeResolver.combine(date: day, dueTime: "15:30", referenceDate: reference, calendar: calendar)
        XCTAssertTrue(combined.hasTime)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(combined.date))
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)

        // 无日期 + 合法钟点 → 落到今天该时刻、hasTime = true
        let noDate = TodoDueTimeResolver.combine(date: nil, dueTime: "08:00", referenceDate: reference, calendar: calendar)
        XCTAssertTrue(noDate.hasTime)
        let noDateComps = calendar.dateComponents([.day, .hour, .minute], from: try XCTUnwrap(noDate.date))
        XCTAssertEqual(noDateComps.day, 4)
        XCTAssertEqual(noDateComps.hour, 8)

        // 无时间 / 非法 / 越界 → 原样返回日期、hasTime = false
        XCTAssertFalse(TodoDueTimeResolver.combine(date: day, dueTime: nil, calendar: calendar).hasTime)
        XCTAssertFalse(TodoDueTimeResolver.combine(date: day, dueTime: "下午三点", calendar: calendar).hasTime)
        XCTAssertFalse(TodoDueTimeResolver.combine(date: day, dueTime: "25:70", calendar: calendar).hasTime)
        XCTAssertNil(TodoDueTimeResolver.combine(date: nil, dueTime: nil, calendar: calendar).date)
    }

    func testTodoReorderPlannerKeepsScheduledSlotsAndPermutesUnscheduled() throws {
        let scheduledA = TodoItemData(title: "S-A", dueDate: Date())
        let unschedX = TodoItemData(title: "U-X")
        let scheduledB = TodoItemData(title: "S-B", recurrenceRule: RecurrenceRule(frequency: .daily))
        let unschedY = TodoItemData(title: "U-Y")
        let unschedZ = TodoItemData(title: "U-Z")

        // 全局未完成序：A(排期) X(无) B(规律) Y(无) Z(无)
        let uncompleted = [scheduledA, unschedX, scheduledB, unschedY, unschedZ]

        // 无日期新序：Z, X, Y
        let result = TodoReorderPlanner.reorderedUncompletedIDs(
            uncompleted: uncompleted,
            newUnscheduledOrder: [unschedZ.id, unschedX.id, unschedY.id]
        )

        // 已排期/规律项槽位不动（第 0、2 位仍是 A、B），无日期槽位（1、3、4）按新序填回。
        XCTAssertEqual(result, [scheduledA.id, unschedZ.id, scheduledB.id, unschedX.id, unschedY.id])
        XCTAssertEqual(result.count, uncompleted.count)
        XCTAssertEqual(Set(result), Set(uncompleted.map(\.id)))
    }

    func testNotificationPlannerOneShotFiltersSortsAndCaps() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let inHour = now.addingTimeInterval(3600)
        let inTwoHours = now.addingTimeInterval(7200)
        let past = now.addingTimeInterval(-3600)

        let timedSoon = TodoItemData(title: "会议", detail: "3楼", dueDate: inTwoHours, hasDueTime: true)
        let timedSooner = TodoItemData(title: "电话", dueDate: inHour, hasDueTime: true)
        let allDay = TodoItemData(title: "买菜", dueDate: inHour, hasDueTime: false)          // 无钟点
        let completed = TodoItemData(title: "已完成", dueDate: inHour, hasDueTime: true, isCompleted: true)
        let pastTimed = TodoItemData(title: "过期", dueDate: past, hasDueTime: true)           // 已过期

        let result = NotificationPlanner.plannedNotifications(
            from: [timedSoon, allDay, completed, pastTimed, timedSooner],
            now: now
        )

        // 只保留带钟点/未完成/未过期，按触发时间升序；一次性 repeats=false
        XCTAssertEqual(result.map(\.todoID), [timedSooner.id, timedSoon.id])
        XCTAssertEqual(result.first?.title, "电话")
        XCTAssertFalse(result.first?.repeats ?? true)
        XCTAssertNil(result.first?.body)              // 无 detail → body nil
        XCTAssertEqual(result.last?.body, "3楼")       // 有 detail → 带上

        // limit 截断
        let many = (0..<10).map { i in
            TodoItemData(title: "T\(i)", dueDate: now.addingTimeInterval(Double(i + 1) * 60), hasDueTime: true)
        }
        XCTAssertEqual(NotificationPlanner.plannedNotifications(from: many, now: now, limit: 3).count, 3)

        // 总开关关闭 → 空集合；打开 → 恢复
        XCTAssertTrue(NotificationPlanner.plannedNotifications(from: [timedSoon, timedSooner], now: now, enabled: false).isEmpty)
        XCTAssertEqual(NotificationPlanner.plannedNotifications(from: [timedSoon, timedSooner], now: now, enabled: true).count, 2)
    }

    func testNotificationPlannerRecurring() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 构造一个带 20:xx 时刻的 dueDate（重复触发只取时分）
        let due = calendar.date(bySettingHour: 20, minute: 15, second: 0, of: now)!

        func todo(_ rule: RecurrenceRule, hasTime: Bool = true) -> TodoItemData {
            TodoItemData(title: "R", dueDate: due, hasDueTime: hasTime, recurrenceRule: rule)
        }

        // daily 无界 → 1 条重复，仅 {hour,minute}
        let daily = NotificationPlanner.plannedNotifications(from: [todo(RecurrenceRule(frequency: .daily))], now: now)
        XCTAssertEqual(daily.count, 1)
        XCTAssertTrue(daily[0].repeats)
        XCTAssertEqual(daily[0].dateComponents.hour, 20)
        XCTAssertEqual(daily[0].dateComponents.minute, 15)
        XCTAssertNil(daily[0].dateComponents.day)
        XCTAssertNil(daily[0].dateComponents.weekday)
        XCTAssertNil(daily[0].dateComponents.year)

        // weekly [2,4,6] → 每 weekday 一条
        let weekly = NotificationPlanner.plannedNotifications(from: [todo(RecurrenceRule(frequency: .weekly, weekdays: [2, 4, 6]))], now: now)
        XCTAssertEqual(weekly.count, 3)
        XCTAssertTrue(weekly.allSatisfy { $0.repeats })
        XCTAssertEqual(Set(weekly.compactMap { $0.dateComponents.weekday }), [2, 4, 6])

        // monthly day=1 → 1 条含 {day:1}
        let monthly = NotificationPlanner.plannedNotifications(from: [todo(RecurrenceRule(frequency: .monthly, dayOfMonth: 1))], now: now)
        XCTAssertEqual(monthly.count, 1)
        XCTAssertTrue(monthly[0].repeats)
        XCTAssertEqual(monthly[0].dateComponents.day, 1)

        // 有界 daily（endDate=+2天）→ 展开为一次性（repeats=false），不超上限
        let end = calendar.date(byAdding: .day, value: 2, to: now)!
        let bounded = NotificationPlanner.plannedNotifications(
            from: [todo(RecurrenceRule(frequency: .daily, endDate: end))], now: now
        )
        XCTAssertFalse(bounded.isEmpty)
        XCTAssertTrue(bounded.allSatisfy { !$0.repeats })
        XCTAssertTrue(bounded.allSatisfy { $0.dateComponents.year != nil }) // 一次性含完整日期
        XCTAssertLessThanOrEqual(bounded.count, NotificationPlanner.boundedExpansionCap)

        // 规律但无具体时间 → 不产出
        XCTAssertTrue(NotificationPlanner.plannedNotifications(from: [todo(RecurrenceRule(frequency: .daily), hasTime: false)], now: now).isEmpty)

        // 已结束（endDate 在过去）→ 不产出
        let pastEnd = calendar.date(byAdding: .day, value: -5, to: now)!
        XCTAssertTrue(NotificationPlanner.plannedNotifications(
            from: [todo(RecurrenceRule(frequency: .daily, endDate: pastEnd))], now: now
        ).isEmpty)
    }

    func testRecurrenceEndResolverComputesExactDates() throws {
        let cal = Calendar(identifier: .gregorian)
        func d(_ y: Int, _ m: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: day)))
        }
        let monday = try d(2026, 7, 6) // 周一

        // after_count：天 / 周 / 月
        XCTAssertEqual(RecurrenceEndResolver.resolve(.afterCount(count: 7, unit: .day), start: monday, today: monday, calendar: cal), try d(2026, 7, 12))
        XCTAssertEqual(RecurrenceEndResolver.resolve(.afterCount(count: 2, unit: .week), start: monday, today: monday, calendar: cal), try d(2026, 7, 19))
        XCTAssertEqual(RecurrenceEndResolver.resolve(.afterCount(count: 1, unit: .month), start: monday, today: monday, calendar: cal), try d(2026, 8, 6))

        // weekday：本周五(6) / 下周五
        XCTAssertEqual(RecurrenceEndResolver.resolve(.weekday(weekday: 6, scope: .this), start: monday, today: monday, calendar: cal), try d(2026, 7, 10))
        XCTAssertEqual(RecurrenceEndResolver.resolve(.weekday(weekday: 6, scope: .next), start: monday, today: monday, calendar: cal), try d(2026, 7, 17))

        // month_end：本月 / 下月
        XCTAssertEqual(RecurrenceEndResolver.resolve(.monthEnd(scope: .this), start: monday, today: monday, calendar: cal), try d(2026, 7, 31))
        XCTAssertEqual(RecurrenceEndResolver.resolve(.monthEnd(scope: .next), start: monday, today: monday, calendar: cal), try d(2026, 8, 31))

        // day_of_month：下月15号
        XCTAssertEqual(RecurrenceEndResolver.resolve(.dayOfMonth(day: 15, scope: .next), start: monday, today: monday, calendar: cal), try d(2026, 8, 15))

        // 绝对日期
        XCTAssertEqual(RecurrenceEndResolver.resolve(.date("2026-07-20"), start: monday, today: monday, calendar: cal), try d(2026, 7, 20))

        // nil / 截止早于起始 → nil
        XCTAssertNil(RecurrenceEndResolver.resolve(nil, start: monday, today: monday, calendar: cal))
        XCTAssertNil(RecurrenceEndResolver.resolve(.date("2026-07-01"), start: monday, today: monday, calendar: cal))
    }

    func testRecurrenceEndResolverClampsAndRollsOver() throws {
        let cal = Calendar(identifier: .gregorian)
        func d(_ y: Int, _ m: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: day)))
        }
        // day_of_month 31 落在 2026-02（28 天）→ clamp 到 02-28
        let feb = try d(2026, 2, 10)
        XCTAssertEqual(RecurrenceEndResolver.resolve(.dayOfMonth(day: 31, scope: .this), start: feb, today: feb, calendar: cal), try d(2026, 2, 28))
        // 周六求"本周五"（已过）→ 顺延到下周五
        let sat = try d(2026, 7, 11) // 周六
        XCTAssertEqual(RecurrenceEndResolver.resolve(.weekday(weekday: 6, scope: .this), start: sat, today: sat, calendar: cal), try d(2026, 7, 17))
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

    // MARK: - TodoTimeDisplayComposer

    func testTimeDisplayComposerReturnsNilWhenAllInputsNil() {
        XCTAssertNil(TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: nil, timeText: nil, dueHint: nil))
    }

    func testTimeDisplayComposerReturnsNilWhenAllInputsEmptyOrWhitespace() {
        XCTAssertNil(TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: nil, timeText: "   ", dueHint: ""))
    }

    func testTimeDisplayComposerFallsBackToDueHintWhenStructuredFieldsAbsent() {
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: nil, timeText: nil, dueHint: "明天下午3点"),
            "明天下午3点"
        )
    }

    func testTimeDisplayComposerUsesRelativeDateOverDueHint() {
        // Bug 2 核心修复：有 dueDate 时用相对日期，不再透传 LLM 的 dueHint 原文
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: "明天", timeText: nil, dueHint: "next Wednesday"),
            "明天"
        )
    }

    func testTimeDisplayComposerJoinsRelativeDateAndTime() {
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: "明天", timeText: "15:00", dueHint: nil),
            "明天 · 15:00"
        )
    }

    func testTimeDisplayComposerSkipsRelativeDateWhenRecurrencePresent() {
        // recurrenceRule 自带日期范围，relativeDateText 不重复展示
        let rule = RecurrenceRule(frequency: .daily)
        let result = TodoTimeDisplayComposer.compose(recurrenceRule: rule, relativeDateText: "明天", timeText: "15:00", dueHint: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.contains("明天") ?? true, "should not duplicate relative date when recurrence present")
    }

    func testTimeDisplayComposerUsesOnlyTimeTextWhenNoRecurrence() {
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: nil, timeText: "15:00", dueHint: "下午三点"),
            "15:00"
        )
    }

    func testTimeDisplayComposerJoinsRecurrenceAndTimeText() throws {
        let rule = RecurrenceRule(frequency: .daily)
        let result = try XCTUnwrap(
            TodoTimeDisplayComposer.compose(recurrenceRule: rule, relativeDateText: nil, timeText: "15:00", dueHint: nil)
        )
        XCTAssertTrue(result.hasPrefix(rule.displayTextWithEndDate), "result should start with recurrence text: \(result)")
        XCTAssertTrue(result.contains("15:00"), "result should contain time text: \(result)")
        XCTAssertTrue(result.contains(" · "), "result should join with ' · ': \(result)")
    }

    func testTimeDisplayComposerDropsDueHintWhenStructuredFieldsPresent() throws {
        let rule = RecurrenceRule(frequency: .daily)
        let result = try XCTUnwrap(
            TodoTimeDisplayComposer.compose(recurrenceRule: rule, relativeDateText: nil, timeText: "15:00", dueHint: "每天下午三点")
        )
        XCTAssertFalse(result.contains("每天下午三点"), "should drop redundant dueHint: \(result)")
    }

    func testTimeDisplayComposerTrimsWhitespaceOnInputs() throws {
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(recurrenceRule: nil, relativeDateText: nil, timeText: "  15:00  ", dueHint: "  \n  "),
            "15:00"
        )
    }

    func testTimeDisplayComposerUsesTimeBucketWhenClockTimeIsAbsent() {
        XCTAssertEqual(
            TodoTimeDisplayComposer.compose(
                recurrenceRule: nil,
                relativeDateText: nil,
                timeText: nil,
                dueHint: "今天晚上去健身",
                timeBucketText: "晚上"
            ),
            "晚上"
        )
    }

    // MARK: - TodoDetailUpdate

    func testTodoDetailUpdateNormalizesClockTimeWithoutDueDate() {
        let update = TodoDetailUpdate(
            title: "无日期但带钟点标记",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: nil,
            hasDueTime: true,
            timeBucket: .evening,
            dueHint: nil,
            recurrenceRule: nil
        )

        XCTAssertFalse(update.hasDueTime)
        XCTAssertEqual(update.timeBucket, .evening)
    }

    // MARK: - TimeBucketResolver

    func testTimeBucketResolverPrefersClockTimeOverConflictingExplicitBucket() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let dueDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 15)))

        XCTAssertEqual(
            TimeBucketResolver.effective(explicitBucket: .morning, dueDate: dueDate, hasDueTime: true, calendar: calendar),
            .afternoon
        )
    }

    func testTimeBucketResolverDerivesClockTimeAndFallsBackToAnytime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 5)))
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 12)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 23)))

        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: morning, hasDueTime: true, calendar: calendar), .morning)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: afternoon, hasDueTime: true, calendar: calendar), .afternoon)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: evening, hasDueTime: true, calendar: calendar), .evening)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: nil, hasDueTime: false, calendar: calendar), .anytime)
    }

    // MARK: - TodoRelativeDateFormatter

    func testRelativeDateFormatterToday() {
        let result = TodoRelativeDateFormatter.format(Date())
        XCTAssertNotNil(result)
        XCTAssertFalse(result.isEmpty)
    }

    func testRelativeDateFormatterTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let result = TodoRelativeDateFormatter.format(tomorrow)
        XCTAssertNotNil(result)
        XCTAssertFalse(result.isEmpty)
    }

    func testRelativeDateFormatterConsistency() {
        // 同一个日期多次格式化结果应一致（确定性）
        let date = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let r1 = TodoRelativeDateFormatter.format(date)
        let r2 = TodoRelativeDateFormatter.format(date)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - RelativeDueLabel

    func testRelativeDueLabelClassifiesOverdueTodayTomorrowAndFuture() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))

        XCTAssertEqual(RelativeDueLabel.status(dueDate: yesterday, isCompleted: false, recurrenceRule: nil, now: today, calendar: calendar), .overdue)
        XCTAssertEqual(RelativeDueLabel.status(dueDate: today, isCompleted: false, recurrenceRule: nil, now: today, calendar: calendar), .today)
        XCTAssertEqual(RelativeDueLabel.status(dueDate: tomorrow, isCompleted: false, recurrenceRule: nil, now: today, calendar: calendar), .tomorrow)
        XCTAssertEqual(RelativeDueLabel.status(dueDate: future, isCompleted: false, recurrenceRule: nil, now: today, calendar: calendar), .future(future))
    }

    func testRelativeDueLabelHidesCompletedAndRecurringTasks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))

        XCTAssertNil(RelativeDueLabel.status(dueDate: yesterday, isCompleted: true, recurrenceRule: nil, now: today, calendar: calendar))
        XCTAssertNil(RelativeDueLabel.status(dueDate: yesterday, isCompleted: false, recurrenceRule: RecurrenceRule(frequency: .daily), now: today, calendar: calendar))
    }

    func testRelativeDueLabelMarksTimedTaskOverdueOncePastClockTimeSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 12, minute: 0)))
        let sameDayEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 23, minute: 21)))
        let sameDayMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 9, minute: 0)))

        // 今天 12:00 的定时任务，23:21 看 → 过期（带钟点、时刻已过）。
        XCTAssertEqual(RelativeDueLabel.status(dueDate: noon, isCompleted: false, recurrenceRule: nil, hasDueTime: true, now: sameDayEvening, calendar: calendar), .overdue)
        // 今天 12:00 的定时任务，09:00 看 → 今天（还没到点）。
        XCTAssertEqual(RelativeDueLabel.status(dueDate: noon, isCompleted: false, recurrenceRule: nil, hasDueTime: true, now: sameDayMorning, calendar: calendar), .today)
        // 无钟点（模糊时段/时段⇒今天）今天任务，23:21 看 → 今天，不误判过期。
        XCTAssertEqual(RelativeDueLabel.status(dueDate: noon, isCompleted: false, recurrenceRule: nil, hasDueTime: false, now: sameDayEvening, calendar: calendar), .today)
    }

    // MARK: - TodoScheduleDefaults（时段⇒今天）

    func testTodoScheduleDefaultsBucketWithoutDateFallsToToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 23, minute: 21)))
        let startOfToday = calendar.startOfDay(for: now)

        // 有模糊时段、无日期、无钟点 → 补今天。
        XCTAssertEqual(TodoScheduleDefaults.effectiveDueDate(resolvedDate: nil, hasDueTime: false, timeBucket: .morning, now: now, calendar: calendar), startOfToday)
        // 无时段、无日期 → 仍 nil（保持 Unscheduled）。
        XCTAssertNil(TodoScheduleDefaults.effectiveDueDate(resolvedDate: nil, hasDueTime: false, timeBucket: nil, now: now, calendar: calendar))
        // anytime 不算显式时段 → nil。
        XCTAssertNil(TodoScheduleDefaults.effectiveDueDate(resolvedDate: nil, hasDueTime: false, timeBucket: .anytime, now: now, calendar: calendar))
        // 已有日期 → 原样返回，不覆盖。
        let explicit = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20)))
        XCTAssertEqual(TodoScheduleDefaults.effectiveDueDate(resolvedDate: explicit, hasDueTime: false, timeBucket: .morning, now: now, calendar: calendar), explicit)
    }

    func testTimeBucketResolverBoundariesLockNoonToAfternoon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func at(_ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: hour, minute: minute)))
        }
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(4, 59), hasDueTime: true, calendar: calendar), .evening)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(5, 0), hasDueTime: true, calendar: calendar), .morning)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(11, 59), hasDueTime: true, calendar: calendar), .morning)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(12, 0), hasDueTime: true, calendar: calendar), .afternoon)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(17, 59), hasDueTime: true, calendar: calendar), .afternoon)
        XCTAssertEqual(TimeBucketResolver.effective(explicitBucket: nil, dueDate: try at(18, 0), hasDueTime: true, calendar: calendar), .evening)
    }

    // MARK: - TodoDueDateResolver (N days offset)

    func testDueDateResolverParsesNDaysFromNow() throws {
        let reference = Date()
        let calendar = Calendar.current
        let result = try XCTUnwrap(TodoDueDateResolver.resolve(
            dueHint: "3 days from now", referenceDate: reference, calendar: calendar
        ))
        XCTAssertEqual(calendar.startOfDay(for: result), calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: reference)!))
    }

    func testDueDateResolverParsesSpelledOutDays() throws {
        let reference = Date()
        let calendar = Calendar.current
        let result = try XCTUnwrap(TodoDueDateResolver.resolve(
            dueHint: "three days from now", referenceDate: reference, calendar: calendar
        ))
        XCTAssertEqual(calendar.startOfDay(for: result), calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: reference)!))
    }

    func testDueDateResolverParsesInNDays() throws {
        let reference = Date()
        let calendar = Calendar.current
        let result = try XCTUnwrap(TodoDueDateResolver.resolve(
            dueHint: "in 5 days", referenceDate: reference, calendar: calendar
        ))
        XCTAssertEqual(calendar.startOfDay(for: result), calendar.startOfDay(for: calendar.date(byAdding: .day, value: 5, to: reference)!))
    }

    func testDueDateResolverParsesChineseDaysOffset() throws {
        let reference = Date()
        let calendar = Calendar.current
        let result = try XCTUnwrap(TodoDueDateResolver.resolve(
            dueHint: "三天后", referenceDate: reference, calendar: calendar
        ))
        XCTAssertEqual(calendar.startOfDay(for: result), calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: reference)!))
    }

    func testDueDateResolverParsesChineseDigitDaysOffset() throws {
        let reference = Date()
        let calendar = Calendar.current
        let result = try XCTUnwrap(TodoDueDateResolver.resolve(
            dueHint: "5天之后", referenceDate: reference, calendar: calendar
        ))
        XCTAssertEqual(calendar.startOfDay(for: result), calendar.startOfDay(for: calendar.date(byAdding: .day, value: 5, to: reference)!))
    }
}
