import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// 洞察引擎阶段 2 验收用例(docs/todo-review-flow-design.md「验证」节 v1 清单):
/// 02-A/B/C、03-A/B/C、排序-A、冷却-A/B、降级-A,外加 DayClock startHour=3 的
/// 23:50 / 01:30 同用户日场景。
final class InsightsRuleTests: XCTestCase {
    private let calendar = Calendar.current

    override func tearDown() {
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
    }

    private func daysAgo(_ days: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    // MARK: - 夹具

    private func openTask(
        title: String,
        createdAt: Date,
        dueDate: Date? = nil,
        id: UUID = UUID(),
        category: TodoCategory = .life
    ) -> InsightOpenTask {
        InsightOpenTask(todoId: id, createdAt: createdAt, dueDate: dueDate, title: title, category: category)
    }

    private func completedEvent(created: Date, completed: Date, id: UUID = UUID()) -> InsightCompletedEvent {
        InsightCompletedEvent(
            todoId: id,
            createdAt: created,
            completedAt: completed,
            category: .life,
            priority: .normal,
            hasDueTime: false,
            dueDate: nil
        )
    }

    private func makeContext(
        now: Date,
        open: [InsightOpenTask] = [],
        defers: [UUID: Int] = [:],
        completed: [InsightCompletedEvent] = []
    ) -> InsightContext {
        InsightContext(
            from: daysAgo(30, from: now),
            to: now,
            completedEvents: completed,
            openTasks: open,
            dueTasks: [],
            deferCounts: defers
        )
    }

    // MARK: - 02 腐烂

    /// 02-A 触发:3 条推迟 ≥3 次 → fired,列表按推迟次数降序。
    func test02A_threeDeferredTasks_fireAndSortedByDeferCountDesc() throws {
        let now = try date(2026, 8, 21)
        let a = openTask(title: "A", createdAt: daysAgo(5, from: now))
        let b = openTask(title: "B", createdAt: daysAgo(5, from: now))
        let c = openTask(title: "C", createdAt: daysAgo(5, from: now))
        let healthy = openTask(title: "fresh", createdAt: daysAgo(1, from: now))
        let ctx = makeContext(
            now: now,
            open: [a, b, c, healthy],
            defers: [a.todoId: 3, b.todoId: 7, c.todoId: 5]
        )

        guard case let .fired(result) = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("02-A 应触发 fired")
        }
        XCTAssertEqual(result.id, .rotting)
        guard case let .rotting(items) = result.viz else { return XCTFail("viz 应为 rotting") }
        XCTAssertEqual(items.map(\.title), ["B", "C", "A"], "按推迟次数降序")
        XCTAssertEqual(items.map(\.deferCount), [7, 5, 3])
        // todoId 必须可关联回处理动作(阶段 3 跳回卡片堆)
        XCTAssertEqual(Set(items.map(\.todoId)), Set([a.todoId, b.todoId, c.todoId]))
    }

    /// 02-B 触发:1 条 25 天前创建、0 推迟 → 命中 age 分支。
    func test02B_taskCreated25DaysAgo_hitsAgeBranch() throws {
        let now = try date(2026, 8, 21)
        let old = openTask(title: "old", createdAt: daysAgo(25, from: now))
        let ctx = makeContext(now: now, open: [old], defers: [:])

        guard case let .fired(result) = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("02-B 应命中 age 分支触发")
        }
        guard case let .rotting(items) = result.viz else { return XCTFail() }
        XCTAssertEqual(items.first?.ageDays, 25)
        XCTAssertEqual(items.first?.deferCount, 0)
        // 单条样本 → 强制 lowData(minSample=3,n=1 < 1.5×3)
        XCTAssertEqual(result.strength, .lowData)
    }

    /// 02-B 边界:躺 20 天(刚好差一天)不触发。
    func test02B_age20Days_doesNotFire() throws {
        let now = try date(2026, 8, 21)
        let task = openTask(title: "t", createdAt: daysAgo(20, from: now))
        let ctx = makeContext(now: now, open: [task])
        guard case .hidden = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("躺 20 天不应触发(阈值 21)")
        }
    }

    /// 02-C 不计入:origin=review 的 4 次推迟不在 deferCounts 里(上游查询已排除),
    /// 该任务不触发。本用例固化「排除 origin==review」的原料契约。
    func test02C_reviewOriginDefers_excludedByContract() throws {
        let now = try date(2026, 8, 21)
        let reviewDeferred = openTask(title: "r", createdAt: daysAgo(5, from: now))
        // 阶段 1 查询(TodoQueryActor.insightContext)对 origin == .review 的 deferred
        // 事件不进 deferCounts——纯函数层只需信任并固化该契约。
        let ctx = makeContext(now: now, open: [reviewDeferred], defers: [:])
        guard case .hidden = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("origin=review 的推迟不计入,4 次也不该触发")
        }
    }

    /// 02-C 对照:同样的 4 次推迟,若是有效推迟(origin != .review)则触发。
    func test02C_fourAppDefers_fire() throws {
        let now = try date(2026, 8, 21)
        let task = openTask(title: "t", createdAt: daysAgo(5, from: now))
        let ctx = makeContext(now: now, open: [task], defers: [task.todoId: 4])
        guard case .fired = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("4 次有效推迟应触发")
        }
    }

    // MARK: - 03 计划 vs 救火

    private func reactiveContext(reactive: Int, planned: Int, now: Date) -> InsightContext {
        var events: [InsightCompletedEvent] = []
        for i in 0..<(reactive + planned) {
            let created = daysAgo(3 + i % 5, from: now)
            let completed = i < reactive
                ? created // 当天(同用户日)完成 = 救火
                : calendar.date(byAdding: .day, value: 2, to: created)! // 隔用户日 = 计划式
            events.append(completedEvent(created: created, completed: completed))
        }
        return makeContext(now: now, completed: events)
    }

    /// 03-A:ratio 0.62(26/42)→ 触发警示。
    func test03A_ratio062_n42_firesWarning() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 26, planned: 16, now: now)
        guard case let .fired(result) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("03-A 0.62 n=42 应触发")
        }
        XCTAssertEqual(result.id, .reactiveVsPlanned)
        guard case let .reactiveVsPlanned(ratio, n) = result.viz else { return XCTFail() }
        XCTAssertEqual(ratio, 26.0 / 42.0, accuracy: 0.0001)
        XCTAssertEqual(n, 42)
        // 警示文案路径(tone = observation,非好转)
        XCTAssertEqual(result.tone, .observation)
    }

    /// 03-B:ratio ≈0.17(5/30)→ 正向信号 + 好转文案。
    func test03B_ratioLow_n30_positiveCopy() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 5, planned: 25, now: now)
        guard case let .fired(result) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("03-B 0.18 n=30 应作为正向信号触发")
        }
        // 好转文案路径
        XCTAssertEqual(result.tone, .improving)
    }

    /// 03-C:ratio 0.40(12/30)→ 一行事实(v4 拍板 3,推翻 v1 的「隐藏」:
    /// 只报占比、不带判断;不走冷却、不记 shownInsights 由 State 侧
    /// `collect` 的分野保证,见 ReviewFlowStateTests)。
    func test03C_ratio040_factLine() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 12, planned: 18, now: now)
        guard case let .fact(line) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("03-C 0.40 应降级成一行事实(拍板 3)")
        }
        XCTAssertEqual(line.id, .reactiveVsPlanned)
        XCTAssertTrue(line.text.contains("40"), "只报占比:\(line.text)")
    }

    /// 03 样本不足(n < 15)→ placeholder 并写明还差多少。
    func test03_nBelow15_placeholderNeedMore() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 4, planned: 6, now: now)
        guard case let .placeholder(needMore) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("n=10 < minSample=15 应为 placeholder")
        }
        XCTAssertEqual(needMore, 5)
    }

    /// sampleNote 必须携带实际样本量(「不含规律任务」的口径文案在 xcstrings,阶段 3 三语验证)。
    func test03_sampleNoteCarriesSampleCount() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 26, planned: 16, now: now)
        guard case let .fired(result) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail()
        }
        // sampleNote 必须带样本数(任何语言下数字都会出现)
        XCTAssertTrue(result.sampleNote.contains("42"), result.sampleNote)
    }

    // MARK: - DayClock startHour=3:23:50 与 01:30 同用户日

    /// startHour=3 时,23:50 记下、次日 01:30 完成 → 同一用户日,算「救火」。
    func testDayClockHour3_lateNightCompletionCountsAsSameUserDay() throws {
        DayClock.setStartHour(3)
        let now = try date(2026, 8, 21)
        let created = try date(2026, 8, 19, 23, 50)
        let completed = try date(2026, 8, 20, 1, 30) // 用户日仍是 8/19
        var events = [completedEvent(created: created, completed: completed)]
        // 补足样本:其余全是隔用户日的计划式
        for i in 0..<30 {
            let c = daysAgo(5 + i % 5, from: now)
            events.append(completedEvent(created: c, completed: calendar.date(byAdding: .day, value: 2, to: c)!))
        }
        let ctx = makeContext(now: now, completed: events)
        guard case let .fired(result) = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("样本充足应触发")
        }
        guard case let .reactiveVsPlanned(ratio, n) = result.viz else { return XCTFail() }
        XCTAssertEqual(n, 31)
        XCTAssertEqual(ratio, 1.0 / 31.0, accuracy: 0.0001, "23:50→01:30 应算同用户日(救火)")
    }

    /// startHour=3 对照:23:50 记下、次日 04:00 完成 → 不同用户日,不算救火。
    func testDayClockHour3_completionAfterStartHourIsNextUserDay() throws {
        DayClock.setStartHour(3)
        let created = try date(2026, 8, 19, 23, 50)
        let completed = try date(2026, 8, 20, 4, 0)
        XCTAssertFalse(
            DayClock.isSameUserDay(created, completed, calendar: calendar),
            "跨过 03:00 用户日边界,应属不同用户日"
        )
    }

    /// startHour=3:腐烂 age 天数也按用户日算(01:30 创建的 now 仍在其后用户日)。
    func testDayClockHour3_rottingAgeUsesUserDays() throws {
        DayClock.setStartHour(3)
        let now = try date(2026, 8, 21, 1, 30) // 用户日 8/20
        let created = try date(2026, 7, 31, 1, 30) // 用户日 7/30,躺 21 个用户日
        let task = openTask(title: "t", createdAt: created)
        let ctx = makeContext(now: now, open: [task])
        guard case let .fired(result) = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("21 个用户日应命中 age 分支")
        }
        guard case let .rotting(items) = result.viz else { return XCTFail() }
        XCTAssertEqual(items.first?.ageDays, 21)
    }

    // MARK: - 排序-A

    /// 排序-A:全部触发 → score 降序;n < 1.5×minSample 强制 lowData。
    func testRankA_sortedByScoreDesc_andForcedLowData() throws {
        let now = try date(2026, 8, 21)
        // 规则 03:n=16(≥15 触发但 < 1.5×15=22.5)→ 强制 lowData,score 再高也是 lowData
        var events: [InsightCompletedEvent] = []
        for _ in 0..<16 {
            let c = daysAgo(5, from: now)
            events.append(completedEvent(created: c, completed: c)) // 全部救火 ratio=1.0
        }
        let reactiveCtx = makeContext(now: now, completed: events)
        guard case let .fired(reactiveResult) = ReactiveVsPlannedRule().evaluate(reactiveCtx, calendar: calendar) else {
            return XCTFail("n=16 应触发")
        }
        // ratio=1.0 → effect=1.0,conf=16/30 → score≈0.53(够 medium 线)但 n<22.5 → lowData
        XCTAssertEqual(reactiveResult.strength, .lowData, "n < 1.5×minSample 强制 lowData")

        // 规则 02:4 条 open 全部腐烂 → effect=1.0,conf=4/6≈0.67 → score≈0.67
        let rotA = openTask(title: "a", createdAt: daysAgo(25, from: now))
        let rotB = openTask(title: "b", createdAt: daysAgo(30, from: now))
        let rotC = openTask(title: "c", createdAt: daysAgo(22, from: now))
        let rotD = openTask(title: "d", createdAt: daysAgo(40, from: now))
        let rottingCtx = makeContext(now: now, open: [rotA, rotB, rotC, rotD])
        guard case let .fired(rottingResult) = RottingRule().evaluate(rottingCtx, calendar: calendar) else {
            return XCTFail("四条 ≥21 天的任务应全部触发")
        }

        let ranked = InsightEngine.rank([rottingResult, reactiveResult])
        XCTAssertEqual(ranked.map(\.id), [.rotting, .reactiveVsPlanned], "score 降序:0.67 > 0.53")
    }

    /// 强度线本身:score/confidence 公式的直接断言。
    func testConfidenceAndStrengthLines() {
        XCTAssertEqual(InsightEngine.confidence(sampleCount: 30, minSample: 15), 1.0, "2×minSample 满分")
        XCTAssertEqual(InsightEngine.confidence(sampleCount: 15, minSample: 15), 0.5, accuracy: 0.0001)
        XCTAssertEqual(InsightEngine.strength(score: 0.7, sampleCount: 100, minSample: 15), .high)
        XCTAssertEqual(InsightEngine.strength(score: 0.4, sampleCount: 100, minSample: 15), .medium)
        XCTAssertEqual(InsightEngine.strength(score: 0.9, sampleCount: 10, minSample: 15), .lowData, "n<1.5×minSample 一票否决")
    }

    // MARK: - 降级-A

    func testLadderA_threeCompletions_skipsStep() {
        XCTAssertEqual(InsightEngine.ladder(completedRecordCount: 3), .skipStep)
        XCTAssertEqual(InsightEngine.ladder(completedRecordCount: 0), .skipStep)
        XCTAssertEqual(InsightEngine.ladder(completedRecordCount: 5), .rottingOnly(needMore: 10))
        XCTAssertEqual(InsightEngine.ladder(completedRecordCount: 14), .rottingOnly(needMore: 1))
        XCTAssertEqual(InsightEngine.ladder(completedRecordCount: 15), .full)
    }

    // MARK: - 冷却 A/B

    /// 冷却-A:上次展示过、效应量变化 8%、间隔 1 次 → 不展示。
    func testCooldownA_eightPercentChange_suppressed() {
        let decision = InsightEngine.cooldown(
            .init(
                reviewsSinceLastShown: 1,
                lastEffectSize: 0.50,
                currentEffectSize: 0.46, // -8%
                lowerIsBetter: true
            )
        )
        guard case .failure = decision else { return XCTFail("8% 变化且间隔不足应冷却") }
    }

    /// 15% 变化放行;变好(lowerIsBetter 且下降)标 improved=true(用好转文案)。
    func testCooldown_fifteenPercentChange_showsWithImprovedFlag() {
        let improved = InsightEngine.cooldown(
            .init(reviewsSinceLastShown: 0, lastEffectSize: 0.40, currentEffectSize: 0.34, lowerIsBetter: true)
        )
        XCTAssertEqual(improved, .success(.effectChanged(improved: true)))

        let worsened = InsightEngine.cooldown(
            .init(reviewsSinceLastShown: 0, lastEffectSize: 0.40, currentEffectSize: 0.46, lowerIsBetter: true)
        )
        XCTAssertEqual(worsened, .success(.effectChanged(improved: false)))

        let interval = InsightEngine.cooldown(
            .init(reviewsSinceLastShown: 3, lastEffectSize: 0.40, currentEffectSize: 0.41, lowerIsBetter: true)
        )
        XCTAssertEqual(interval, .success(.intervalElapsed))
    }

    // MARK: 占位行选取(v3 ③ 拍板 7)

    /// 选条按 `placeholderPriority` 固定优先序,**不比 needMore 数值**——三条
    /// 规则缺口量纲不同(高优完成 vs 完成记录),比大小会随机推荐更难达成的
    /// 条件。对抗夹具:effortOrdering(3) 数值上比 energyWindow(2) 更大,
    /// 仍必须选 effortOrdering——按「取最小」实现的代码会在这条上红。
    /// 走查场景恰好只有一条占位,min/max/优先序结果相同,此错走查不可能暴露。
    func testPlaceholderPicksByPriorityNotByValue() {
        let both: [(id: InsightID, needMore: Int)] = [
            (id: .energyWindow, needMore: 2),
            (id: .effortOrdering, needMore: 3),
        ]
        XCTAssertEqual(InsightID.firstPlaceholder(in: both)?.id, .effortOrdering)

        let reactiveOnly: [(id: InsightID, needMore: Int)] = [(id: .reactiveVsPlanned, needMore: 5)]
        XCTAssertEqual(InsightID.firstPlaceholder(in: reactiveOnly)?.id, .reactiveVsPlanned)

        XCTAssertNil(InsightID.firstPlaceholder(in: []), "无占位 → 行不渲染")
    }

    /// 占位文案键映射(v3 拍板 7):三条可占位规则按 id 出**静态字面量**键,
    /// rotting/预留 id 无占位文案 → nil(行不渲染)。断言环境无关:swift test
    /// (无 catalog)回落「键模式 + 实参」,app 宿主测试(catalog 在场)返回
    /// 真文案——两环境都成立的是:非 nil、三条互不相同(同 N 不同串 ⇒ 键
    /// 各自命中,防 id↔键错接)、文案含 N。⚠️ 若有人把键改回
    /// `"\(...rawValue)"` 动态拼键,运行时查 `need_more.%@_%lld`(catalog
    /// 无此键,真机整串回落键名)——该构造约束由 `placeholderText` 的
    /// 静态字面量与注释保证,单测两环境下无法区分动态拼键,不在此断言。
    func testPlaceholderTextKeyedStaticallyById() {
        let effort = InsightID.effortOrdering.placeholderText(needMore: 3)
        let energy = InsightID.energyWindow.placeholderText(needMore: 3)
        let reactive = InsightID.reactiveVsPlanned.placeholderText(needMore: 3)

        XCTAssertNotNil(effort)
        XCTAssertNotNil(energy)
        XCTAssertNotNil(reactive)
        // 同 N 三条互不相同 ⇒ 三个 id 各自命中各自的键。
        XCTAssertNotEqual(effort, energy)
        XCTAssertNotEqual(effort, reactive)
        XCTAssertNotEqual(energy, reactive)
        // N 段进了文案(回落键模式与三语真文案都含 N)。
        XCTAssertTrue(effort?.contains("3") == true, "文案携带 needMore: \(String(describing: effort))")
        XCTAssertTrue(energy?.contains("3") == true)
        XCTAssertTrue(reactive?.contains("3") == true)

        XCTAssertNil(InsightID.rotting.placeholderText(needMore: 1), "rotting 无占位分支")
        XCTAssertNil(InsightID.brokenPromises.placeholderText(needMore: 1), "04 未实现")
        XCTAssertNil(InsightID.weeklyDecay.placeholderText(needMore: 1), "06 未实现")
    }
}

// MARK: - 01 先易后难(2026-08-23 启用)

final class EffortOrderingRuleTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)))
    }

    private func event(
        createdDaysAgo: Int,
        spanDays: Int,
        priority: Priority,
        now: Date
    ) -> InsightCompletedEvent {
        let created = calendar.date(byAdding: .day, value: -createdDaysAgo, to: now)!
        let completed = calendar.date(byAdding: .day, value: -(createdDaysAgo - spanDays), to: now)!
        return InsightCompletedEvent(
            todoId: UUID(),
            createdAt: created,
            completedAt: completed,
            category: .work,
            priority: priority,
            hasDueTime: false,
            dueDate: nil
        )
    }

    private func makeContext(now: Date, completed: [InsightCompletedEvent]) -> InsightContext {
        InsightContext(
            from: calendar.date(byAdding: .day, value: -30, to: now)!,
            to: now,
            completedEvents: completed,
            openTasks: [],
            dueTasks: [],
            deferCounts: [:]
        )
    }

    /// 01-A 触发:高优中位 6 天 vs 其他 1 天(≥ max(2,2))→ fired,viz 带中位数。
    func test01A_highDragsMuchLonger_fires() throws {
        let now = try date(2026, 8, 21)
        let highSpans = [5, 6, 7, 8].map { span in event(createdDaysAgo: 10, spanDays: span, priority: .high, now: now) }
        let other = (0..<4).map { _ in event(createdDaysAgo: 10, spanDays: 0, priority: .normal, now: now) }
        let ctx = makeContext(now: now, completed: highSpans + other)

        guard case let .fired(result) = EffortOrderingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("01-A 应触发 fired")
        }
        XCTAssertEqual(result.id, .effortOrdering)
        XCTAssertEqual(result.tone, .observation)
        guard case let .effortOrdering(highDays, otherDays, highCount, otherCount) = result.viz else {
            return XCTFail("viz 应为 effortOrdering")
        }
        XCTAssertEqual(highDays, 6, "5,6,7,8 中位 = (6+7)/2 = 6")
        XCTAssertEqual(otherDays, 0)
        XCTAssertEqual(highCount, 4)
        XCTAssertEqual(otherCount, 4)
        // n = 较稀缺组 = 4 < 1.5×6 → 强制 lowData(诚实标注)
        XCTAssertEqual(result.strength, .lowData)
    }

    /// 01-B 中间地带:高优 3 天 vs 其他 2 天 → hidden。
    func test01B_mildGap_hidden() throws {
        let now = try date(2026, 8, 21)
        let high = [2, 3, 3, 4].map { event(createdDaysAgo: 10, spanDays: $0, priority: .high, now: now) }
        let other = [1, 2, 2, 3].map { event(createdDaysAgo: 10, spanDays: $0, priority: .normal, now: now) }
        let ctx = makeContext(now: now, completed: high + other)
        guard case .hidden = EffortOrderingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("01-B 3 vs 2 天应 hidden")
        }
    }

    /// 01-C 正向:高优中位 ≤ 其他 → improving。
    func test01C_highFaster_improving() throws {
        let now = try date(2026, 8, 21)
        let high = [0, 1, 1, 2].map { event(createdDaysAgo: 10, spanDays: $0, priority: .high, now: now) }
        let other = [2, 3, 3, 4].map { event(createdDaysAgo: 10, spanDays: $0, priority: .normal, now: now) }
        let ctx = makeContext(now: now, completed: high + other)
        guard case let .fired(result) = EffortOrderingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("01-C 应触发正向 fired")
        }
        XCTAssertEqual(result.tone, .improving)
        // improving 的 effectSize 取负(「越大越糟」冷却语义,防止跨期 tone 翻转
        // 时把恶化误标 improving):effect = (3-1)/3 取负 = -2/3。
        XCTAssertEqual(result.effectSize, -2.0 / 3.0, accuracy: 0.001)
    }

    /// 01-D 组样本不足:高优仅 2 条 → placeholder 写清还差几条。
    func test01D_groupTooSmall_placeholder() throws {
        let now = try date(2026, 8, 21)
        let high = [1, 2].map { event(createdDaysAgo: 10, spanDays: $0, priority: .high, now: now) }
        let other = (0..<6).map { _ in event(createdDaysAgo: 10, spanDays: 1, priority: .normal, now: now) }
        let ctx = makeContext(now: now, completed: high + other)
        guard case let .placeholder(needMore) = EffortOrderingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("01-D 应 placeholder")
        }
        XCTAssertEqual(needMore, 1)
    }

    /// 01-E 对照组不足(高优已满 ≥3、其他 <3)**不出占位**:该分支缺口在
    /// 非高优组,按 effortOrdering 占位键写「做完 N 条高优」照做永不解锁
    /// (v3 ③ 验收禁止);诚实建议(去做普通任务以解锁)违反反 gaming
    /// 章程——没有可诚实建议的动作就不说。走查场景不会碰到(priority 可
    /// 手改,高优重度用户可达),此错只能靠本测试挡。
    func test01E_otherGroupTooSmall_noPlaceholder() throws {
        let now = try date(2026, 8, 21)
        let high = (0..<4).map { _ in event(createdDaysAgo: 10, spanDays: 1, priority: .high, now: now) }
        let other = (0..<2).map { _ in event(createdDaysAgo: 10, spanDays: 1, priority: .normal, now: now) }
        let ctx = makeContext(now: now, completed: high + other)
        guard case .hidden = EffortOrderingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("01-E 高优已满、对照组不足应 hidden,不得出高优口径占位")
        }
    }
}

// MARK: - 05 精力窗口(2026-08-23 启用)

final class EnergyWindowRuleTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)))
    }

    /// 高优 + 带钟点(dueHour)的完成事件(completedAt = now,完成钟点由 now 决定)。
    private func timedHigh(now: Date, dueHour: Int) throws -> InsightCompletedEvent {
        InsightCompletedEvent(
            todoId: UUID(),
            createdAt: calendar.date(byAdding: .day, value: -2, to: now)!,
            completedAt: now,
            category: .work,
            priority: .high,
            hasDueTime: true,
            dueDate: try date(2026, 8, 20, dueHour)
        )
    }

    /// 普通完成事件(completedAt = now)。
    private func filler(now: Date) -> InsightCompletedEvent {
        InsightCompletedEvent(
            todoId: UUID(),
            createdAt: calendar.date(byAdding: .day, value: -1, to: now)!,
            completedAt: now,
            category: .life,
            priority: .normal,
            hasDueTime: false,
            dueDate: nil
        )
    }

    private func makeContext(now: Date, completed: [InsightCompletedEvent]) -> InsightContext {
        InsightContext(
            from: calendar.date(byAdding: .day, value: -30, to: now)!,
            to: now,
            completedEvents: completed,
            openTasks: [],
            dueTasks: [],
            deferCounts: [:]
        )
    }

    /// 05-A 触发:15 条完成全在 9 点 + 2 件高优排在 22/23 点 → fired,lowData(稀缺腿 n=2)。
    func test05A_morningPeakLateHigh_fires() throws {
        let now = try date(2026, 8, 21, 9)
        var events: [InsightCompletedEvent] = (0..<13).map { _ in filler(now: now) }
        events.append(try timedHigh(now: now, dueHour: 22))
        events.append(try timedHigh(now: now, dueHour: 23))
        let ctx = makeContext(now: now, completed: events)

        guard case let .fired(result) = EnergyWindowRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("05-A 应触发 fired")
        }
        XCTAssertEqual(result.id, .energyWindow)
        guard case let .energyWindow(hourCounts, highDueHours, peakHour) = result.viz else {
            return XCTFail("viz 应为 energyWindow")
        }
        XCTAssertEqual(hourCounts.count, 24)
        XCTAssertEqual(Set(highDueHours), [22, 23])
        XCTAssertEqual(peakHour, 9)
        // 稀缺腿 n=2 → 恒 lowData(demo 同款诚实标注)
        XCTAssertEqual(result.strength, .lowData)
    }

    /// 05-B 高峰在下午 → hidden(上半句不成立,组合洞察宁漏报不误报)。
    func test05B_afternoonPeak_hidden() throws {
        let now = try date(2026, 8, 21, 15)
        var events: [InsightCompletedEvent] = (0..<13).map { _ in filler(now: now) }
        events.append(try timedHigh(now: now, dueHour: 22))
        events.append(try timedHigh(now: now, dueHour: 23))
        let ctx = makeContext(now: now, completed: events)
        guard case .hidden = EnergyWindowRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("05-B 下午高峰应 hidden")
        }
    }

    /// 05-C 带钟点的高优仅 1 件 → hidden(下半句样本不足,整条不说)。
    func test05C_singleHighTimed_hidden() throws {
        let now = try date(2026, 8, 21, 9)
        var events: [InsightCompletedEvent] = (0..<14).map { _ in filler(now: now) }
        events.append(try timedHigh(now: now, dueHour: 22))
        let ctx = makeContext(now: now, completed: events)
        guard case .hidden = EnergyWindowRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("05-C 单件高优应 hidden")
        }
    }

    /// 05-D 完成记录 < 15 → placeholder 写清还差几条。
    func test05D_tooFewCompletions_placeholder() throws {
        let now = try date(2026, 8, 21, 9)
        let events = (0..<5).map { _ in filler(now: now) }
        let ctx = makeContext(now: now, completed: events)
        guard case let .placeholder(needMore) = EnergyWindowRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("05-D 应 placeholder")
        }
        XCTAssertEqual(needMore, 10)
    }
}

// MARK: - 地板 A · 积压年龄(v4 批 1,docs/todo-review-flow-v4.md)

final class BacklogAgeFloorTests: XCTestCase {
    private let calendar = Calendar.current

    override func tearDown() {
        DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)
        super.tearDown()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
    }

    private func daysAgo(_ days: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    private func openTask(title: String, createdAt: Date) -> InsightOpenTask {
        InsightOpenTask(todoId: UUID(), createdAt: createdAt, dueDate: nil, title: title, category: .life)
    }

    private func fact(
        _ tasks: [InsightOpenTask],
        now: Date,
        rottingShown: Bool = false
    ) -> InsightEngine.BacklogAgeFact? {
        InsightEngine.backlogAgeFact(
            openTasks: tasks, now: now, calendar: calendar, rottingShown: rottingShown
        )
    }

    /// 零积压 → nil(整块不渲染——第 2 步卡堆也是空的,无话可说是诚实的)。
    func testEmptyBacklogReturnsNil() throws {
        let now = try date(2026, 8, 21)
        XCTAssertNil(fact([], now: now))
    }

    /// 19 条全新(1–19 天):三档 0–7 / 8–20 / 21+ 分布正确;点名最老 3 条
    /// (年龄降序);21+ 档为 0 且点名在场 → 说真话行(矩阵档 2)。
    func test19FreshTasks_bucketsNamingAndHonestLine() throws {
        let now = try date(2026, 8, 21)
        let tasks = (1...19).map { age in
            openTask(title: "t\(age)", createdAt: daysAgo(age, from: now))
        }
        let result = try XCTUnwrap(fact(tasks, now: now))

        XCTAssertEqual(result.total, 19)
        XCTAssertEqual(result.freshCount, 7, "0–7 天:1…7 天共 7 条")
        XCTAssertEqual(result.agingCount, 12, "8–20 天:8…19 天共 12 条")
        XCTAssertEqual(result.oldCount, 0)
        XCTAssertEqual(result.oldestAgeDays, 19)
        XCTAssertEqual(result.oldestItems.map(\.ageDays), [19, 18, 17], "最老前 3,年龄降序")
        XCTAssertTrue(result.showsNoOldLine, "21+ 为 0 且点名在场——说真话行渲染")
    }

    /// 含 21+ 条目:进 old 档(分界沿用 RottingRule.ageThresholdDays,20 天
    /// 不进、21 天进);点名含最老条目。
    func test21PlusItemsEnterOldBucket() throws {
        let now = try date(2026, 8, 21)
        let tasks = [
            openTask(title: "20天", createdAt: daysAgo(20, from: now)),
            openTask(title: "21天", createdAt: daysAgo(21, from: now)),
            openTask(title: "25天", createdAt: daysAgo(25, from: now)),
            openTask(title: "3天", createdAt: daysAgo(3, from: now)),
        ]
        let result = try XCTUnwrap(fact(tasks, now: now))
        XCTAssertEqual(result.oldCount, 2)
        XCTAssertEqual(result.agingCount, 1)
        XCTAssertEqual(result.freshCount, 1)
        XCTAssertEqual(result.oldestItems.map(\.title), ["25天", "21天", "20天"])
        XCTAssertFalse(result.showsNoOldLine, "21+ 档非空——真话行不出")
    }

    /// 腐烂卡本期展示 → 点名整体让位(分布条保留;腐烂卡的列表更细,同屏
    /// 不重复点名);被冷却扣掉时(rottingShown=false)地板照常点名。
    func testRottingShownYieldsNaming() throws {
        let now = try date(2026, 8, 21)
        let tasks = [
            openTask(title: "25天", createdAt: daysAgo(25, from: now)),
            openTask(title: "30天", createdAt: daysAgo(30, from: now)),
        ]
        let shown = try XCTUnwrap(fact(tasks, now: now, rottingShown: true))
        XCTAssertTrue(shown.oldestItems.isEmpty, "腐烂卡展示——点名让位")
        XCTAssertEqual(shown.oldCount, 2, "分布条照报(说事实不重复点名)")
        XCTAssertFalse(shown.showsNoOldLine)

        let cooledAway = try XCTUnwrap(fact(tasks, now: now, rottingShown: false))
        XCTAssertEqual(cooledAway.oldestItems.map(\.title), ["30天", "25天"], "冷却扣掉腐烂卡——地板点名顶上(核心回归:屏不空)")
    }

    /// 腐烂卡经推迟分支触发(0 条 ≥21 天)时点名为空 ⇔ 真话行同被压制
    /// (`showsNoOldLine` 的派生契约:腐烂卡自己有话可说,不叠加)。
    func testDeferBranchRottingSuppressesHonestLineDerivation() throws {
        let now = try date(2026, 8, 21)
        let tasks = [openTask(title: "t", createdAt: daysAgo(9, from: now))]
        let result = try XCTUnwrap(fact(tasks, now: now, rottingShown: true))
        XCTAssertEqual(result.oldCount, 0)
        XCTAssertTrue(result.oldestItems.isEmpty)
        XCTAssertFalse(result.showsNoOldLine, "点名为空(=腐烂卡在场)——真话行不出")
    }

    /// 口径边界(startHour=3):地板 A 的档位与 RottingRule 判定在 20/21 天
    /// 边界必须同一把尺(用户日)。7/31 04:00 创建(用户日 7/31)→ 20 个用户
    /// 日 → aging;7/31 01:30 创建(用户日 7/30)→ 21 个用户日 → old,
    /// 且 RottingRule 同步命中 age 分支(v4 批 1「口径统一到 DayClock」的
    /// 回归护栏——改回自然日会在这里红)。
    func testUserDayBoundaryMatchesRottingRule() throws {
        DayClock.setStartHour(3)
        let now = try date(2026, 8, 21, 1, 30) // 用户日 8/20
        let justUnder = try date(2026, 7, 31, 4, 0)  // 用户日 7/31 → 躺 20 个用户日
        let atLine = try date(2026, 7, 31, 1, 30)    // 用户日 7/30 → 躺 21 个用户日

        let under = try XCTUnwrap(fact([openTask(title: "u", createdAt: justUnder)], now: now))
        XCTAssertEqual(under.agingCount, 1)
        XCTAssertEqual(under.oldCount, 0)
        XCTAssertEqual(under.oldestItems.first?.ageDays, 20)

        let over = try XCTUnwrap(fact([openTask(title: "o", createdAt: atLine)], now: now))
        XCTAssertEqual(over.oldCount, 1, "21 个用户日 → old 档")
        XCTAssertEqual(over.oldestItems.first?.ageDays, 21)

        // 同尺对账:RottingRule 对 atLine 条目命中 age 分支(21 用户日)。
        let ctx = InsightContext(
            from: daysAgo(30, from: now), to: now,
            completedEvents: [], openTasks: [openTask(title: "o", createdAt: atLine)],
            dueTasks: [], deferCounts: [:]
        )
        guard case .fired = RottingRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("21 用户日应与 RottingRule 同步命中——地板与腐烂卡分界漂移")
        }
    }

    /// 同年龄 id 决胜(确定性,单测稳定);未来创建的脏数据钳 0(进 fresh 档)。
    func testDeterministicTiebreakAndFutureDataClamped() throws {
        let now = try date(2026, 8, 21)
        let a = openTask(title: "a", createdAt: daysAgo(10, from: now))
        let b = openTask(title: "b", createdAt: daysAgo(10, from: now))
        let result = try XCTUnwrap(fact([b, a], now: now))
        let expected = [a, b].sorted { $0.todoId.uuidString < $1.todoId.uuidString }
        XCTAssertEqual(result.oldestItems.map(\.todoId), expected.map(\.todoId))

        let future = openTask(title: "f", createdAt: calendar.date(byAdding: .day, value: 3, to: now)!)
        let clamped = try XCTUnwrap(fact([future], now: now))
        XCTAssertEqual(clamped.freshCount, 1, "未来创建钳 0 天,不产生负年龄")
        XCTAssertEqual(clamped.oldestAgeDays, 0)
    }
}

// MARK: - 地板 C · 积压集中在哪(v4 批 3,拍板 4 的下游)

final class BacklogCategoryFloorTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)))
    }

    private func daysAgo(_ days: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    private func open(_ title: String, category: TodoCategory, daysOld: Int, now: Date) -> InsightOpenTask {
        InsightOpenTask(
            todoId: UUID(), createdAt: daysAgo(daysOld, from: now),
            dueDate: nil, title: title, category: category
        )
    }

    private func done(_ category: TodoCategory, now: Date) -> InsightCompletedEvent {
        InsightCompletedEvent(
            todoId: UUID(), createdAt: daysAgo(3, from: now), completedAt: now,
            category: category, priority: .normal, hasDueTime: false, dueDate: nil
        )
    }

    private func fact(
        _ open: [InsightOpenTask],
        done completed: [InsightCompletedEvent] = [],
        now: Date
    ) -> InsightEngine.BacklogCategoryFact? {
        InsightEngine.backlogCategoryFact(
            openTasks: open, completedEvents: completed, now: now, calendar: calendar
        )
    }

    /// 零积压 → nil;全部 `.other`(AI 解析失败兜底)→ nil(「其他」不是领域)。
    func testNilOnEmptyOrOtherOnly() throws {
        let now = try date(2026, 8, 21)
        XCTAssertNil(fact([], now: now))
        XCTAssertNil(fact([open("x", category: .other, daysOld: 9, now: now)], now: now))
    }

    /// focus = 积压条数最多者;并列取声明序在先(TodoCategory.allCases 序,
    /// 确定性);focusOldestAgeDays 取该分类里最老的放置天数(用户日)。
    func testFocusPicksMostConcentratedWithDeclarationTiebreak() throws {
        let now = try date(2026, 8, 21)
        let open_ = [
            open("w1", category: .work, daysOld: 5, now: now),
            open("w2", category: .work, daysOld: 14, now: now),
            open("l1", category: .life, daysOld: 30, now: now),
        ]
        let result = try XCTUnwrap(fact(open_, now: now))
        XCTAssertEqual(result.focusCategory, .work, "2 > 1")
        XCTAssertEqual(result.focusCount, 2)
        XCTAssertEqual(result.focusOldestAgeDays, 14)
        XCTAssertNil(result.contrastCategory, "life 也有积压——无「全清」对照")

        // 并列 1:1 → 声明序在先者(断言用 allCases 动态算,不硬编码序)。
        let tie = [
            open("w", category: .work, daysOld: 3, now: now),
            open("l", category: .life, daysOld: 3, now: now),
        ]
        let firstDeclared = TodoCategory.allCases.first { $0 == .work || $0 == .life }
        let tieResult = try XCTUnwrap(fact(tie, now: now))
        XCTAssertEqual(tieResult.focusCategory, firstDeclared, "并列取声明序在先")
    }

    /// 对照组 = 本期完成过、当前零积压的分类里完成数最多者;`.other` 的完成
    /// 不当对照(「其他方面清完了」不是有效对照)。
    func testContrastPicksClearedCategoryWithMostCompletions() throws {
        let now = try date(2026, 8, 21)
        let open_ = [
            open("w1", category: .work, daysOld: 5, now: now),
            open("w2", category: .work, daysOld: 14, now: now),
        ]
        let completed = (0..<3).map { _ in done(.life, now: now) }
            + (0..<1).map { _ in done(.study, now: now) }
            + (0..<9).map { _ in done(.other, now: now) }
        let result = try XCTUnwrap(fact(open_, done: completed, now: now))
        XCTAssertEqual(result.contrastCategory, .life, "3 > 1,.other 的 9 条不算对照")
        XCTAssertEqual(result.contrastCount, 3)

        // 什么都没完成过 → 无对照(fact 仍出 focus 行)。
        let noDone = try XCTUnwrap(fact(open_, now: now))
        XCTAssertNil(noDone.contrastCategory)
    }
}
