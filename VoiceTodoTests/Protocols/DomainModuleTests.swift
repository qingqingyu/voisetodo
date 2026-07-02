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
}
