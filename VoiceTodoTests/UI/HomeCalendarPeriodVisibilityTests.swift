import XCTest
@testable import VoiceTodo

/// `HomeCalendarState.isViewingCurrentPeriod` 的回归测试。
///
/// 主 bug：折叠态（周条）下左右滑翻到本月内的其它周，「回到今天」箭头永不出现。
/// 根因是谓词只按 `.month` 粒度比较 `visibleMonthAnchor` 与今天，而 `shiftWeek`
/// 同月内翻周时故意不动 `visibleMonthAnchor`——两者相乘导致「还在当前时段」恒真。
///
/// 修复后谓词粒度随形态切换：折叠成周条比周（走 `startOfWeek`，周一起始硬编码），
/// 展开成月网格比月。本测试锁定六条不变量，每条对应方案文档里的一条设计约束。
final class HomeCalendarPeriodVisibilityTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 保险：清掉共享 startHour，避免上一条用例残留污染本类的 hour=0 前提。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        // zh_CN / en_US 默认 firstWeekday=1（周日）——故意保留默认，
        // 用来证伪「实现会偷懒走 .weekOfYear」的怀疑（用例 4/5）。
    }

    override func tearDownWithError() throws {
        // 与 setUp 对称：清掉本类可能 set 过的 startHour，避免影响后续测试类。
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        try super.tearDownWithError()
    }

    // MARK: - 主 bug 回归

    /// 用例 1：周条里翻到本月内的另一周 → false（按钮该出现）。
    /// 修复前此例恒为 true，箭头永不出现——是最关键的一条回归闸门。
    func testWeekStripSameMonthDifferentWeek_returnsFalse() throws {
        // 2026-07-24 是周五，所在周（周一起始）是 7/20–7/26。
        let today = try makeDay(year: 2026, month: 7, day: 24)
        // 翻到上一周 7/13（周一），同月不同周。
        let selectedPreviousWeek = try makeDay(year: 2026, month: 7, day: 13)

        let result = HomeCalendarState.isViewingCurrentPeriod(
            selectedDate: selectedPreviousWeek,
            visibleMonthAnchor: today, // 同月内翻周时 anchor 不动
            isWeekStrip: true,
            today: today,
            calendar: calendar
        )

        XCTAssertFalse(result, "周条翻到本月其它周应判定为「离开当前时段」，渲染回到今天箭头")
    }

    /// 用例 2：周条里同周不同天 → true。
    /// 周条里点选本周的其它天不应冒出「回到今天」——今天还在眼前。
    func testWeekStripSameWeekDifferentDay_returnsTrue() throws {
        let today = try makeDay(year: 2026, month: 7, day: 24) // 周五
        let sameWeekMonday = try makeDay(year: 2026, month: 7, day: 20) // 本周周一

        let result = HomeCalendarState.isViewingCurrentPeriod(
            selectedDate: sameWeekMonday,
            visibleMonthAnchor: today,
            isWeekStrip: true,
            today: today,
            calendar: calendar
        )

        XCTAssertTrue(result, "周条里同周不同天不该冒出箭头")
    }

    /// 用例 3：月网格 + 本月内点选另一周的天 → true。
    /// 约束 2：展开态不看 selectedDate，月网格里点本月某天不算「离开当前时段」。
    func testMonthGridSameMonthDifferentWeek_returnsTrue() throws {
        let today = try makeDay(year: 2026, month: 7, day: 24)
        let sameMonthOtherWeek = try makeDay(year: 2026, month: 7, day: 5)

        let result = HomeCalendarState.isViewingCurrentPeriod(
            selectedDate: sameMonthOtherWeek,
            visibleMonthAnchor: today,
            isWeekStrip: false,
            today: today,
            calendar: calendar
        )

        XCTAssertTrue(result, "月网格里点选本月另一天不应触发箭头（约束 2）")
    }

    /// 用例 4：周日起始 locale + today=周日、selectedDate=同一条周条的周一 → true。
    /// 约束 3：实现若改用 `.weekOfYear`，此例会红——`.weekOfYear` 在 firstWeekday=1
    /// 下把周日判到下周。
    func testWeekStripSundayLocaleSundayAndMondaySameWeek_returnsTrue() throws {
        var sundayFirstCalendar = Calendar(identifier: .gregorian)
        sundayFirstCalendar.firstWeekday = 1 // 周日起始（zh_CN / en_US 默认）

        // 2026-07-26 是周日，2026-07-20 是同一条周条（周一起始）的周一。
        let sunday = try makeDay(year: 2026, month: 7, day: 26)
        let sameStripMonday = try makeDay(year: 2026, month: 7, day: 20)

        let result = HomeCalendarState.isViewingCurrentPeriod(
            selectedDate: sameStripMonday,
            visibleMonthAnchor: sunday,
            isWeekStrip: true,
            today: sunday,
            calendar: sundayFirstCalendar
        )

        XCTAssertTrue(result, "同一条周条（周一起始）的周一与周日应判为同周——禁用 .weekOfYear")
    }

    /// 用例 5：跨年周（12 月底与 1 月初同属一条周一起始的周）→ true。
    /// 约束 3 的另一个 `.weekOfYear` 坑：跨年周边界。
    func testWeekStripCrossYearBoundaryWeek_returnsTrue() throws {
        // 2026-12-28（周一）与 2026-12-31（周四）在同一条周条，
        // 但 2027-01-01（周五）属于下一条周条——这里测「跨年但同周」。
        // 取 2024-12-30（周一）与 2024-12-31（周二）、2025-01-01（周三）、2025-01-05（周日）：
        // 周一起始的这条周条是 2024-12-30 ~ 2025-01-05。
        let dec30 = try makeDay(year: 2024, month: 12, day: 30) // 周一
        let jan1 = try makeDay(year: 2025, month: 1, day: 1) // 周三，同一周条

        let result = HomeCalendarState.isViewingCurrentPeriod(
            selectedDate: dec30,
            visibleMonthAnchor: dec30, // anchor 不重要，周条态用不到
            isWeekStrip: true,
            today: jan1,
            calendar: calendar
        )

        XCTAssertTrue(result, "跨年周（12-30 与 1-1 同周条）应判同周——跨年边界的 .weekOfYear 坑")
    }

    /// 用例 6：startHour=3 时周一凌晨 → 语义今天是周日，属上一条周条。
    /// 约束 4：谓词必须用「语义今天」，否则箭头永远挂着且点不掉。
    func testWeekStripStartHour3EarlyMorningUsesSemanticToday() throws {
        DayClock.setStartHour(3)
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 周一 01:30：startHour=3 下语义今天是周日（昨天）。
        let mondayEarly = try XCTUnwrap(shanghaiCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27, hour: 1, minute: 30)
        ))
        // 语义今天 = 周日 0 点（自然日 7/26 的 0 点）。
        let semanticToday = DayClock.startOfUserDay(for: mondayEarly, calendar: shanghaiCalendar)
        // 周一自然日 0 点（不是语义今天）。
        let mondayMidnight = try XCTUnwrap(shanghaiCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 27)
        ))

        // selectedDate = 语义今天（周日）→ 同周（语义今天所在周）→ true。
        XCTAssertTrue(
            HomeCalendarState.isViewingCurrentPeriod(
                selectedDate: shanghaiCalendar.startOfDay(for: semanticToday),
                visibleMonthAnchor: shanghaiCalendar.startOfDay(for: semanticToday),
                isWeekStrip: true,
                today: shanghaiCalendar.startOfDay(for: semanticToday),
                calendar: shanghaiCalendar
            ),
            "selectedDate=语义今天（周日）应判为同周"
        )

        // selectedDate = 自然日周一（selectedDate 已跳到下一条周条）→ 不同周 → false。
        // 修复前若用裸 Date() 比，语义今天错算成自然日周一，谓词会判同周，
        // 点箭头跳过去之后箭头仍挂着——这条断言锁住这个 bug。
        XCTAssertFalse(
            HomeCalendarState.isViewingCurrentPeriod(
                selectedDate: mondayMidnight,
                visibleMonthAnchor: mondayMidnight,
                isWeekStrip: true,
                today: shanghaiCalendar.startOfDay(for: semanticToday),
                calendar: shanghaiCalendar
            ),
            "selectedDate=自然日周一（已离开语义今天所在周）应判为不同周"
        )
    }

    // MARK: - Helpers

    private func makeDay(year: Int, month: Int, day: Int) throws -> Date {
        try XCTUnwrap(
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        )
    }
}
