import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `TodoSpan` 单元测试 —— 跨天事件日期计算的纯函数验证。
///
/// 覆盖 docs/multi-day-span-events.md Step 1 列出的 9 个场景:
/// 单天 / 两日 / 三日 / 通宵跨日 / 退化 / 截断 / 跨月跨年 / normalized 不变式 / shiftedEnd 平移。
final class TodoSpanTests: XCTestCase {

    /// 测试用日历(UTC,避免本地时区抖动)。
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 解析 "yyyy-MM-dd HH:mm" 为 UTC Date。
    private func date(_ s: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: s)!
    }

    /// 解析 "yyyy-MM-dd" 为 UTC 00:00 Date。
    private func day(_ s: String) -> Date { date("\(s) 00:00") }

    // MARK: - coveredDays

    func testCoveredDays_singleDay_returnsSingleElement() {
        let result = TodoSpan.coveredDays(dueDate: day("2026-08-08"), eventEndDate: nil, calendar: calendar)
        XCTAssertEqual(result, [day("2026-08-08")])
    }

    func testCoveredDays_twoDays_returnsBoth() {
        let result = TodoSpan.coveredDays(
            dueDate: day("2026-08-08"),
            eventEndDate: day("2026-08-09"),
            calendar: calendar
        )
        XCTAssertEqual(result, [day("2026-08-08"), day("2026-08-09")])
    }

    func testCoveredDays_threeDays_returnsAll() {
        let result = TodoSpan.coveredDays(
            dueDate: day("2026-08-08"),
            eventEndDate: day("2026-08-10"),
            calendar: calendar
        )
        XCTAssertEqual(result, [day("2026-08-08"), day("2026-08-09"), day("2026-08-10")])
    }

    func testCoveredDays_overnight22to02_coversTwoDays() {
        // 周四 22:00 出发 → 周五 02:00 结束(通宵)。按 startOfDay 口径,覆盖周四 + 周五。
        let result = TodoSpan.coveredDays(
            dueDate: date("2026-08-13 22:00"),
            eventEndDate: date("2026-08-14 02:00"),
            calendar: calendar
        )
        XCTAssertEqual(result, [day("2026-08-13"), day("2026-08-14")])
    }

    func testCoveredDays_endBeforeStart_degeneratesToSingleDay() {
        // 终点早于起点 → 视为单天(返回起点一天)
        let result = TodoSpan.coveredDays(
            dueDate: day("2026-08-10"),
            eventEndDate: day("2026-08-08"),
            calendar: calendar
        )
        XCTAssertEqual(result, [day("2026-08-10")])
    }

    func testCoveredDays_overMaxSpan_truncatesTo366() {
        // 跨度 400 天,截断到 366 天
        let result = TodoSpan.coveredDays(
            dueDate: day("2025-01-01"),
            eventEndDate: day("2026-02-05"),
            calendar: calendar
        )
        XCTAssertEqual(result.count, TodoSpan.maxSpanDays)
        XCTAssertEqual(result.first, day("2025-01-01"))
        // 第 366 天 = 2025-01-01 + 365 天 = 2026-01-01
        XCTAssertEqual(result.last, day("2026-01-01"))
    }

    func testCoveredDays_crossMonthYear_returnsAllDays() {
        // 跨年:2025-12-30 → 2026-01-02,共 4 天
        let result = TodoSpan.coveredDays(
            dueDate: day("2025-12-30"),
            eventEndDate: day("2026-01-02"),
            calendar: calendar
        )
        XCTAssertEqual(result, [
            day("2025-12-30"), day("2025-12-31"), day("2026-01-01"), day("2026-01-02")
        ])
    }

    // MARK: - covers

    func testCovers_singleDay_onlyMatchesSameDay() {
        let due = day("2026-08-08")
        XCTAssertTrue(TodoSpan.covers(day: due, dueDate: due, eventEndDate: nil, calendar: calendar))
        XCTAssertFalse(TodoSpan.covers(day: day("2026-08-09"), dueDate: due, eventEndDate: nil, calendar: calendar))
    }

    func testCovers_multiDay_matchesAllDaysInRange() {
        let due = day("2026-08-08")
        let end = day("2026-08-10")
        XCTAssertTrue(TodoSpan.covers(day: due, dueDate: due, eventEndDate: end, calendar: calendar))
        XCTAssertTrue(TodoSpan.covers(day: day("2026-08-09"), dueDate: due, eventEndDate: end, calendar: calendar))
        XCTAssertTrue(TodoSpan.covers(day: end, dueDate: due, eventEndDate: end, calendar: calendar))
        XCTAssertFalse(TodoSpan.covers(day: day("2026-08-07"), dueDate: due, eventEndDate: end, calendar: calendar))
        XCTAssertFalse(TodoSpan.covers(day: day("2026-08-11"), dueDate: due, eventEndDate: end, calendar: calendar))
    }

    // MARK: - normalized

    func testNormalized_nilDueDate_returnsNil() {
        // 不变式 1:无起点 → nil
        XCTAssertNil(TodoSpan.normalized(
            eventEndDate: day("2026-08-10"),
            dueDate: nil,
            hasRecurrence: false,
            calendar: calendar
        ))
    }

    func testNormalized_hasRecurrence_returnsNil() {
        // 不变式 2:带重复 → nil(v1 互斥)
        XCTAssertNil(TodoSpan.normalized(
            eventEndDate: day("2026-08-10"),
            dueDate: day("2026-08-08"),
            hasRecurrence: true,
            calendar: calendar
        ))
    }

    func testNormalized_endNotAfterStart_returnsNil() {
        // 不变式 3:终点 ≤ 起点 → nil(退化为单天)
        XCTAssertNil(TodoSpan.normalized(
            eventEndDate: day("2026-08-08"),
            dueDate: day("2026-08-08"),
            hasRecurrence: false,
            calendar: calendar
        ))
        XCTAssertNil(TodoSpan.normalized(
            eventEndDate: day("2026-08-07"),
            dueDate: day("2026-08-08"),
            hasRecurrence: false,
            calendar: calendar
        ))
    }

    func testNormalized_spanOverMax_truncatesToCap() {
        // 不变式 4:跨度超 366 天 → 截断到 startDay + 365
        let result = TodoSpan.normalized(
            eventEndDate: day("2026-02-05"),
            dueDate: day("2025-01-01"),
            hasRecurrence: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-01-01"))
    }

    func testNormalized_validSpan_preservesOriginalEnd() {
        // 合规跨天 → 保留原始 eventEndDate(含钟点分量)
        let result = TodoSpan.normalized(
            eventEndDate: date("2026-08-10 18:00"),
            dueDate: date("2026-08-08 09:00"),
            hasRecurrence: false,
            calendar: calendar
        )
        XCTAssertEqual(result, date("2026-08-10 18:00"))
    }

    // MARK: - shiftedEnd

    func testShiftedEnd_nilOriginalEnd_returnsNil() {
        XCTAssertNil(TodoSpan.shiftedEnd(
            originalDue: day("2026-08-08"),
            originalEnd: nil,
            newDue: day("2026-08-10"),
            calendar: calendar
        ))
    }

    func testShiftedEnd_preservesSpan() {
        // 原 8/8 → 8/10(跨度 2 天),平移到新起点 8/15 → 8/17
        let result = TodoSpan.shiftedEnd(
            originalDue: day("2026-08-08"),
            originalEnd: day("2026-08-10"),
            newDue: day("2026-08-15"),
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-08-17"))
    }

    func testShiftedEnd_zeroSpan_returnsNil() {
        // 原数据异常:originalEnd == originalDue(跨度 0)→ 返回 nil 让调用方清掉跨天
        XCTAssertNil(TodoSpan.shiftedEnd(
            originalDue: day("2026-08-08"),
            originalEnd: day("2026-08-08"),
            newDue: day("2026-08-15"),
            calendar: calendar
        ))
    }
}
