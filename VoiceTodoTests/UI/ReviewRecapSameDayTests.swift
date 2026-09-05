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

    // MARK: - monthSummary 窗口与标签口径(docs/review-window-tab-decoupling.md)

    /// 滚动 30 天窗口边界:窗口 = [todayStart − 1 个月, todayStart + 1 天)。
    /// 统计页 Hero(`fixedWindowSummary`)与流程第 1 步同调本 builder,
    /// 窗口一致性由构造保证——这里钉住边界,防回归成日历月。
    func testMonthSummary_windowIsRolling30Days_notCalendarMonth() throws {
        let today = try noon(2026, 9, 2)
        // startHour 已被 setUp 清零 → start = 2026-08-02 00:00,end = 2026-09-03 00:00。
        let summary = RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            allTodos: [],
            completedTodos: [
                // 窗口前一天(8/1)→ 不计。
                TodoItemData(title: "窗口前", isCompleted: true, completedAt: try noon(2026, 8, 1), createdAt: try noon(2026, 8, 1)),
                // 窗口首日(8/2)→ 计入。
                TodoItemData(title: "窗口首日", isCompleted: true, completedAt: try noon(2026, 8, 2), createdAt: try noon(2026, 8, 2)),
                // 今天(9/2,已在日历 9 月)→ 计入,证明是滚动窗口不是日历 8 月。
                TodoItemData(title: "今天", isCompleted: true, completedAt: today, createdAt: today),
            ],
            recurringCompletions: []
        )

        XCTAssertEqual(summary.total, 2, "8/1 不计、8/2 与 9/2 计入——滚动 30 天,非日历月")
    }

    /// periodLabel 覆盖参数(2026-09-04 拍板 B2):传值原样生效;缺省保留
    /// 日历月名旧行为——参数新增对既有调用方零回归。
    func testMonthSummary_periodLabelOverride() throws {
        let today = try noon(2026, 9, 2)
        let overridden = RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            periodLabel: "近 30 天",
            allTodos: [],
            completedTodos: [],
            recurringCompletions: []
        )
        XCTAssertEqual(overridden.periodLabel, "近 30 天")

        let fallback = RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            allTodos: [],
            completedTodos: [],
            recurringCompletions: []
        )
        XCTAssertFalse(fallback.periodLabel.isEmpty, "缺省仍产出日历月名标签")
        XCTAssertNotEqual(fallback.periodLabel, "近 30 天", "缺省行为不受参数新增影响")
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

    // MARK: - weekSummary(v3 拍板 1:窗口 = 上次复盘至今)

    /// 起点取 since 的用户日(含),窗口外不计——不是滚动 30 天。
    func testWeekSummary_startIsSince_notRollingMonth() throws {
        let summary = RecapSummaryBuilder.weekSummary(
            since: try noon(2026, 8, 28),
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: [],
            completedTodos: [
                TodoItemData(title: "起点当天", isCompleted: true, completedAt: try noon(2026, 8, 28), createdAt: try noon(2026, 8, 27)),
                TodoItemData(title: "起点前一天", isCompleted: true, completedAt: try noon(2026, 8, 27), createdAt: try noon(2026, 8, 27)),
                TodoItemData(title: "今天", isCompleted: true, completedAt: try noon(2026, 9, 4), createdAt: try noon(2026, 9, 4)),
            ],
            recurringCompletions: []
        )
        XCTAssertEqual(summary.total, 2, "8/28(含)起:起点前一天不计,起点当天与今天计入")
    }

    /// since == nil(首次复盘)→ 回落近 7 天。
    func testWeekSummary_firstReviewFallsBackTo7Days() throws {
        let summary = RecapSummaryBuilder.weekSummary(
            since: nil,
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: [],
            completedTodos: [
                TodoItemData(title: "8 天前", isCompleted: true, completedAt: try noon(2026, 8, 27), createdAt: try noon(2026, 8, 27)),
                TodoItemData(title: "7 天前", isCompleted: true, completedAt: try noon(2026, 8, 28), createdAt: try noon(2026, 8, 28)),
            ],
            recurringCompletions: []
        )
        XCTAssertEqual(summary.total, 1, "窗口 = 8/28(含)–9/5(不含),8/27 不计")
    }

    /// 回归护栏:periodLabel 是窗口描述(月日),不是日历月名——月名格式带
    /// 年份(「Sep 2026」/「2026年9月」),窗口描述只有月日;「滚动窗口配
    /// 日历月名」的错配正是 v3 拍板 1 要修的。
    func testWeekSummary_periodLabelIsWindowRange_notCalendarMonth() throws {
        let summary = RecapSummaryBuilder.weekSummary(
            since: try noon(2026, 8, 28),
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: [],
            completedTodos: [],
            recurringCompletions: []
        )
        XCTAssertFalse(summary.periodLabel.isEmpty)
        XCTAssertFalse(summary.periodLabel.contains("2026"), "窗口描述不带年份;带年份即回退成了日历月名")
    }

    /// sameDay 判词同口径分母(审阅修订二):oneOffCompletionCount 只数窗口内
    /// 一次性完成;total 含规律完成记录。有规律任务时两者不等——判词分母
    /// 不许合并回 total(回归护栏),summary.total 展示数不动。
    func testOneOffCompletions_denominatorExcludesRecurring() throws {
        let todos = [
            TodoItemData(title: "一次性", isCompleted: true, completedAt: try noon(2026, 8, 30), createdAt: try noon(2026, 8, 30)),
            TodoItemData(
                title: "规律",
                recurrenceRule: RecurrenceRule(frequency: .daily),
                isCompleted: true,
                completedAt: try noon(2026, 8, 31),
                createdAt: try noon(2026, 8, 1)
            ),
        ]
        XCTAssertEqual(
            ReviewAggregator.oneOffCompletions(todos, from: try noon(2026, 8, 28), to: try noon(2026, 9, 5), calendar: calendar),
            1,
            "窗口内一次性完成 = 1(规律父任务的 isCompleted 完成时刻不进分母)"
        )

        let summary = RecapSummaryBuilder.weekSummary(
            since: try noon(2026, 8, 28),
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: todos,
            completedTodos: todos.filter { $0.recurrenceRule == nil },
            recurringCompletions: [(id: UUID(), todoId: todos[1].id, completedAt: try noon(2026, 8, 31))]
        )
        XCTAssertEqual(summary.total, 2, "展示数含规律完成记录(对,用户确实做完了)")
        XCTAssertEqual(summary.oneOffCompletionCount, 1, "判词分母只数一次性完成——两个口径,别合并")
    }
}
