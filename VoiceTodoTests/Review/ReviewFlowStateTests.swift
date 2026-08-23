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
        recurring: Bool = false
    ) -> TodoItemData {
        TodoItemData(
            title: title,
            recurrenceRule: recurring ? RecurrenceRule(frequency: .daily) : nil,
            isCompleted: isCompleted,
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
        let state = ReviewFlowState(todos: [todo("a"), todo("b"), todo("c")])
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
        let state = ReviewFlowState(todos: [todo("a"), todo("b"), todo("c")])
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
