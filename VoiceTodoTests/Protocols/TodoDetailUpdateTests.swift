import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `TodoDetailUpdate.eventEndDate` 归一化测试。
///
/// 验证 init 调 `TodoSpan.normalized` 应用的 4 条不变式:
/// 1. dueDate == nil → eventEndDate 必 nil
/// 2. hasRecurrence → eventEndDate 必 nil(v1 互斥)
/// 3. endDay <= startDay → nil(退化为单天)
/// 4. 跨度超 maxSpanDays → 截断到 startDay + maxSpanDays - 1
///
/// 详见 docs/multi-day-span-events.md「字段命名与语义」+「不变式」节。
final class TodoDetailUpdateTests: XCTestCase {

    /// 测试用日历(UTC,避免本地时区抖动)。
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 解析 "yyyy-MM-dd" 为 UTC 00:00 Date。
    /// - Throws: 解析失败时由 `XCTUnwrap` 抛出,给出可读断言(格式串写错时不会裸 crash)。
    private func day(_ s: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return try XCTUnwrap(
            formatter.date(from: s),
            "测试日期解析失败: \"\(s)\" 不匹配 yyyy-MM-dd"
        )
    }

    // MARK: - 不变式 1:dueDate == nil → eventEndDate = nil

    func testEventEndDate_nilDueDate_normalizesToNil() throws {
        // 无起点时,即使传了 eventEndDate 也会被清空(单点事件无法跨天)
        let update = TodoDetailUpdate(
            title: "无起点但传了终点",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: nil,
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: try day("2026-08-10")
        )
        XCTAssertNil(update.eventEndDate)
    }

    // MARK: - 不变式 2:hasRecurrence → eventEndDate = nil(v1 互斥)

    func testEventEndDate_withRecurrence_normalizesToNil() throws {
        // 跨天 + 重复 v1 互斥:同时设两个时,eventEndDate 让步给 recurrenceRule
        let update = TodoDetailUpdate(
            title: "跨天 + 重复互斥",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: try day("2026-08-08"),
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            eventEndDate: try day("2026-08-10")
        )
        XCTAssertNil(update.eventEndDate)
        // recurrenceRule 保留(让步的是 eventEndDate,不是反过来)
        XCTAssertNotNil(update.recurrenceRule)
    }

    // MARK: - 不变式 3:endDay <= startDay → nil(退化)

    func testEventEndDate_endEqualsStart_normalizesToNil() throws {
        // 起终点同一天 → 单天事件,eventEndDate 应 nil
        let update = TodoDetailUpdate(
            title: "起点终点同一天",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: try day("2026-08-08"),
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: try day("2026-08-08")
        )
        XCTAssertNil(update.eventEndDate)
    }

    func testEventEndDate_endBeforeStart_normalizesToNil() throws {
        // 终点早于起点 → 数据异常,清空 eventEndDate
        let update = TodoDetailUpdate(
            title: "终点早于起点",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: try day("2026-08-10"),
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: try day("2026-08-08")
        )
        XCTAssertNil(update.eventEndDate)
    }

    // MARK: - 不变式 4:跨度超 maxSpanDays → 截断

    func testEventEndDate_spanOverMax_truncatesToCap() throws {
        // 跨度 400 天(>366),截断到 startOfDay(dueDate) + maxSpanDays - 1 天。
        // 注:被测 TodoDetailUpdate.init 内部用 Calendar.current(与 RecurrenceRule.occurs(on:) 同口径,
        // 见 Protocols/Models.swift:497 注释)。期望值必须按 .current 时区算,
        // 否则跨时区机器上 startOfDay 的日界翻转会让断言失败。
        let current = Calendar.current
        let dueDate = try day("2025-01-01")
        let expectedEnd = try XCTUnwrap(
            current.date(
                byAdding: .day,
                value: TodoSpan.maxSpanDays - 1,
                to: current.startOfDay(for: dueDate)
            ),
            "测试 setup:.current 时区下计算截断期望日期失败"
        )

        let update = TodoDetailUpdate(
            title: "跨年休假",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: dueDate,
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: try day("2026-02-05")
        )
        XCTAssertEqual(update.eventEndDate, expectedEnd)
    }

    // MARK: - 合规情况:保留原始 eventEndDate(含钟点)

    func testEventEndDate_validSpan_preservesOriginal() throws {
        // 合规跨天 → 保留原始 eventEndDate(含钟点分量,后续显示用)
        // 注:被测 TodoDetailUpdate.init 内部用 Calendar.current,本测试日历锁 UTC。
        // 选 8/8 → 8/10 这种同日历日不会跨时区翻转的日期,使结果与 .current 无关。
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let end = try XCTUnwrap(
            formatter.date(from: "2026-08-10 18:00"),
            "测试 setup:解析 \"2026-08-10 18:00\" 失败"
        )

        let update = TodoDetailUpdate(
            title: "周末出游",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: try day("2026-08-08"),
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: end
        )
        XCTAssertEqual(update.eventEndDate, end)
    }

    func testEventEndDate_twoDaySpan_preservesOriginal() throws {
        // 最小合规跨天:2 天(起点 + 次日)
        let update = TodoDetailUpdate(
            title: "出差 2 天",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: try day("2026-08-08"),
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil,
            eventEndDate: try day("2026-08-09")
        )
        XCTAssertEqual(update.eventEndDate, try day("2026-08-09"))
    }

    /// `reminderOffsetMinutes` 三态契约的 struct 侧守卫:
    /// init 不做归一化(应用/钳制在 TodoStore.updateFull),只验证默认 nil 与原样透传。
    /// 行为级测试(保留/清除/钳制/无钟点清除)见 StoreTests.testUpdateFullReminderOffsetTriState。
    func testReminderOffsetMinutesDefaultsNilAndPassesThrough() throws {
        let omitted = TodoDetailUpdate(
            title: "开会", detail: nil, category: nil, priority: nil,
            dueDate: try day("2026-08-08"), hasDueTime: true,
            timeBucket: nil, dueHint: nil, recurrenceRule: nil
        )
        XCTAssertNil(omitted.reminderOffsetMinutes, "不传 = nil(保留原值语义的默认档)")

        let explicit = TodoDetailUpdate(
            title: "开会", detail: nil, category: nil, priority: nil,
            dueDate: try day("2026-08-08"), hasDueTime: true,
            timeBucket: nil, dueHint: nil, recurrenceRule: nil,
            reminderOffsetMinutes: 0
        )
        XCTAssertEqual(explicit.reminderOffsetMinutes, 0, "0 = 清除档,init 原样透传")
    }
}
