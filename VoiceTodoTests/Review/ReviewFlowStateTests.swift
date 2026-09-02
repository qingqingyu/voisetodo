import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `ReviewFlowState` 纯逻辑验收(阶段 3):
/// triage 输入过滤 / 步骤闸门(至少选 1 件,2026-08-22 放宽)/ 撤销栈(只覆盖划掉)/ 账本计数。
/// 见 docs/todo-review-flow-design.md「验证」与「阶段 3」。
///
/// fixture 注意:`todo(_:)` 每次调用生成新 UUID,决定必须作用于**同一实例**
/// (从 `state.deck` 取),否则 id 对不上。
@MainActor
final class ReviewFlowStateTests: XCTestCase {

    private func todo(
        _ title: String,
        isCompleted: Bool = false,
        abandoned: Bool = false,
        recurring: Bool = false,
        category: TodoCategory = .other,
        daysOld: Int = 0,
        dueDate: Date? = nil,
        extractionOutcome: ExtractionOutcome = .parsed
    ) -> TodoItemData {
        TodoItemData(
            title: title,
            dueDate: dueDate,
            recurrenceRule: recurring ? RecurrenceRule(frequency: .daily) : nil,
            category: category,
            isCompleted: isCompleted,
            createdAt: Calendar.current.date(byAdding: .day, value: -daysOld, to: Date())!,
            extractionOutcome: extractionOutcome,
            abandonedAt: abandoned ? Date() : nil
        )
    }

    // MARK: triage 输入过滤(拍板 4)

    func testTriageInputFiltersCompletedAbandonedAndRecurring() {
        let input = [
            todo("open one-shot"),               // ✓ 保留
            todo("done", isCompleted: true),      // ✗ 已完成
            todo("abandoned", abandoned: true),   // ✗ 已划掉
            todo("recurring", recurring: true),   // ✗ 规律任务(刷屏,拍板 4)
            todo("another open"),                 // ✓ 保留
        ]
        let result = ReviewFlowState.triageInput(from: input)
        XCTAssertEqual(result.map(\.title), ["open one-shot", "another open"])
    }

    // MARK: 步骤闸门(2026-08-22 拍板放宽:至少选 1 件)

    func testCommitGateRequiresAtLeastOneSelection() {
        let state = ReviewFlowState(todos: (0..<5).map { todo("t\($0)") })
        // 没有任何决定时:候选池空 → 闸门放行(无从选起,见 State 注释)。
        XCTAssertTrue(state.canPassCommit)

        for item in state.deck { state.markScheduled(item) }
        // 候选池非空:0 件不过,1 件即过(不再强制选满 3)。
        XCTAssertFalse(state.canPassCommit)
        state.toggleCommitSelection(state.scheduled[0])
        XCTAssertTrue(state.canPassCommit)
        // 第 4 件:已达上限 3,不可再选。
        for item in state.scheduled.dropFirst() { state.toggleCommitSelection(item) }
        state.toggleCommitSelection(state.scheduled[3])
        XCTAssertEqual(state.commitSelection.count, 3)
        XCTAssertTrue(state.canPassCommit)
    }

    func testCommitGateWhenFewerThanThreeScheduled() {
        let state = ReviewFlowState(todos: [todo("a"), todo("b")])
        let items = state.deck
        state.markScheduled(items[0])
        state.markScheduled(items[1])
        XCTAssertFalse(state.canPassCommit)
        state.toggleCommitSelection(state.scheduled[0])
        XCTAssertTrue(state.canPassCommit)
    }

    func testToggleCommitSelectionDeselectsBeyondCap() {
        let state = ReviewFlowState(todos: (0..<4).map { todo("t\($0)") })
        for item in state.deck { state.markScheduled(item) }
        for item in state.scheduled.prefix(3) { state.toggleCommitSelection(item) }
        // 取消到 0 件 → 闸门重新关上。
        for item in state.scheduled.prefix(3) { state.toggleCommitSelection(item) }
        XCTAssertEqual(state.commitSelection.count, 0)
        XCTAssertFalse(state.canPassCommit)
    }

    // MARK: 撤销栈只覆盖划掉(拍板 7)

    func testUndoOnlyRestoresAbandoned() {
        // 2026-09-01 拍板 2 后 init 按停滞天数重排,固定顺序需错开 createdAt。
        let state = ReviewFlowState(todos: [
            todo("a", daysOld: 30),
            todo("b", daysOld: 20),
            todo("c", daysOld: 10),
        ])
        let a = state.deck[0], b = state.deck[1], c = state.deck[2]
        // 排进下周:不进撤销栈。
        state.markScheduled(a)
        // 今天就做:不进撤销栈。
        state.markToday(b)
        // 划掉:进撤销栈。
        state.markAbandoned(c)

        let restored = state.popAbandonForUndo()
        XCTAssertEqual(restored?.title, "c")
        // 划掉撤销后任务回卡堆最前,栈清空。
        XCTAssertEqual(state.deck.map(\.title), ["c"])
        XCTAssertNil(state.popAbandonForUndo())
        // 已处理集合里只剩 a / b(撤销只回滚 c)。
        XCTAssertEqual(state.abandonedStack.count, 0)
        XCTAssertEqual(state.processedIDs.count, 2)
    }

    func testSplitNotUndoable() {
        let state = ReviewFlowState(todos: [todo("big")])
        state.markSplit(state.deck[0])
        XCTAssertTrue(state.deck.isEmpty)
        XCTAssertNil(state.popAbandonForUndo())
    }

    // MARK: 步骤跳转(降级阶梯:<5 条完成 → 跳过洞察步)

    func testAdvanceSkipsInsightsWhenLadderSaysSo() {
        let state = ReviewFlowState(todos: [])
        state.currentStep = .triage
        state.insightContextValue = InsightContext(
            from: Date(), to: Date(),
            completedEvents: [], openTasks: [], dueTasks: [], deferCounts: [:]
        )
        state.configureInsightsLadder()
        XCTAssertTrue(state.skipsInsights)
        state.advance()
        XCTAssertEqual(state.currentStep, .commit)
        state.retreat()
        XCTAssertEqual(state.currentStep, .triage)
    }

    func testAdvanceKeepsInsightsWhenEnoughCompletions() {
        let state = ReviewFlowState(todos: [])
        state.currentStep = .triage
        let events = (0..<15).map { _ in InsightCompletedEvent(
            todoId: UUID(), createdAt: Date(), completedAt: Date(),
            category: .other, priority: .normal, hasDueTime: false, dueDate: nil
        )}
        state.insightContextValue = InsightContext(
            from: Date(), to: Date(),
            completedEvents: events, openTasks: [], dueTasks: [], deferCounts: [:]
        )
        state.configureInsightsLadder()
        XCTAssertFalse(state.skipsInsights)
        state.advance()
        XCTAssertEqual(state.currentStep, .insights)
    }

    // MARK: 账本计数

    func testLedgerCounts() {
        let state = ReviewFlowState(todos: (0..<6).map { todo("t\($0)") })
        // 先快照再逐个决定:markXxx 会从 deck 移除条目,索引会漂移。
        let items = state.deck
        state.markScheduled(items[0])
        state.markScheduled(items[1])
        state.markToday(items[2])
        state.markAbandoned(items[3])
        state.markSplit(items[4])
        state.toggleCommitSelection(state.scheduled[0])
        state.toggleCommitSelection(state.scheduled[1])

        let ledger = state.ledger
        XCTAssertEqual(ledger.inputCount, 6)
        XCTAssertEqual(ledger.remainingCount, 1)
        XCTAssertEqual(ledger.scheduledCount, 2)
        XCTAssertEqual(ledger.todayCount, 1)
        XCTAssertEqual(ledger.abandonedCount, 1)
        XCTAssertEqual(ledger.splitCount, 1)
        XCTAssertEqual(ledger.pinnedCount, 2)
    }

    // MARK: 深链聚焦

    func testBringToFrontOfDeck() {
        // 2026-09-01 拍板 2 后 init 会按停滞天数重排,同日创建的条目退化为
        // id 决胜——测试要固定顺序必须错开 createdAt(a 最久 → 排最前)。
        let state = ReviewFlowState(todos: [
            todo("a", daysOld: 30),
            todo("b", daysOld: 20),
            todo("c", daysOld: 10),
        ])
        XCTAssertEqual(state.deck.map(\.title), ["a", "b", "c"])
        state.bringToFrontOfDeck(state.deck[2].id)
        XCTAssertEqual(state.deck.map(\.title), ["c", "a", "b"])
        // 不在卡堆的 id:无操作。
        state.bringToFrontOfDeck(UUID())
        XCTAssertEqual(state.deck.map(\.title), ["c", "a", "b"])
    }
}

// MARK: - 阶段 4 · 会话组装 / 跨期对照数据源

extension ReviewFlowStateTests {

    private func reviewSession(
        completedAt: Date,
        voiceNote: String? = nil
    ) -> ReviewSession {
        ReviewSession(
            completedAt: completedAt,
            periodStart: completedAt,
            periodEnd: completedAt,
            voiceNote: voiceNote,
            ledger: ReviewLedger(
                inputCount: 1, remainingCount: 0, scheduledCount: 1, todayCount: 0,
                abandonedCount: 0, splitCount: 0, pinnedCount: 0
            ),
            shownInsights: []
        )
    }

    func testLastVoiceNoteFromMostRecentSession() {
        var state = ReviewFlowState(todos: [], previousSessions: [
            reviewSession(completedAt: Date(timeIntervalSinceNow: -86_400), voiceNote: "旧的"),
            reviewSession(completedAt: Date(), voiceNote: "  想把晚上留给八字 App  "),
        ])
        XCTAssertEqual(state.lastVoiceNote, "想把晚上留给八字 App")

        state = ReviewFlowState(todos: [], previousSessions: [
            reviewSession(completedAt: Date(), voiceNote: "   "),
        ])
        XCTAssertNil(state.lastVoiceNote, "空白回答视同没有")
    }

    /// `ReviewNotesEntry.make`(2026-08-23 拍板「全量可见」):空白过滤 / 新→旧 /
    /// 处理数取 ledger.inputCount。与 `lastVoiceNote` 同口径但不过滤条数。
    func testReviewNotesEntryMakeFiltersBlanksAndSortsNewestFirst() {
        let old = reviewSession(completedAt: Date(timeIntervalSinceNow: -7 * 86_400), voiceNote: "上周的话")
        let blank = reviewSession(completedAt: Date(timeIntervalSinceNow: -86_400), voiceNote: "  \n ")
        let newest = ReviewSession(
            completedAt: Date(),
            periodStart: Date(),
            periodEnd: Date(),
            voiceNote: "  这周想把上午留给重要的事  ",
            ledger: ReviewLedger(
                inputCount: 5, remainingCount: 0, scheduledCount: 1, todayCount: 0,
                abandonedCount: 0, splitCount: 0, pinnedCount: 0
            ),
            shownInsights: []
        )

        let entries = ReviewNotesEntry.make(from: [old, blank, newest])

        XCTAssertEqual(entries.map(\.id), [newest.id, old.id], "空白视同没有,其余新→旧")
        XCTAssertEqual(entries.map(\.note), ["这周想把上午留给重要的事", "上周的话"])
        XCTAssertEqual(entries.map(\.handledCount), [5, 1])
        XCTAssertTrue(ReviewNotesEntry.make(from: []).isEmpty)
    }

    func testBuildSessionMapsLedgerNoteAndInsights() {
        let now = Date()
        let state = ReviewFlowState(todos: [])
        let a = TodoItemData(title: "a")
        let b = TodoItemData(title: "b")
        let c = TodoItemData(title: "c")
        state.markScheduled(a)
        state.markToday(b)
        state.markAbandoned(c)
        state.toggleCommitSelection(a)
        state.recordShownInsight(InsightResult(
            id: .rotting, strength: .high, tone: .observation, headline: "h", body: "b",
            viz: .rotting(items: []), sampleNote: "n",
            score: 0.7, effectSize: 0.42, sampleCount: 30
        ))
        state.recordPeriod(start: now.addingTimeInterval(-86_400), end: now)
        state.voiceAnswerText = "  这周想把上午留给重要的事  "

        let session = state.buildSession(completedAt: now)

        XCTAssertEqual(session.voiceNote, "这周想把上午留给重要的事")
        XCTAssertEqual(session.shownInsights, [InsightSnapshot(id: .rotting, effectSize: 0.42, strength: .high)])
        XCTAssertEqual(session.ledger, ReviewLedger(
            inputCount: 3, remainingCount: 0, scheduledCount: 1, todayCount: 1,
            abandonedCount: 1, splitCount: 0, pinnedCount: 1
        ))
        XCTAssertEqual(session.periodStart, now.addingTimeInterval(-86_400))
        XCTAssertEqual(session.periodEnd, now)
    }

    func testRecordShownInsightUpsertsOnRetry() {
        let state = ReviewFlowState(todos: [])
        func result(effectSize: Double) -> InsightResult {
            InsightResult(id: .rotting, strength: .medium, tone: .observation, headline: "h",
                          body: "b", viz: .rotting(items: []), sampleNote: "n",
                          score: 0.5, effectSize: effectSize, sampleCount: 20)
        }
        state.recordShownInsight(result(effectSize: 0.4))
        state.recordShownInsight(result(effectSize: 0.6))

        XCTAssertEqual(state.shownInsights.count, 1)
        XCTAssertEqual(state.shownInsights.first?.effectSize, 0.6)
    }
}

// MARK: - 上次定的重点 / 领域提示(2026-08-25 轻修)

extension ReviewFlowStateTests {

    // MARK: 上次定的重点结局

    func testLastPinnedOutcomeNilWhenNoPins() {
        let state = ReviewFlowState(todos: [todo("a")])
        XCTAssertNil(state.lastPinnedOutcome, "上次没置顶过 → 结局行隐藏")
        XCTAssertTrue(state.lastPinnedIDs.isEmpty)
    }

    func testLastPinnedOutcomeCountsFromRawSnapshotNotDeck() {
        let done = todo("done", isCompleted: true)
        let open = todo("open")
        let recurringOpen = todo("recurring", recurring: true)
        let state = ReviewFlowState(
            todos: [done, open, recurringOpen],
            lastPinnedIDs: [done.id, open.id, recurringOpen.id]
        )
        // 完成的 done 不在 deck 里,但照样数得出来——计数基于原始快照而非 deck。
        // (生产中置顶池只可能含一次性任务:commit 候选 = scheduled,全部来自卡堆;
        // recurringOpen 进 pending 只是夹具造出来的边界,口径仍是纯 isCompleted 切分。)
        XCTAssertEqual(state.lastPinnedOutcome, .init(completed: 1, pending: 2))
    }

    func testLastPinnedOutcomeIgnoresDeletedIDs() {
        let open = todo("open")
        let deletedID = UUID()
        let state = ReviewFlowState(todos: [open], lastPinnedIDs: [open.id, deletedID])
        // 已删除的 id 两边都不计,数字与当前库对得上。
        XCTAssertEqual(state.lastPinnedOutcome, .init(completed: 0, pending: 1))
    }

    func testLastPinnedOutcomeNilWhenAllDeleted() {
        let state = ReviewFlowState(todos: [todo("other")], lastPinnedIDs: [UUID()])
        // 上次定的重点全删了 → 0/0 是误导噪音(读起来像一件没动),结局行隐藏。
        XCTAssertNil(state.lastPinnedOutcome)
    }

    // MARK: 领域提示轮换(2026-08-25 拍板:只在出现过的分类里轮换)

    func testAskDomainHintOnlyRotatesAmongPresentCategories() {
        let todos = [todo("w1", category: .work), todo("l1", category: .life)]
        // 只轮换出现过的分类,声明序稳定:seed 0/1/2/3 → work,life,work,life。
        // (study/health 等从未出现的分类永不出现。)
        let rotation = (0...3).map {
            ReviewFlowState.askDomainHintCategory(todos: todos, rotationSeed: $0)
        }
        XCTAssertEqual(rotation, [.work, .life, .work, .life])

        XCTAssertNil(ReviewFlowState.askDomainHintCategory(todos: [], rotationSeed: 0),
                     "空快照无分类可问 → 提示行隐藏")
    }

    func testAskDomainHintAdvancesWithSessionCount() {
        let todos = [todo("w1", category: .work), todo("l1", category: .life)]
        let first = ReviewFlowState(todos: todos)
        let second = ReviewFlowState(
            todos: todos,
            previousSessions: [reviewSession(completedAt: Date())]
        )
        // seed = 历史会话数:每次复盘前进一格。
        XCTAssertEqual(first.askDomainHintCategory, .work)
        XCTAssertEqual(second.askDomainHintCategory, .life)
    }
}

// MARK: - v2 · 排序截断 + 批量出口(2026-09-01 拍板 1/2/3,docs/todo-review-flow-v2.md)

extension ReviewFlowStateTests {

    /// 35 条积压:卡堆只取前 8,尾部 27;最该决定的(停滞最久)在卡堆最前。
    func testInitTruncatesDeckAndRanksByStagnation() {
        // t34 最久(35 天)、t0 最新(1 天):daysOld = index + 1。
        let todos = (0..<35).map { index in
            todo("t\(index)", daysOld: index + 1)
        }
        let state = ReviewFlowState(todos: todos)

        XCTAssertEqual(state.deck.count, TriageRanking.deckSize)
        XCTAssertEqual(state.tail.count, 35 - TriageRanking.deckSize)
        XCTAssertEqual(state.deck.first?.title, "t34", "停滞最久的排最前")
        XCTAssertEqual(state.tail.first?.title, "t26", "第 9 名起进尾部")
    }

    /// 不足 8 条:全部进卡堆,尾部空(批量出口整块不出)。
    func testInitKeepsSmallBacklogEntirelyInDeck() {
        let state = ReviewFlowState(todos: (0..<5).map { todo("t\($0)", daysOld: $0 + 1) })
        XCTAssertEqual(state.deck.count, 5)
        XCTAssertTrue(state.tail.isEmpty)
        XCTAssertTrue(state.somedayBatchCandidates.isEmpty)
        XCTAssertEqual(state.untouchedTailCount, 0)
    }

    /// insightContext 到位后重排:尾部高推迟条目顶进卡堆,原卡堆末位换到尾部
    /// (拍板 2 的时序要求——冷启动那帧排序是错的,必须重排)。
    func testRankDeckPromotesDeferredTailItem() {
        // 9 条:t8 最久(9 天)→ 卡堆,t0 最新(1 天)→ 尾部。
        let todos = (0..<9).map { index in todo("t\(index)", daysOld: index + 1) }
        let state = ReviewFlowState(todos: todos)
        XCTAssertEqual(state.tail.map(\.title), ["t0"])

        state.rankDeck(deferCounts: [state.tail[0].id: 5], now: Date())

        XCTAssertEqual(state.deck.first?.title, "t0", "推迟 5 次的尾部条目顶到最前")
        XCTAssertEqual(state.deck.count, TriageRanking.deckSize)
        XCTAssertEqual(state.tail.count, 1, "原卡堆末位换到尾部")

        // 已处理的条目不在 deck/tail,重排不回流——哪怕给它最高的推迟次数。
        let processed = state.deck[1]
        state.markScheduled(processed)
        state.rankDeck(deferCounts: [processed.id: 99], now: Date())
        XCTAssertFalse(state.deck.contains { $0.id == processed.id })
        XCTAssertFalse(state.tail.contains { $0.id == processed.id })
        XCTAssertEqual(state.processedIDs.count, 1)
    }

    /// 批量候选门槛:停滞 ≥ 30 天 **且** AI 识别成功(.parsed)。
    /// `.rawFallback` 清了三字段也只落「没能识别」,不进候选。
    /// 批量候选只看尾部(排序后第 9 名起),不满 8 条没有尾部也就没有候选。
    func testSomedayBatchCandidatesFilter() {
        // 8 条「更久」的占位把目标条目挤进尾部。
        let fillers = (0..<8).map { todo("filler\($0)", daysOld: 100 + $0) }
        let full = ReviewFlowState(todos: fillers + [
            todo("古董-parsed", daysOld: 40),
            todo("古董-rawFallback", daysOld: 40, extractionOutcome: .rawFallback),
            todo("古董-unparsed", daysOld: 40, extractionOutcome: .unparsed),
            todo("新-10天", daysOld: 10),
        ])

        XCTAssertEqual(full.somedayBatchCandidates.map(\.title), ["古董-parsed"])
        XCTAssertEqual(full.untouchedTailCount, 3, "rawFallback/unparsed 与 10 天的都原样留着")
    }

    /// 执行 → 整批撤销 的状态闭环:快照、计数、尾部进出;不进 processedIDs /
    /// abandonedStack(推后不是决定,也不是划掉)。
    func testSomedayBatchExecuteUndoRoundtrip() {
        let fillers = (0..<8).map { todo("filler\($0)", daysOld: 100 + $0) }
        let oldies = (0..<3).map { todo("old\($0)", daysOld: 40 + $0) }
        let state = ReviewFlowState(todos: fillers + oldies + [todo("新", daysOld: 5)])
        let batchIDs = Set(oldies.map(\.id))

        state.markSomedayBatchExecuted()
        XCTAssertEqual(state.somedayCount, 3)
        XCTAssertEqual(state.somedayUndoSnapshot?.count, 3)
        XCTAssertTrue(state.somedayBatchCandidates.isEmpty, "尾部已清,出口行消失")
        XCTAssertEqual(state.untouchedTailCount, 1, "不满 30 天的说明行还在")
        XCTAssertTrue(state.processedIDs.isEmpty)
        XCTAssertTrue(state.abandonedStack.isEmpty)
        XCTAssertEqual(state.ledger.somedayCount, 3)

        state.undoSomedayBatch()
        XCTAssertEqual(state.somedayCount, 0)
        XCTAssertNil(state.somedayUndoSnapshot)
        XCTAssertEqual(Set(state.somedayBatchCandidates.map(\.id)), batchIDs, "原字段条目回尾部")
        state.undoSomedayBatch() // 重复撤销:无操作
        XCTAssertEqual(state.somedayCount, 0)
    }

    /// buildSession 把 somedayCount 写进持久化账本。
    func testBuildSessionCarriesSomedayCount() {
        let fillers = (0..<8).map { todo("filler\($0)", daysOld: 100 + $0) }
        let state = ReviewFlowState(todos: fillers + [todo("old", daysOld: 40)])
        state.markSomedayBatchExecuted()

        let session = state.buildSession(completedAt: Date())
        XCTAssertEqual(session.ledger.somedayCount, 1)
    }

    /// 「决定了 N 件」= 逐张决定四去向之和;批量推后不算,划掉撤销会回退(拍板 4)。
    func testDecidedCountExcludesSomedayAndRespectsUndo() {
        let state = ReviewFlowState(todos: [
            todo("a", daysOld: 30), todo("b", daysOld: 20),
            todo("c", daysOld: 10), todo("d", daysOld: 5),
        ])
        XCTAssertEqual(state.decidedCount, 0, "全零——收尾主卡不出")

        let items = state.deck
        state.markScheduled(items[0])
        state.markToday(items[1])
        state.markAbandoned(items[2])
        XCTAssertEqual(state.decidedCount, 3)

        // 划掉撤销:决定数回退(撤销栈是净额)。
        _ = state.popAbandonForUndo()
        XCTAssertEqual(state.decidedCount, 2)

        // 批量推后不进决定数。
        let fillers = (0..<8).map { todo("filler\($0)", daysOld: 100 + $0) }
        let batchState = ReviewFlowState(todos: fillers + (0..<3).map { todo("old\($0)", daysOld: 40 + $0) })
        batchState.markSomedayBatchExecuted()
        XCTAssertEqual(batchState.decidedCount, 0)
        XCTAssertEqual(batchState.ledger.somedayCount, 3)
    }

    /// 旧 payload(无 somedayCount 键)解码 → 默认 0;混排列表不拖垮整体。
    /// 失败半径:自动合成的 Codable 遇缺键是抛错,一条失败会污染整个
    /// allSessions(),自定义 init(from:) 兜底(docs v2 实施补注)。
    func testReviewLedgerDecodesOldPayloadWithoutSomedayCount() throws {
        let oldJSON = """
        {"inputCount":3,"remainingCount":1,"scheduledCount":1,"todayCount":1,
        "abandonedCount":0,"splitCount":0,"pinnedCount":1}
        """
        let old = try JSONDecoder().decode(ReviewLedger.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(old.somedayCount, 0)
        XCTAssertEqual(old.inputCount, 3)

        // 新 payload 正常读出。
        let newJSON = """
        {"inputCount":3,"remainingCount":1,"scheduledCount":1,"todayCount":1,
        "abandonedCount":0,"splitCount":0,"pinnedCount":1,"somedayCount":27}
        """
        let new = try JSONDecoder().decode(ReviewLedger.self, from: Data(newJSON.utf8))
        XCTAssertEqual(new.somedayCount, 27)

        // 编码往返:新字段写入后再读不丢。
        let roundtrip = try JSONDecoder().decode(
            ReviewLedger.self, from: JSONEncoder().encode(new)
        )
        XCTAssertEqual(roundtrip, new)
    }
}

// MARK: - v2 · 第 4 步候选池并集(2026-09-01 拍板,docs/todo-review-flow-v2.md)

extension ReviewFlowStateTests {

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func at(_ year: Int, _ month: Int, _ day: Int) -> Date {
        fixedCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// 窗口语义:下一个周一(2026-09-07,周三参照)起 7 天,闭开区间;
    /// 与「排下周」写库落点同坐标系。本周/下下周/无日期都不进。
    func testNextWeekCommittedWindow() {
        // 2026-09-02 是周三 → 下一个周一是 09-07,窗口 [09-07, 09-14)。
        let now = at(2026, 9, 2)
        let input = [
            todo("本周四", dueDate: at(2026, 9, 3)),
            todo("下周一", dueDate: at(2026, 9, 7)),
            todo("下周日", dueDate: at(2026, 9, 13)),
            todo("下下周一", dueDate: at(2026, 9, 14)),
            todo("无日期"),
            todo("下周但已完成", isCompleted: true, dueDate: at(2026, 9, 9)),
        ]
        let committed = ReviewFlowState.nextWeekCommitted(
            from: input, now: now, calendar: fixedCalendar
        )
        XCTAssertEqual(committed.map(\.title), ["下周一", "下周日"])
    }

    /// 候选池并集 + 去重:本来就在下周的未处理条目进池;本会话「今天就做/
    /// 不做了/拆小」处理过的下周条目退出;右滑即时写库不产生双行(审阅缺口 B)。
    func testCommitPoolUnionsAndDedups() {
        let calendar = Calendar.current
        let nextMonday = calendar.nextDate(
            after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime
        )!
        let nextWednesday = calendar.date(byAdding: .day, value: 2, to: nextMonday)!
        let state = ReviewFlowState(todos: [
            todo("本来就在下周", daysOld: 20, dueDate: nextWednesday),
            todo("swipeA", daysOld: 15),
            todo("swipeB", daysOld: 10),
            todo("今天做-原本在下周", daysOld: 8, dueDate: nextWednesday),
            todo("划掉-原本在下周", daysOld: 6, dueDate: nextWednesday),
        ])

        // 第 2 步:右滑两张 + 今天一张 + 划掉一张(按标题取,避免顺序假设)。
        func deckItem(_ title: String) -> TodoItemData {
            state.deck.first { $0.title == title }!
        }
        state.markScheduled(deckItem("swipeA"))
        state.markScheduled(deckItem("swipeB"))
        state.markToday(deckItem("今天做-原本在下周"))
        state.markAbandoned(deckItem("划掉-原本在下周"))

        XCTAssertEqual(state.scheduled.map(\.title).sorted(), ["swipeA", "swipeB"])
        XCTAssertEqual(state.preexistingNextWeek.map(\.title), ["本来就在下周"])
        XCTAssertEqual(state.commitPool.count, 3, "2 张刚排 + 1 张本来就在,无重复")
        XCTAssertFalse(state.commitPool.contains { $0.title == "今天做-原本在下周" })
        XCTAssertFalse(state.commitPool.contains { $0.title == "划掉-原本在下周" })
    }

    /// 闸门随池子走:第 2 步整步跳过(scheduled 空)但下周本有排期时,
    /// 空池死路消失——池子非空,至少选 1 件(2026-08-22 闸门口径不变)。
    func testCommitGateWithPreexistingOnly() {
        let calendar = Calendar.current
        let nextMonday = calendar.nextDate(
            after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime
        )!
        let state = ReviewFlowState(todos: [todo("本来就在下周", daysOld: 20, dueDate: nextMonday)])

        XCTAssertTrue(state.scheduled.isEmpty, "前提:第 2 步没排任何一张")
        XCTAssertFalse(state.commitPool.isEmpty)
        XCTAssertFalse(state.canPassCommit, "池子非空 → 至少选 1 件")
        state.toggleCommitSelection(state.commitPool[0])
        XCTAssertTrue(state.canPassCommit)
    }
}
