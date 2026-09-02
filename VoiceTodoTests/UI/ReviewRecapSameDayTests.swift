import XCTest
@testable import VoiceTodo

/// 「当天记下、当天做完」统计(2026-08-21 拍板新增)的口径测试。
///
/// 口径:completedAt 落在 [start, end) 区间、且与 createdAt 同一**用户日**;
/// 只数一次性任务(recurrenceRule == nil)——规律任务的完成记录
/// (TodoOccurrenceCompletion)没有 per-occurrence createdAt,算不了,
/// 排除(与第 3 步洞察 03 同口径,设计文档「偏差与口径」)。
///
/// 日期全部用正午构造,避开 DayClock 用户日起点(默认 0 点,可被偏好调到
/// 3 点)的边界耦合;startHour 的清理由 setUp/tearDown 对称负责。
final class ReviewRecapSameDayTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        try super.setUpWithError()
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
    }

    override func tearDownWithError() throws {
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        try super.tearDownWithError()
    }

    private func noon(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        )
    }

    // MARK: - 纯函数口径

    func testSameUserDayCounted_crossDayNot() throws {
        let doneDay = try noon(2026, 8, 19)
        let todos = [
            // 当天上午记、当天正午完 → 同一用户日,计入。
            TodoItemData(
                title: "当天记当天完",
                isCompleted: true,
                completedAt: doneDay,
                createdAt: doneDay.addingTimeInterval(-3 * 3600)
            ),
            // 昨天记、今天完 → 跨用户日,不计。
            TodoItemData(
                title: "隔天完",
                isCompleted: true,
                completedAt: doneDay,
                createdAt: try noon(2026, 8, 18)
            ),
        ]

        let count = ReviewAggregator.sameDayCompletions(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(count, 1)
    }

    func testRecurringExcluded_evenIfSameDay() throws {
        let day = try noon(2026, 8, 19)
        let todos = [
            TodoItemData(
                title: "每日规律",
                recurrenceRule: RecurrenceRule(frequency: .daily),
                isCompleted: true,
                completedAt: day,
                createdAt: day
            ),
        ]

        let count = ReviewAggregator.sameDayCompletions(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(count, 0, "规律任务没有 per-occurrence createdAt,不参与当天口径")
    }

    func testCompletedOutsideWindowExcluded() throws {
        let todos = [
            // 区间之前完成。
            TodoItemData(
                title: "上上个月",
                isCompleted: true,
                completedAt: try noon(2026, 6, 30),
                createdAt: try noon(2026, 6, 30)
            ),
            // endDay 当天完成(end 是开区间,不含)。
            TodoItemData(
                title: "区间边界",
                isCompleted: true,
                completedAt: try noon(2026, 9, 1),
                createdAt: try noon(2026, 9, 1)
            ),
            // 未完成(completedAt nil)。
            TodoItemData(title: "还没做完", createdAt: try noon(2026, 8, 19)),
        ]

        let count = ReviewAggregator.sameDayCompletions(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(count, 0)
    }

    func testMultipleDaysAccumulate() throws {
        let todos = try (1...3).map { day in
            let at = try noon(2026, 8, day * 5) // 5 / 10 / 15 日
            return TodoItemData(
                title: "第 \(day) 件",
                isCompleted: true,
                completedAt: at,
                createdAt: at.addingTimeInterval(-3600)
            )
        }

        let count = ReviewAggregator.sameDayCompletions(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(count, 3)
    }

    // MARK: - monthSummary 接线

    func testMonthSummary_sameDayCount_onlyOneOffSameDayCompletions() throws {
        let today = try noon(2026, 8, 21)
        let sameDay1 = try noon(2026, 8, 5)
        let sameDay2 = try noon(2026, 8, 12)
        let crossDay = try noon(2026, 8, 12)

        let summary = RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            allTodos: [],
            completedTodos: [
                TodoItemData(
                    title: "当天 1",
                    isCompleted: true,
                    completedAt: sameDay1,
                    createdAt: sameDay1
                ),
                TodoItemData(
                    title: "当天 2",
                    isCompleted: true,
                    completedAt: sameDay2,
                    createdAt: sameDay2.addingTimeInterval(-2 * 3600)
                ),
                TodoItemData(
                    title: "跨天",
                    isCompleted: true,
                    completedAt: crossDay,
                    createdAt: try noon(2026, 8, 10)
                ),
            ],
            recurringCompletions: [
                // 规律完成记录不参与当天口径(无 per-occurrence createdAt)。
                (id: UUID(), todoId: UUID(), completedAt: sameDay1),
            ]
        )

        XCTAssertEqual(summary.sameDayCount, 2)
    }

    // MARK: - 判词证据链(2026-09-01 拍板:完成 / 新增 / 还挂着)

    /// 新增:窗口内 createdAt 落区间,**不过滤规律**、不看完成态;
    /// 边界(开区间)与 sameDayCompletions 同约定。
    func testCreatedInWindow_countsAllTypes_openEndBoundary() throws {
        let todos = [
            TodoItemData(title: "窗口内-未完成", createdAt: try noon(2026, 8, 5)),
            TodoItemData(title: "窗口内-已完成", isCompleted: true, completedAt: try noon(2026, 8, 6), createdAt: try noon(2026, 8, 5)),
            TodoItemData(
                title: "窗口内-规律",
                recurrenceRule: RecurrenceRule(frequency: .daily),
                createdAt: try noon(2026, 8, 7)
            ),
            TodoItemData(title: "窗口前", createdAt: try noon(2026, 7, 31)),
            TodoItemData(title: "end 当天(开区间不含)", createdAt: try noon(2026, 8, 21)),
        ]

        let count = ReviewAggregator.createdInWindow(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 8, 21),
            calendar: calendar
        )

        XCTAssertEqual(count, 3, "未完成/已完成/规律都算新增,边界与窗口前不算")
    }

    /// 还挂着:与入口卡「N 件事等你决定」、第 2 步卡堆同口径
    /// (!isCompleted && abandonedAt == nil && recurrenceRule == nil)。
    func testPendingOneOffCount_matchesTriageInputCriteria() {
        let todos = [
            TodoItemData(title: "挂着"),
            TodoItemData(title: "完成了", isCompleted: true),
            TodoItemData(
                title: "划掉了",
                abandonedAt: Date()
            ),
            TodoItemData(
                title: "规律",
                recurrenceRule: RecurrenceRule(frequency: .daily)
            ),
            TodoItemData(title: "另一件挂着"),
        ]

        XCTAssertEqual(ReviewAggregator.pendingOneOffCount(todos), 2)
    }

    /// monthSummary 接线:三数并排的数据源就位(第 1 步判词证据链)。
    func testMonthSummary_carriesEvidenceChainNumbers() throws {
        let today = try noon(2026, 8, 21)
        let summary = RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            allTodos: [
                TodoItemData(title: "本月新增-未完成", createdAt: try noon(2026, 8, 10)),
                TodoItemData(title: "上月旧账-还挂着", createdAt: try noon(2026, 7, 15)),
                TodoItemData(title: "本月新增-已完成", isCompleted: true, completedAt: try noon(2026, 8, 11), createdAt: try noon(2026, 8, 9)),
            ],
            completedTodos: [],
            recurringCompletions: []
        )

        XCTAssertEqual(summary.createdCount, 2)
        XCTAssertEqual(summary.pendingOneOffCount, 2, "两件未完成的一次性(本月一件 + 上月一件)")
    }
}
