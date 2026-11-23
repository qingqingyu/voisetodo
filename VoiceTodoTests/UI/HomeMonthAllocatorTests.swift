import XCTest
@testable import VoiceTodo

/// 月历注水法行高分配器 + 格子切片的测试(2026-11)。
///
/// 背景:分配器改成「两层需求」——先按未完成数分高度,已完成的只吃剩余空间。
/// 用户反馈已完成多的周抢走高度,今天 7 件未完成只露出 1 条。
///
/// 回归期望值(`testRegression*` 各组)的来源:改动前把旧 `allocateRowHeights(eventsPerDay:)`
/// 原样抽出来跑同一批输入,把输出的行高和条数抄下来。只含未完成的输入下新实现必须逐位一致。
final class HomeMonthAllocatorTests: XCTestCase {
    private typealias Metrics = HomeLayoutMetrics

    // MARK: - 第 1 组:回归(只含未完成,结果与改动前完全一致)

    func testRegressionFourWeekMonth() {
        let demand = allOpen([
            [3, 0, 0, 2, 0, 1, 0],
            [5, 0, 4, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [2, 0, 0, 0, 6, 0, 1],
        ])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 480)

        XCTAssertEqual(result.rowHeights, [101, 153, 24, 178])
        XCTAssertEqual(result.barsShown, [3, 5, 0, 6])
    }

    func testRegressionFiveWeekMonth() {
        let demand = allOpen([
            [1, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [4, 4, 0, 0, 3, 0, 0],
            [0, 0, 7, 0, 0, 0, 0],
            [2, 0, 0, 0, 0, 0, 0],
        ])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 480)

        XCTAssertEqual(result.rowHeights, [44, 20, 122, 192, 70])
        XCTAssertEqual(result.barsShown, [1, 0, 4, 6, 2])
    }

    func testRegressionSixWeekMonth() {
        let demand = allOpen([
            [0, 0, 0, 0, 0, 0, 0],
            [3, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [9, 0, 0, 5, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 1],
            [0, 0, 0, 0, 0, 0, 0],
        ])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 480)

        XCTAssertEqual(result.rowHeights, [20, 96, 20, 240, 44, 20])
        XCTAssertEqual(result.barsShown, [0, 3, 0, 8, 1, 0])
    }

    /// 同一份 6 周输入换个紧预算:Pass 3a 因 slack 不够中断、走 Pass 3b 的路径也要一致。
    func testRegressionSixWeekMonthTightBudget() {
        let demand = allOpen([
            [0, 0, 0, 0, 0, 0, 0],
            [3, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [9, 0, 0, 5, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 1],
            [0, 0, 0, 0, 0, 0, 0],
        ])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 300)

        XCTAssertEqual(result.rowHeights, [20, 24, 20, 152, 24, 20])
        XCTAssertEqual(result.barsShown, [0, 0, 0, 5, 0, 0])
    }

    /// 预算紧到 Pass 1 只给得起一周 1 条:估算 cap 压到 1、其余周分不到的路径。
    func testRegressionFiveWeekMonthVeryTightBudget() {
        let demand = allOpen([
            [1, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [4, 4, 0, 0, 3, 0, 0],
            [0, 0, 7, 0, 0, 0, 0],
            [2, 0, 0, 0, 0, 0, 0],
        ])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 200)

        XCTAssertEqual(result.rowHeights, [25, 20, 25, 74, 24])
        XCTAssertEqual(result.barsShown, [0, 0, 0, 2, 0])
    }

    // MARK: - 第 2 组:复现截图(已完成让位给未完成)

    /// 5 周月:第 3 周某天 5 条全已完成,第 4 周(今天)某天 7 条未完成,预算 ~380pt。
    /// 改动前(只按全部条数分):shown = [1, 0, 3, 4, 1]——今天那周只露出 4 条,
    /// 前一周却用 2 条位置显示已完成。改动后今天那周拿到 6 条。
    func testScreenshotScenarioOpenWeekWinsOverCompletedWeek() {
        let open = [
            [2, 0, 1, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0],
            [0, 0, 0, 7, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 1],
        ]
        let done = [
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 5, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
        ]
        let budget: CGFloat = 380
        let result = Metrics.allocateRowHeights(demandPerDay: demand(open: open, done: done), budgetHeight: budget)

        let todayWeek = 3
        let completedWeek = 2
        let legacyTodayBars = 4  // 改动前同一输入的输出
        XCTAssertGreaterThanOrEqual(result.barsShown[todayWeek], legacyTodayBars)
        XCTAssertGreaterThanOrEqual(result.barsShown[todayWeek], result.barsShown[completedWeek])

        XCTAssertEqual(result.barsShown, [1, 0, 1, 6, 1])

        // 「预算能装下的上限」用对照实验来定,不用手算公式:Pass 3a 第一段是「隐藏最多的周优先」,
        // 不是「其余各周先拿满未完成需求」,所以今天这周拿到的条数可能比按公式反推的还多 1
        // (第 1 周 open=2 只拿到 1 条,省下的高度让今天多装第 6 条)。
        // 同一份输入把已完成全部去掉(done 全 0)再跑一次:已完成的存在不应减少今天未完成的显示条数。
        let openOnly = Metrics.allocateRowHeights(demandPerDay: allOpen(open), budgetHeight: budget)
        XCTAssertEqual(result.barsShown[todayWeek], openOnly.barsShown[todayWeek], "有已完成 vs 没有已完成,今天那周条数相同")

        // 已完成多的周没被挤没:它自己那 1 条未完成仍在(这个预算下 5 条已完成都放不下,
        // 已完成能在剩余空间里显示的情况见下一个用例)。
        XCTAssertEqual(result.barsShown[completedWeek], 1)
    }

    /// 截图场景预算宽裕时(iPhone 15 量级 ~480pt):未完成全部显示,已完成用剩余空间补上。
    func testScreenshotScenarioAmpleBudgetShowsCompletedToo() {
        let open = [
            [2, 0, 1, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0],
            [0, 0, 0, 7, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 1],
        ]
        let done = [
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 5, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
        ]
        let result = Metrics.allocateRowHeights(demandPerDay: demand(open: open, done: done), budgetHeight: 480)

        XCTAssertEqual(result.barsShown[3], 7, "未完成 7 条全部显示")
        XCTAssertGreaterThan(result.barsShown[2], 1, "剩余空间用来显示已完成")
    }

    // MARK: - 第 3 组:只有已完成的周照样能显示

    func testCompletedOnlyWeekShowsWhenBudgetAmple() {
        let open = [
            [2, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
        ]
        let done = [
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 3, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
        ]
        let result = Metrics.allocateRowHeights(demandPerDay: demand(open: open, done: done), budgetHeight: 480)

        XCTAssertEqual(result.barsShown[0], 2, "未完成的先满足")
        XCTAssertEqual(result.barsShown[1], 3, "已完成的用剩余空间显示出来(Pass 3a 第二段生效)")
        XCTAssertEqual(result.barsShown[2], 0)
    }

    /// 未完成吃满之后才轮到已完成,且已完成只拿剩余空间:第 2 周 4 条未完成全显示,
    /// 只有已完成的第 1 周用剩余 slack 拿到 5 条(共 6 条),Pass 3a 第二段因 slack 不够一条中断。
    func testCompletedGetsOnlyLeftoverSlackAfterOpenSatisfied() {
        let open = [
            [0, 0, 0, 0, 0, 0, 0],
            [4, 0, 0, 0, 0, 0, 0],
        ]
        let done = [
            [0, 0, 6, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
        ]
        // avail = 300 - 8 = 292;估算 cap = Int((146-18)/26) = 4 → Pass 1/2 把第 2 周注到 4 条(need(4)=122),
        // 第 1 周 open=0 分不到。剩 292-122-20 = 150 给已完成,够 5 条(need(5)=148),第 6 条差 4pt。
        let result = Metrics.allocateRowHeights(demandPerDay: demand(open: open, done: done), budgetHeight: 300)

        XCTAssertEqual(result.barsShown[1], 4)
        XCTAssertEqual(result.barsShown[0], 5, "未完成全显示后,剩余空间给已完成")
        XCTAssertLessThanOrEqual(result.barsShown[0], 6)
    }

    // MARK: - 第 4 组:预算极小

    func testTinyBudgetDoesNotCrashAndShowsNothing() {
        let demand = demand(
            open: [[2, 0, 1, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0, 0], [0, 0, 0, 7, 0, 0, 0], [0, 0, 0, 0, 0, 0, 1]],
            done: [[0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 5, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]]
        )

        for budget: CGFloat in [30, 0, -50] {
            let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: budget)
            XCTAssertEqual(result.barsShown, [0, 0, 0, 0, 0], "预算 \(budget)")
            XCTAssertEqual(result.rowHeights, [20, 20, 20, 20, 20], "预算 \(budget):各周退回最小行高")
        }
    }

    func testEmptyInputReturnsEmpty() {
        let result = Metrics.allocateRowHeights(demandPerDay: [], budgetHeight: 480)
        XCTAssertEqual(result.rowHeights, [])
        XCTAssertEqual(result.barsShown, [])
    }

    // MARK: - 第 5 组:不变量

    func testInvariantsHoldAcrossVariedInputs() {
        var cases: [([[Metrics.DayDemand]], CGFloat)] = []
        // 固定几组:空月、单周超忙、全已完成、混合。
        cases.append((allOpen([[0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]]), 480))
        cases.append((allOpen([[15, 0, 0, 0, 0, 0, 0]]), 900))
        cases.append((demand(
            open: [[0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]],
            done: [[3, 2, 0, 0, 1, 0, 4], [0, 0, 5, 0, 0, 0, 0]]
        ), 480))
        // 确定性伪随机(线性同余,不依赖 SystemRandomNumberGenerator,失败可复现)。
        var seed: UInt64 = 20_261_123
        for weeks in [4, 5, 6] {
            for _ in 0..<12 {
                var openWeeks: [[Int]] = []
                var doneWeeks: [[Int]] = []
                for _ in 0..<weeks {
                    var openDays: [Int] = []
                    var doneDays: [Int] = []
                    for _ in 0..<7 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        let roll = Int((seed >> 33) % 100)
                        openDays.append(roll < 55 ? 0 : roll % 12)
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        let roll2 = Int((seed >> 33) % 100)
                        doneDays.append(roll2 < 70 ? 0 : roll2 % 6)
                    }
                    openWeeks.append(openDays)
                    doneWeeks.append(doneDays)
                }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                cases.append((demand(open: openWeeks, done: doneWeeks), CGFloat(240 + (seed >> 40) % 400)))
            }
        }

        let need = Metrics.needHeight(bars:)
        for (index, input) in cases.enumerated() {
            let result = Metrics.allocateRowHeights(demandPerDay: input.0, budgetHeight: input.1)
            let n = input.0.count
            XCTAssertEqual(result.rowHeights.count, n, "case \(index)")
            XCTAssertEqual(result.barsShown.count, n, "case \(index)")

            let totalDemand = input.0.map { $0.map(\.total).max() ?? 0 }
            for i in 0..<n {
                XCTAssertLessThanOrEqual(need(result.barsShown[i]), result.rowHeights[i] + 0.001, "case \(index) 周 \(i):行高装得下显示的条数")
                XCTAssertGreaterThanOrEqual(result.rowHeights[i], Metrics.gridCellChrome, "case \(index) 周 \(i):不低于最小行高")
                XCTAssertLessThanOrEqual(result.barsShown[i], totalDemand[i], "case \(index) 周 \(i):不超过全部需求")
                XCTAssertGreaterThanOrEqual(result.barsShown[i], 0)
            }

            // 核心保证(2026-11):已完成的存在不减少任何一周的条数——
            // 把同一输入的已完成全部去掉(total = open)再分配一次,混合输入每周的 barsShown
            // 都不低于纯未完成输入。依据:Pass 1/2 与 Pass 3a 第一段只看未完成,两者走到第一段结束时
            // shown 完全相同;之后 Pass 3a 第二段只加不减。Pass 3b 的零头在混合输入下会分给更多周
            // (含只有已完成的周),但出口 (b) 时 slack < 一条 bar 的增量(26pt),纯未完成输入里
            // 不可能靠这点零头多出一条(唯一有隐藏的周若是 shown=0,第一段早就给它加上了)。
            let openOnly = Metrics.allocateRowHeights(
                demandPerDay: input.0.map { $0.map { Metrics.DayDemand(open: $0.open, total: $0.open) } },
                budgetHeight: input.1
            )
            for i in 0..<n {
                XCTAssertGreaterThanOrEqual(result.barsShown[i], openOnly.barsShown[i], "case \(index) 周 \(i):已完成不挤占未完成的条数")
            }

            // 预算装得下最小行高时:行高总和 + 行间距恰好等于预算(剩余 slack 全部分出去)。
            let minimum = Metrics.gridCellChrome * CGFloat(n) + Metrics.gridRowSpacing * CGFloat(n - 1)
            if input.1 >= minimum {
                let used = result.rowHeights.reduce(0, +) + Metrics.gridRowSpacing * CGFloat(n - 1)
                XCTAssertEqual(used, input.1, accuracy: 0.001, "case \(index):用满预算且不超")
            }
        }
    }

    /// 硬上限:单日条数超过 15 时需求被截到 15,不会分出装不下的高度。
    func testHardLimitCapsDemand() {
        let demand = allOpen([[40, 0, 0, 0, 0, 0, 0]])
        let result = Metrics.allocateRowHeights(demandPerDay: demand, budgetHeight: 2_000)

        XCTAssertEqual(result.barsShown, [15])
        XCTAssertGreaterThanOrEqual(result.rowHeights[0], Metrics.needHeight(bars: 15))
    }

    // MARK: - 事件条切片(HomeMonthGridButton.slice,原 slicedEvents 抽出的 static 纯函数)

    /// 7 未完成 + 2 已完成,maxVisible = 4 → 4 条全是未完成,overflow = 3。
    func testSlicePrefersOpenAndCountsOpenOverflow() {
        let occurrences = makeOccurrences(open: 7, completed: 2)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 4)

        XCTAssertEqual(result.visible.count, 4)
        XCTAssertTrue(result.visible.allSatisfy { !$0.isCompleted })
        XCTAssertEqual(result.overflow, 3)
    }

    /// 2 未完成 + 5 已完成,maxVisible = 4 → 2 未完成 + 2 已完成,overflow = 0(无未完成溢出)。
    func testSliceFillsRemainderWithCompletedWithoutOverflow() {
        let occurrences = makeOccurrences(open: 2, completed: 5)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 4)

        XCTAssertEqual(result.visible.count, 4)
        XCTAssertEqual(result.visible.filter { !$0.isCompleted }.count, 2)
        XCTAssertEqual(result.visible.filter { $0.isCompleted }.count, 2)
        // total > maxVisible 的分支返回 max(0, …)(既有行为),视图层按 `overflow > 0` 判断,0 与 nil 等价。
        XCTAssertEqual(result.overflow ?? 0, 0)
    }

    /// 3 未完成,maxVisible = 0 → 事件条为空,overflow = 3(「+N」仍在日数字行显示)。
    func testSliceZeroVisibleStillReportsOpenOverflow() {
        let occurrences = makeOccurrences(open: 3, completed: 0)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 0)

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.overflow, 3)
    }

    func testSliceZeroVisibleWithMixedCountsOnlyOpen() {
        let occurrences = makeOccurrences(open: 4, completed: 6)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 0)

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.overflow, 4, "overflow 只数未完成")
    }

    func testSliceZeroVisibleOnlyCompletedHasNoOverflow() {
        let occurrences = makeOccurrences(open: 0, completed: 3)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 0)

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertNil(result.overflow)
    }

    func testSliceEverythingFitsHasNoOverflow() {
        let occurrences = makeOccurrences(open: 2, completed: 1)
        let result = HomeMonthGridButton.slice(occurrences, maxVisibleEvents: 5)

        XCTAssertEqual(result.visible.count, 3)
        XCTAssertNil(result.overflow)
    }

    func testSliceEmptyDay() {
        let result = HomeMonthGridButton.slice([], maxVisibleEvents: 3)
        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertNil(result.overflow)
    }

    // MARK: - Helpers

    private func allOpen(_ weeks: [[Int]]) -> [[Metrics.DayDemand]] {
        demand(open: weeks, done: weeks.map { $0.map { _ in 0 } })
    }

    private func demand(open: [[Int]], done: [[Int]]) -> [[Metrics.DayDemand]] {
        zip(open, done).map { openWeek, doneWeek in
            zip(openWeek, doneWeek).map { Metrics.DayDemand(open: $0, total: $0 + $1) }
        }
    }

    private func makeOccurrences(open: Int, completed: Int) -> [TodoOccurrenceData] {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        var occurrences: [TodoOccurrenceData] = []
        for index in 0..<(open + completed) {
            let isCompleted = index >= open
            let todo = TodoItemData(
                title: "任务 \(index)",
                dueDate: day,
                isCompleted: isCompleted,
                completedAt: isCompleted ? day : nil,
                extractionOutcome: .parsed
            )
            occurrences.append(TodoOccurrenceData(todo: todo, occurrenceDate: day, isCompleted: isCompleted))
        }
        return occurrences
    }
}
