import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `TodoDueDateShifter.nextDay` 单元测试。
///
/// 核心断言:**"明天"语义相对 baseDate,不相对真实当前时刻 `Date()`**。
/// 这是 2026-07-25 修复的根因——之前 moveTodoToTomorrow 内联用 `Date()` 导致
/// calendar tab 选非今天时"移到明天"违背用户心智(选中 24 号时移到明天会变成
/// 移到真实今天+1)。
///
/// 覆盖 5 个场景(对应 review 时列举的 bug 表)+ 钟点保留 + DST + 月边界 + 自定义 dayStartHour。
final class TodoDueDateShifterTests: XCTestCase {

    /// 测试用日历(UTC,避免本地时区抖动)。每个测试可重设 timeZone。
    private var calendar: Calendar = {
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

    override func tearDown() {
        // 清掉 DayClock 的 startHour,避免跨测试污染。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    // MARK: - 场景 1:基准 —— selectedDate == 真实今天

    func testScenario1_baseDateEqualsToday_noDueTime_returnsNextDay() {
        DayClock.setStartHour(0)
        // 真实今天 = baseDate = 23 号(用户选了今天)
        // 期望:明天 = 24 号
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-23"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-07-24"))
    }

    // MARK: - 场景 2:bug 修复核心 —— selectedDate ≠ 真实今天(未来日)

    func testScenario2_baseDateIsFutureDay_noDueTime_returnsBaseDatePlusOne() {
        DayClock.setStartHour(0)
        // 真实今天 = 23 号,但用户选了 24 号(baseDate)
        // 旧 bug:nextDay 用 Date() → 返回 24 号(相对真实今天+1,等于 selectedDate 本身)
        // 修复后:nextDay 用 baseDate → 返回 25 号(相对选中日+1)
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-24"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-07-25"))
    }

    // MARK: - 场景 3:selectedDate ≠ 真实今天(过去日)

    func testScenario3_baseDateIsPastDay_noDueTime_returnsBaseDatePlusOne() {
        DayClock.setStartHour(0)
        // 真实今天 = 23 号,用户选了 22 号(baseDate)
        // 旧 bug:nextDay 用 Date() → 返回 24 号(相对真实今天+1,等于"多移一天")
        // 修复后:nextDay 用 baseDate → 返回 23 号(相对选中日+1)
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-22"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-07-23"))
    }

    // MARK: - 场景 4:selectedDate 是月末(跨月边界)

    func testScenario4_baseDateIsMonthEnd_crossesMonthBoundary() {
        DayClock.setStartHour(0)
        // 7/31 → 8/1,验证跨月不破。
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-31"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-08-01"))
    }

    // MARK: - 场景 5:selectedDate 是年末(跨年边界)

    func testScenario5_baseDateIsYearEnd_crossesYearBoundary() {
        DayClock.setStartHour(0)
        // 12/31 → 1/1,验证跨年不破。
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-12-31"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2027-01-01"))
    }

    // MARK: - 钟点保留行为

    func testHasDueTime_preservesHourAndMinute() {
        DayClock.setStartHour(0)
        // 任务原 dueDate = 24 号 14:30,baseDate = 24 号
        // 期望:明天 25 号 14:30(钟点保留)
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-24"),
            originalDue: date("2026-07-24 14:30"),
            hasDueTime: true,
            calendar: calendar
        )
        XCTAssertEqual(result, date("2026-07-25 14:30"))
    }

    func testNoDueTime_zeroesTimeRegardlessOfOriginalDue() {
        DayClock.setStartHour(0)
        // hasDueTime=false:不管 originalDue 有没有钟点,结果都是明天 00:00。
        // (startOfUserDay 已经把 baseDate 钟点清零,+1 天后仍是 00:00)
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-24"),
            originalDue: date("2026-07-24 14:30"),  // 即使原 dueDate 有钟点
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, day("2026-07-25"))  // 25 号 00:00
    }

    func testHasDueTimeButOriginalDueNil_fallsBackToMidnight() {
        DayClock.setStartHour(0)
        // 边界:hasDueTime=true 但 originalDue=nil(理论不该发生,但函数不应 crash)
        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2026-07-24"),
            originalDue: nil,
            hasDueTime: true,
            calendar: calendar
        )
        // guard hasDueTime, let originalDue else → 走 false 分支,返回 tomorrow 00:00
        XCTAssertEqual(result, day("2026-07-25"))
    }

    // MARK: - 自定义 dayStartHour 行为

    func testCustomDayStartHour_baseDateBeforeHour_belongsToPreviousUserDay() {
        // startHour=3:凌晨 0:00-2:59 算"昨天"。
        // baseDate = 24 号 01:00(自然 24 号,但用户日算 23 号)
        // 明天 = 24 号 03:00(用户日 23 号 + 1 天)
        DayClock.setStartHour(3)
        let result = TodoDueDateShifter.nextDay(
            baseDate: date("2026-07-24 01:00"),
            originalDue: nil,
            hasDueTime: false,
            calendar: calendar
        )
        XCTAssertEqual(result, date("2026-07-24 03:00"))
    }

    // MARK: - DST 边界(美东时区,春令时跳变)

    func testDSTSpringForward_fallsBackToMidnight() {
        // 美东时区 2024-03-10 凌晨 2:00 跳到 3:00(2:30 不存在)。
        // 任务原 dueDate = 03-09 14:30,baseDate = 03-09,期望"明天 03-10 14:30"——正常存在。
        // 改成 2:30 触发 DST fallback:任务原 dueDate = 03-09 02:30,
        // 期望"明天 03-10"——bySettingHour 在 03-10 找不到 02:30 → fallback 到 03-10 00:00。
        var eastern = calendar
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        DayClock.setStartHour(0)

        let result = TodoDueDateShifter.nextDay(
            baseDate: day("2024-03-09"),
            originalDue: date("2024-03-09 02:30"),  // 此刻在美东存在(03-10 不存在)
            hasDueTime: true,
            calendar: eastern
        )
        // 用 eastern 日历检查结果:期望是 03-10 00:00 美东时间
        let expected = eastern.date(bySettingHour: 0, minute: 0, second: 0, of: day("2024-03-10"))!
        XCTAssertEqual(result, expected)
    }
}
