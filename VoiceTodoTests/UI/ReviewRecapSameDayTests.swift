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

    private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int) throws -> Date {
        try XCTUnwrap(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
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

    // MARK: - oneOffBacklogDelta(地板 B 方向源,v4 复盘审阅发现 2)

    /// 一次性口径:记下(+1)/ 完成(−1)/ 划掉(−1)三路都要进方向;
    /// 规律任务(父任务与 occurrence 完成都)不进——规律完成不清积压。
    func testOneOffBacklogDelta_countsCreateCompleteAbandon_skipsRecurring() throws {
        let todos = [
            // 窗口内记下、还挂着 → +1。
            TodoItemData(title: "新挂着", createdAt: try noon(2026, 8, 10)),
            // 窗口外记下、窗口内完成 → −1。
            TodoItemData(
                title: "老任务清掉",
                isCompleted: true,
                completedAt: try noon(2026, 8, 12),
                createdAt: try noon(2026, 7, 1)
            ),
            // 窗口内划掉 → −1(复盘自己的主要出口,混口径减法会漏掉它)。
            TodoItemData(
                title: "不做了",
                createdAt: try noon(2026, 7, 20),
                abandonedAt: try noon(2026, 8, 15)
            ),
            // 窗口内记下又完成 → +1 −1 = 0(两边抵消,积压确实没变)。
            TodoItemData(
                title: "当天闭环",
                isCompleted: true,
                completedAt: try noon(2026, 8, 18),
                createdAt: try noon(2026, 8, 18)
            ),
            // 规律父任务:窗口内记下 → 不进方向(积压口径排除规律)。
            TodoItemData(
                title: "每日规律",
                recurrenceRule: RecurrenceRule(frequency: .daily),
                createdAt: try noon(2026, 8, 10)
            ),
            // 窗口外的动静一概不计。
            TodoItemData(
                title: "上月完成",
                isCompleted: true,
                completedAt: try noon(2026, 7, 2),
                createdAt: try noon(2026, 7, 1)
            ),
        ]

        let delta = ReviewAggregator.oneOffBacklogDelta(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(delta, -1, "+1 新挂 −1 完成 −1 划掉 +0 当天闭环,规律与窗外不计")
    }

    /// 拆小的净效应 = 父任务划掉(−1)+ N 条子任务记下(+N)。
    func testOneOffBacklogDelta_splitParentAbandonedChildrenCreated() throws {
        let splitDay = try noon(2026, 8, 10)
        let todos = [TodoItemData(title: "原任务", createdAt: try noon(2026, 7, 1), abandonedAt: splitDay)]
            + (0..<3).map { index in
                TodoItemData(title: "子\(index)", createdAt: splitDay, parentTodoId: UUID())
            }

        let delta = ReviewAggregator.oneOffBacklogDelta(
            todos,
            from: try noon(2026, 8, 1),
            to: try noon(2026, 9, 1),
            calendar: calendar
        )

        XCTAssertEqual(delta, 2, "−1 + 3 = +2")
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

    /// 起点取 since 时刻(含;下界时刻粒度,见下一条钉边界测试),窗口外不计
    /// ——不是滚动 30 天。
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

    /// 窗口起点 = 上次复盘完成**时刻**(2026-09-07 实施审阅发现 2 拍板:
    /// 时刻粒度)——起点折算用户日会把复盘当天早晨、已被上次复盘统计过的
    /// 完成重复计入,周节奏下每期窗口与上期重叠一天。夹具:上次复盘
    /// 9/3 09:00;9/3 08:00 完成的(复盘前)不计,9/3 10:00 完成的(复盘后)计。
    func testWeekSummary_startIsSinceInstant_notSinceUserDay() throws {
        let summary = RecapSummaryBuilder.weekSummary(
            since: try at(2026, 9, 3, hour: 9),
            today: try noon(2026, 9, 10),
            calendar: calendar,
            allTodos: [],
            completedTodos: [
                TodoItemData(title: "复盘前完成", isCompleted: true, completedAt: try at(2026, 9, 3, hour: 8), createdAt: try noon(2026, 9, 1)),
                TodoItemData(title: "复盘后完成", isCompleted: true, completedAt: try at(2026, 9, 3, hour: 10), createdAt: try noon(2026, 9, 1)),
            ],
            recurringCompletions: []
        )
        XCTAssertEqual(summary.total, 1, "窗口 = [9/3 09:00, 9/11):复盘前(08:00)不计,复盘后(10:00)计")
        XCTAssertEqual(summary.oneOffCompletionCount, 1)
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

    // MARK: - Hero 三态(v3 拍板 2,docs v3 验证章)

    /// 有上次置顶结局 → 兑现判词(total = 完成 + 待处理);nil(首次复盘 /
    /// 上次没置顶 / 上次置顶的已全删)→ 回退完成数句式,不硬造空承诺文案。
    func testHeroContentThreeStates() {
        XCTAssertEqual(RecapHeroContent.make(lastPinnedOutcome: nil), .countSummary)
        XCTAssertEqual(
            RecapHeroContent.make(lastPinnedOutcome: (completed: 1, pending: 2)),
            .pinnedOutcome(total: 3, completed: 1),
            "上次定的 3 件、1 件做完 → 判词「上次定的 3 件,1 件做完了」"
        )
    }

    // MARK: - sameDay 判词门槛(v3 ① 改动 4)

    /// 门槛边界:占比**严格大于** 40% 才出——恰在门槛(2/5 = 0.40)不出,
    /// 越过(3/5 = 0.60)出;分母为 0(只有规律完成)不出。判词键
    /// `review.hero.sameday_judgment` 三语均为「相当一部分」份额事实——
    /// 门槛不动文案不动,谁把比较级说法加回来先在这里红(审阅修订三护栏)。
    func testSameDayJudgmentThresholdBoundary() throws {
        // 5 条一次性完成,其中 2 条当天记当天完:2/5 = 0.40,恰在门槛 → 不出。
        let atThreshold = try judgmentSummary(sameDayCount: 2, oneOffCount: 5)
        XCTAssertFalse(atThreshold.showsSameDayJudgment, "占比 == 40% 不出(严格大于)")

        // 3 条当天完:3/5 = 0.60 → 出。
        let aboveThreshold = try judgmentSummary(sameDayCount: 3, oneOffCount: 5)
        XCTAssertTrue(aboveThreshold.showsSameDayJudgment, "占比 > 40% 出判词")

        // 分母为 0:窗口内只有规律完成记录 → 不出(无同口径分母)。
        let recurringOnly = RecapSummaryBuilder.weekSummary(
            since: try noon(2026, 8, 28),
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: [],
            completedTodos: [],
            recurringCompletions: [(id: UUID(), todoId: UUID(), completedAt: try noon(2026, 8, 31))]
        )
        XCTAssertEqual(recurringOnly.total, 1)
        XCTAssertEqual(recurringOnly.oneOffCompletionCount, 0)
        XCTAssertFalse(recurringOnly.showsSameDayJudgment)
    }

    /// 判词分母回归护栏:分母是 `oneOffCompletionCount` 不是 `total`——
    /// sameDay 2 / oneOff 4(占比 0.5,出),规律完成把 total 抬到 10(若有人
    /// 把分母改回 total 会算 0.2 不出)→ 这条红(审阅修订二)。
    func testSameDayJudgmentDenominatorIsOneOffNotTotal() throws {
        let summary = try judgmentSummary(sameDayCount: 2, oneOffCount: 4, recurringCount: 6)
        XCTAssertEqual(summary.total, 10, "total 含规律完成")
        XCTAssertEqual(summary.oneOffCompletionCount, 4)
        XCTAssertTrue(summary.showsSameDayJudgment, "2/4 = 0.5 > 0.4 出;若分母误用 total(2/10)则不出——回归护栏")
    }

    /// 判词夹具:窗口 8/28–9/4,sameDayCount 条「当天记当天完」+
    /// (oneOffCount − sameDayCount)条「前一天记次日完」+ recurringCount 条
    /// 规律完成记录(抬 total、不进分母)。
    private func judgmentSummary(
        sameDayCount: Int,
        oneOffCount: Int,
        recurringCount: Int = 0
    ) throws -> ReviewSummary {
        precondition(sameDayCount <= oneOffCount)
        let doneDay = try noon(2026, 8, 29)
        let plannedDay = try noon(2026, 8, 28)
        var oneOff: [TodoItemData] = (0..<sameDayCount).map { index in
            TodoItemData(title: "same\(index)", isCompleted: true, completedAt: doneDay, createdAt: doneDay)
        }
        oneOff.append(contentsOf: (0..<(oneOffCount - sameDayCount)).map { index in
            TodoItemData(title: "slow\(index)", isCompleted: true, completedAt: doneDay, createdAt: plannedDay)
        })
        let recurringParent = TodoItemData(
            title: "规律",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: try noon(2026, 8, 1)
        )
        var recurring: [(id: UUID, todoId: UUID, completedAt: Date)] = []
        for offset in 0..<recurringCount {
            recurring.append((id: UUID(), todoId: recurringParent.id, completedAt: try noon(2026, 8, 30 + offset % 3)))
        }
        return RecapSummaryBuilder.weekSummary(
            since: try noon(2026, 8, 28),
            today: try noon(2026, 9, 4),
            calendar: calendar,
            allTodos: recurringCount > 0 ? oneOff + [recurringParent] : oneOff,
            completedTodos: oneOff,
            recurringCompletions: recurring
        )
    }

    // MARK: - sameday 行零值消隐(v4 批 5 附带发现 4)

    /// 完成 > 0 但当天件数为 0 → 行不出(主文案级别的「0 件当天记当天做完」
    /// 读起来像指责);当天件数 > 0 → 出;total == 0 沿旧行为不出。
    /// 判词行依赖本行(>40% 份额在 sameDay==0 时数学上不可达,无需单测)。
    func testSameDayLineHiddenAtZero() throws {
        // 3 条一次性完成、全部隔天 → sameDay == 0:行消隐(走查病灶)。
        let zeroSameDay = try judgmentSummary(sameDayCount: 0, oneOffCount: 3)
        XCTAssertFalse(zeroSameDay.showsSameDayLine, "完成 3 但当天 0——「其中 0 件」是指责,不出")

        let hasSameDay = try judgmentSummary(sameDayCount: 2, oneOffCount: 5)
        XCTAssertTrue(hasSameDay.showsSameDayLine)

        let noCompletions = try judgmentSummary(sameDayCount: 0, oneOffCount: 0, recurringCount: 0)
        XCTAssertFalse(noCompletions.showsSameDayLine, "total == 0 沿旧行为——不出")
    }

    // MARK: - 英文单复数 variations 结构护栏(v4 批 5 附带发现 3)

    /// 直读**源码里的 catalog**(编译产物按语言拆 lproj,模拟器语言不定,
    /// 运行时断言会随宿主语言漂移):18 个已做 variations 的键 en 侧必须有
    /// one/other 两档且互不相同——删掉或写坏(只剩 other/两档同文)先红。
    /// 精确文案不在测试里重复(catalog 单一来源);zh/ja 无复数形态,不查。
    func testEnglishPluralVariationsStructurally() throws {
        let catalogURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])

        let variedKeys = [
            "review.flow.ledger.decided_%lld",
            "review.hero.sameday_%lld",
            "review.flow.rotting.age_%lld",
            "review.flow.triage.born_days_%lld",
            "review.flow.triage.tl_deferred_%lld",
            "review.insight.rotting.sample_note_%lld",
            "review.insight.effort.headline_%lld",
            "review.insight.rotting.headline_%lld",
        ]
        for key in variedKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let en = try XCTUnwrap(localizations["en"] as? [String: Any], key)
            let variations = try XCTUnwrap(en["variations"] as? [String: Any], "\(key) 缺 variations")
            let plural = try XCTUnwrap(variations["plural"] as? [String: Any], key)
            let one = try XCTUnwrap(plural["one"] as? [String: Any], key)
            let other = try XCTUnwrap(plural["other"] as? [String: Any], key)
            let oneValue = try XCTUnwrap((one["stringUnit"] as? [String: Any])?["value"] as? String, key)
            let otherValue = try XCTUnwrap((other["stringUnit"] as? [String: Any])?["value"] as? String, key)
            XCTAssertNotEqual(oneValue, otherValue, "\(key) 单复数两档不得同文(同文=variations 失效)")
        }
    }
}
