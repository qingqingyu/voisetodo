import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// TaskEventType / TaskEventOrigin 的 tolerant 构造 + 推迟判定纯函数
/// `TaskEventRules.isDeferral`(阶段 1 数据地基,docs/todo-review-flow-design.md §1.3)。
final class TaskEventKindTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    override func tearDown() {
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        makeCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - tolerant 构造

    func testTaskEventTypeTolerant() {
        XCTAssertEqual(TaskEventType.tolerant("deferred"), .deferred)
        XCTAssertEqual(TaskEventType.tolerant("  ABANDONED\n"), .abandoned)
        XCTAssertEqual(TaskEventType.tolerant("Split"), .split)
        XCTAssertNil(TaskEventType.tolerant(nil))
        XCTAssertNil(TaskEventType.tolerant("created"), "created 不在事件集(拍板 3)")
        XCTAssertNil(TaskEventType.tolerant("bogus"))
    }

    func testTaskEventOriginTolerant() {
        XCTAssertEqual(TaskEventOrigin.tolerant("app"), .app)
        XCTAssertEqual(TaskEventOrigin.tolerant("  REVIEW "), .review)
        XCTAssertEqual(TaskEventOrigin.tolerant("Detail"), .detail)
        XCTAssertNil(TaskEventOrigin.tolerant(nil))
        XCTAssertNil(TaskEventOrigin.tolerant("widget"), "widget 已从 origin 集合删除(拍板 5)")
    }

    // MARK: - isDeferral 纯函数

    func testIsDeferral_sameUserDayDifferentClock_notDeferred() {
        // 同日改钟点(10:00 → 22:00)不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 20, 10),
            newDueDate: date(2026, 8, 20, 22),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
    }

    func testIsDeferral_crossUserDay_deferred() {
        // 跨用户日(20 日 → 21 日)记
        XCTAssertTrue(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 20, 22),
            newDueDate: date(2026, 8, 21, 9),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
    }

    func testIsDeferral_movedEarlier_notDeferred() {
        // 往前改不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 21, 9),
            newDueDate: date(2026, 8, 20, 22),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
    }

    func testIsDeferral_nilOldDueDate_notDeferred() {
        // 旧 dueDate 为 nil(首次排期)不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: nil,
            newDueDate: date(2026, 8, 21, 9),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
        // 新值为 nil(清除日期)同样不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 21, 9),
            newDueDate: nil,
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
    }

    func testIsDeferral_completedOrAbandoned_notDeferred() {
        // 已完成不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 20, 10),
            newDueDate: date(2026, 8, 21, 9),
            isCompleted: true,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
        // 已划掉不记
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 20, 10),
            newDueDate: date(2026, 8, 21, 9),
            isCompleted: false,
            abandonedAt: date(2026, 8, 20, 8),
            calendar: makeCalendar()
        ))
    }

    func testIsDeferral_startHour3_lateNightToEarlyMorning_sameUserDay() {
        // startHour=3:前一晚 23:50 → 次日 01:30 仍属同一用户日,不算推迟
        DayClock.setStartHour(3)
        XCTAssertFalse(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 20, 23, 50),
            newDueDate: date(2026, 8, 21, 1, 30),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
        // 对照:01:30 → 03:30 跨进新用户日,算推迟
        XCTAssertTrue(TaskEventRules.isDeferral(
            oldDueDate: date(2026, 8, 21, 1, 30),
            newDueDate: date(2026, 8, 21, 3, 30),
            isCompleted: false,
            abandonedAt: nil,
            calendar: makeCalendar()
        ))
    }
}
