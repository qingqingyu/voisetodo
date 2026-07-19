import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `DayClock` 单元测试。覆盖 hour=0 零回归、hour=3 边界、跨月跨年、DST、非法值兜底。
final class DayClockTests: XCTestCase {
    /// 每个测试都用独立 calendar 时区，避免相互污染。
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    override func tearDown() {
        // 清掉写入的 startHour，避免污染其他测试。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    // MARK: - hour=0 零回归

    func testStartHourZero_matchesCalendarStartOfDay() {
        DayClock.setStartHour(0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        // 100 个随机时刻，hour=0 时 DayClock 行为必须等于 Calendar.startOfDay。
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let moment = Date(timeIntervalSince1970: Double.random(in: 0...(2_000_000_000), using: &rng))
            XCTAssertEqual(
                DayClock.startOfUserDay(for: moment, calendar: calendar),
                calendar.startOfDay(for: moment),
                "hour=0 must match Calendar.startOfDay for \(moment)"
            )
        }
    }

    func testDefaultStartHour_isZero() {
        // 不调 setStartHour，未配置时必须读回 0。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        XCTAssertEqual(DayClock.startHour, 0)
    }

    // MARK: - hour=3 边界

    func testStartHourThree_beforeStart_returnsPreviousDay() throws {
        // 凌晨 1:30 < 03:00 → 仍属于前一用户日，返回 2026-03-14 03:00
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 3, day: 15, hour: 1, minute: 30)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testStartHourThree_afterStart_returnsSameDay() throws {
        // 04:00 >= 03:00 → 属于当日，返回 2026-03-15 03:00
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 3, day: 15, hour: 4)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testStartHourThree_atExactBoundary_returnsSameDay() throws {
        // 整点 03:00 = candidateStart <= moment → 属于当日
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 3, day: 15, hour: 3, minute: 0)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    // MARK: - 跨月跨年

    func testCrossMonthBoundary() throws {
        // 2026-04-01 01:00, hour=3 → 2026-03-31 03:00
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 4, day: 1, hour: 1)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 3)))
        XCTAssertEqual(result, expected)
    }

    func testCrossYearBoundary() throws {
        // 2026-01-01 02:00, hour=5 → 2025-12-31 05:00
        DayClock.setStartHour(5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 1, day: 1, hour: 2)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)

        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 5)))
        XCTAssertEqual(result, expected)
    }

    // MARK: - DST

    func testDSTSpringForward_doesNotCrash() throws {
        // 北美春季 DST：2026-03-08 02:00→03:00（洛杉矶）。03:00 之前的小时不存在。
        // hour=3 在 2026-03-08 应解析到当日的 03:00（即 candidateStart）。
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles

        // moment 在 DST 切换前的不存在时刻附近，用 bySettingHour 应兜底返回系统决定值。
        let components = DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)
        let moment = try XCTUnwrap(calendar.date(from: components))

        // 不抛异常即视为通过；结果必须 <= moment 或属于前一用户日。
        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)
        XCTAssertLessThanOrEqual(result, moment, "startOfUserDay must not be after moment")
    }

    func testDSTFallBack_doesNotCrash() throws {
        // 北美秋季 DST：2026-11-01 02:00 重复两次。hour=3 应正常解析。
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles

        let components = DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30)
        let moment = try XCTUnwrap(calendar.date(from: components))

        let result = DayClock.startOfUserDay(for: moment, calendar: calendar)
        XCTAssertLessThanOrEqual(result, moment)
    }

    // MARK: - 非法值兜底

    func testInvalidStartHour_returnsZero() {
        DayClock.appGroupDefaults.set(99, forKey: DayClock.startHourKey)
        XCTAssertEqual(DayClock.startHour, 0)
    }

    func testNegativeStartHour_returnsZero() {
        DayClock.appGroupDefaults.set(-1, forKey: DayClock.startHourKey)
        XCTAssertEqual(DayClock.startHour, 0)
    }

    // MARK: - setStartHour clamp

    func testSetStartHour_clampsHigh() {
        DayClock.setStartHour(25)
        XCTAssertEqual(DayClock.startHour, 23)
    }

    func testSetStartHour_clampsLow() {
        DayClock.setStartHour(-1)
        XCTAssertEqual(DayClock.startHour, 0)
    }

    // MARK: - userDayInterval

    func testUserDayInterval_returnsCorrectRange() throws {
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let components = DateComponents(year: 2026, month: 3, day: 15, hour: 4)
        let moment = try XCTUnwrap(calendar.date(from: components))
        let interval = DayClock.userDayInterval(for: moment, calendar: calendar)

        let expectedStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 3)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 3)))
        XCTAssertEqual(interval.start, expectedStart)
        XCTAssertEqual(interval.end, expectedEnd)
    }

    // MARK: - isSameUserDay

    func testIsSameUserDay_acrossNaturalMidnight() throws {
        // hour=3 时，2026-03-15 01:00 和 2026-03-14 23:00 都属于同一用户日（2026-03-14 03:00 起）
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let a = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1)))
        let b = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 23)))
        XCTAssertTrue(DayClock.isSameUserDay(a, b, calendar: calendar))
    }

    func testIsSameUserDay_acrossUserDayBoundary() throws {
        // hour=3 时，2026-03-15 02:00 和 2026-03-15 04:00 跨用户日边界，不属于同一用户日
        DayClock.setStartHour(3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let a = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 2)))
        let b = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 4)))
        XCTAssertFalse(DayClock.isSameUserDay(a, b, calendar: calendar))
    }
}
