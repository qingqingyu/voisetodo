import XCTest
@testable import VoiceTodo

/// `PaywallContent.calendarDaysUntil(_:now:calendar:)` 的回归测试。
///
/// 已订阅且已关续费的日期行按该函数分档:≤0「今天到期」/ 1「明天到期」/ 2...7
/// 「X 天后到期」+ 警示色,>7 维持「有效期至 X」。分档边界差一天就会翻错文案,
/// 所以这里锁定:按 `startOfDay` 的日历天(不是秒数除 86400——夏令时切换日
/// 实际只有 23/25 小时,秒数除法会差一天)、跨天/跨月/跨夏令时各形态。
final class PaywallExpiryDaysTests: XCTestCase {
    /// 固定时区的 gregorian calendar(时区无关用例共用,注入让函数可测)。
    private func makeCalendar(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 用指定 calendar 的组件构造 Date,保证用例不依赖宿主机时区。
    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else {
            preconditionFailure("invalid date components: \(components)")
        }
        return date
    }

    // MARK: - 分档边界

    func test_sameDayLaterToday_isZero() {
        let calendar = makeCalendar()
        let now = date(2026, 10, 12, 8, 0, calendar: calendar)
        let expiration = date(2026, 10, 12, 23, 30, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 0)
    }

    func test_tomorrowMidnightOneMinute_isOne_evenThoughLessThan24Hours() {
        let calendar = makeCalendar()
        // 今晚 23:59 到期 → 明天 00:01,真实间隔 2 分钟,日历天必须是 1:
        // 「明天到期」文案靠它;秒数除法在此会得 0。
        let now = date(2026, 10, 12, 23, 59, calendar: calendar)
        let expiration = date(2026, 10, 13, 0, 1, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 1)
    }

    func test_exactlySevenDays_isSeven() {
        let calendar = makeCalendar()
        let now = date(2026, 10, 12, calendar: calendar)
        let expiration = date(2026, 10, 19, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 7)
    }

    func test_eightDays_isEight() {
        let calendar = makeCalendar()
        let now = date(2026, 10, 12, calendar: calendar)
        let expiration = date(2026, 10, 20, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 8)
    }

    func test_alreadyExpired_isNegative() {
        let calendar = makeCalendar()
        let now = date(2026, 10, 12, calendar: calendar)
        let expiration = date(2026, 10, 10, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), -2)
    }

    // MARK: - 跨月

    func test_acrossMonthBoundary() {
        let calendar = makeCalendar()
        let now = date(2026, 10, 12, calendar: calendar)
        let expiration = date(2026, 11, 1, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 20)
    }

    // MARK: - 跨夏令时

    func test_springForwardDSTDay_countsCalendarDaysNot24HourBlocks() {
        // 美国 2027-03-14 02:00 春令时拨快:该日同一钟点只有 23 真实小时。
        // now 03-13 12:00 → expiration 03-14 12:00 真实间隔 23h,秒数除 86400 得 0,
        // 日历天必须是 1。
        let calendar = makeCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let now = date(2027, 3, 13, 12, 0, calendar: calendar)
        let expiration = date(2027, 3, 14, 12, 0, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 1)
    }

    func test_fallBackDSTDay_countsCalendarDaysNot24HourBlocks() {
        // 美国 2027-11-07 02:00 秋令时拨慢:该日同一钟点有 25 真实小时。
        // now 11-06 12:00 → expiration 11-07 12:00 真实间隔 25h,日历天仍是 1。
        let calendar = makeCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let now = date(2027, 11, 6, 12, 0, calendar: calendar)
        let expiration = date(2027, 11, 7, 12, 0, calendar: calendar)
        XCTAssertEqual(PaywallContent.calendarDaysUntil(expiration, now: now, calendar: calendar), 1)
    }
}
