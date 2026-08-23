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
        id: UUID = UUID()
    ) -> InsightOpenTask {
        InsightOpenTask(todoId: id, createdAt: createdAt, dueDate: dueDate, title: title)
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

    /// 03-C:ratio 0.40(12/30)→ 不触发(中间地带隐藏)。
    func test03C_ratio040_hidden() throws {
        let now = try date(2026, 8, 21)
        let ctx = reactiveContext(reactive: 12, planned: 18, now: now)
        guard case .hidden = ReactiveVsPlannedRule().evaluate(ctx, calendar: calendar) else {
            return XCTFail("03-C 0.40 应隐藏")
        }
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
