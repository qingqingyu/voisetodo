import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `TriageRanking` 纯函数验收(2026-09-01 拍板 1+2,docs/todo-review-flow-v2.md):
/// 字典序排序(推迟次数 desc → 停滞天数 desc → id 决胜)、冷启动退化、
/// 停滞天数钳 0。见文档「验证」清单。
final class TriageRankingTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    private func now(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func todo(
        _ title: String,
        createdOn: Date,
        id: UUID = UUID()
    ) -> TodoItemData {
        TodoItemData(id: id, title: title, createdAt: createdOn)
    }

    /// 冷启动(事件表无推迟历史,deferCounts 全 0):自动退化成纯按停滞天数降序。
    func testRankColdStartDegradesToStagnationOrder() {
        let now = now(2026, 9, 1)
        let input = [
            todo("fresh", createdOn: calendar.date(byAdding: .day, value: -1, to: now)!),
            todo("ancient", createdOn: calendar.date(byAdding: .day, value: -60, to: now)!),
            todo("mid", createdOn: calendar.date(byAdding: .day, value: -10, to: now)!),
        ]
        let ranked = TriageRanking.rank(input, deferCounts: [:], now: now, calendar: calendar)
        XCTAssertEqual(ranked.map(\.title), ["ancient", "mid", "fresh"])
    }

    /// 有推迟数据:推迟次数优先,哪怕停滞天数更短(主键平滑接管,字典序非乘积)。
    func testRankDeferCountBeatsStagnation() {
        let now = now(2026, 9, 1)
        let seldomDeferred = todo("40 天没动过", createdOn: calendar.date(byAdding: .day, value: -40, to: now)!)
        let oftenDeferred = todo("3 天但推了 4 次", createdOn: calendar.date(byAdding: .day, value: -3, to: now)!)
        let ranked = TriageRanking.rank(
            [seldomDeferred, oftenDeferred],
            deferCounts: [oftenDeferred.id: 4],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(ranked.map(\.title), ["3 天但推了 4 次", "40 天没动过"])
    }

    /// 同推迟次数:停滞天数决胜;全同:id 确定性决胜(单测稳定,不随机)。
    func testRankTiebreakByStagnationThenID() {
        let now = now(2026, 9, 1)
        let older = todo("older", createdOn: calendar.date(byAdding: .day, value: -20, to: now)!)
        let newer = todo("newer", createdOn: calendar.date(byAdding: .day, value: -5, to: now)!)
        var ranked = TriageRanking.rank(
            [newer, older], deferCounts: [older.id: 2, newer.id: 2], now: now, calendar: calendar
        )
        XCTAssertEqual(ranked.map(\.title), ["older", "newer"])

        // 停滞也相同:两次排序结果一致(确定性)。
        let twinA = todo("twinA", createdOn: now)
        let twinB = todo("twinB", createdOn: now)
        ranked = TriageRanking.rank(
            [twinA, twinB], deferCounts: [:], now: now, calendar: calendar
        )
        let rankedAgain = TriageRanking.rank(
            [twinB, twinA], deferCounts: [:], now: now, calendar: calendar
        )
        XCTAssertEqual(ranked.map(\.id), rankedAgain.map(\.id))
    }

    /// 空数组 / 单条。
    func testRankEdgeCases() {
        let now = now(2026, 9, 1)
        XCTAssertTrue(TriageRanking.rank([], deferCounts: [:], now: now, calendar: calendar).isEmpty)
        let only = todo("only", createdOn: now)
        XCTAssertEqual(
            TriageRanking.rank([only], deferCounts: [only.id: 9], now: now, calendar: calendar).map(\.id),
            [only.id]
        )
    }

    /// 停滞天数:整日差;未来创建的脏数据钳 0。
    func testStagnationDaysClampsNegative() {
        let now = now(2026, 9, 1)
        XCTAssertEqual(
            TriageRanking.stagnationDays(
                of: todo("old", createdOn: calendar.date(byAdding: .day, value: -31, to: now)!),
                now: now, calendar: calendar
            ),
            31
        )
        XCTAssertEqual(
            TriageRanking.stagnationDays(of: todo("future", createdOn: now), now: now, calendar: calendar),
            0
        )
        // 未来 2 天创建的脏数据:不出现负数。
        XCTAssertEqual(
            TriageRanking.stagnationDays(
                of: todo("dirty", createdOn: calendar.date(byAdding: .day, value: 2, to: now)!),
                now: now, calendar: calendar
            ),
            0
        )
    }
}
