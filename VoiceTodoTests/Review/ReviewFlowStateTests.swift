import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `ReviewFlowState` 纯逻辑验收(阶段 3):
/// triage 输入过滤 / 步骤闸门(不选够不过)/ 撤销栈(只覆盖划掉)/ 账本计数。
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

    // MARK: 步骤闸门(不选够不给过)

    func testCommitGateBlocksUntilRequiredCountSelected() {
        let state = ReviewFlowState(todos: (0..<5).map { todo("t\($0)") })
        // 没有任何决定时:候选池空 → 闸门放行(无从选起,见 State 注释)。
        XCTAssertTrue(state.canPassCommit)

        for item in state.deck { state.markScheduled(item) }
        // 候选 5 条 → 应选 3 件;0/1/2 件都不过。
        XCTAssertEqual(state.commitRequiredCount, 3)
        state.toggleCommitSelection(state.scheduled[0])
        XCTAssertFalse(state.canPassCommit)
        state.toggleCommitSelection(state.scheduled[1])
        XCTAssertFalse(state.canPassCommit)
        state.toggleCommitSelection(state.scheduled[2])
        XCTAssertTrue(state.canPassCommit)
        // 第 4 件:已达上限,不可再选。
        state.toggleCommitSelection(state.scheduled[3])
        XCTAssertEqual(state.commitSelection.count, 3)
        XCTAssertTrue(state.canPassCommit)
    }

    func testCommitGateWhenFewerThanThreeScheduled() {
        let state = ReviewFlowState(todos: [todo("a"), todo("b")])
        let items = state.deck
        state.markScheduled(items[0])
        state.markScheduled(items[1])
        XCTAssertEqual(state.commitRequiredCount, 2)
        state.toggleCommitSelection(state.scheduled[0])
        XCTAssertFalse(state.canPassCommit)
        state.toggleCommitSelection(state.scheduled[1])
        XCTAssertTrue(state.canPassCommit)
    }

    func testToggleCommitSelectionDeselectsBeyondCap() {
        let state = ReviewFlowState(todos: (0..<4).map { todo("t\($0)") })
        for item in state.deck { state.markScheduled(item) }
        for item in state.scheduled.prefix(3) { state.toggleCommitSelection(item) }
        // 取消选中的第一件 → 回到 2 件,闸门重新关上。
        state.toggleCommitSelection(state.scheduled[0])
        XCTAssertEqual(state.commitSelection.count, 2)
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
        state.saveRule(ReviewRule(insightID: .rotting, text: "r", createdAt: Date()))
        state.toggleCommitSelection(state.scheduled[0])
        state.toggleCommitSelection(state.scheduled[1])

        let ledger = state.ledger
        XCTAssertEqual(ledger.inputCount, 6)
        XCTAssertEqual(ledger.remainingCount, 1)
        XCTAssertEqual(ledger.scheduledCount, 2)
        XCTAssertEqual(ledger.todayCount, 1)
        XCTAssertEqual(ledger.abandonedCount, 1)
        XCTAssertEqual(ledger.splitCount, 1)
        XCTAssertEqual(ledger.savedRuleCount, 1)
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

    // MARK: 规则去重

    func testSaveRuleDeduplicatesByInsightID() {
        let state = ReviewFlowState(todos: [])
        state.saveRule(ReviewRule(insightID: .rotting, text: "a", createdAt: Date()))
        state.saveRule(ReviewRule(insightID: .rotting, text: "b", createdAt: Date()))
        state.saveRule(ReviewRule(insightID: .reactiveVsPlanned, text: "c", createdAt: Date()))
        XCTAssertEqual(state.savedRules.count, 2)
        XCTAssertEqual(state.savedRules.first { $0.insightID == .rotting }?.text, "a")
    }
}
