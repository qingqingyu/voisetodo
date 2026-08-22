import SwiftUI
import Observation

// MARK: - 流程状态

/// 五步复盘流程的全部决定(阶段 3,docs/todo-review-flow-design.md「阶段 3」)。
///
/// 步骤间数据流动全走本类(`@Observable`):排进下周的 / 划掉的 / 拆小的 /
/// 存下的规则 / 选中的三件事 / 账本数字。第 5 步(账本)与阶段 4 的会话持久化
/// 都从这里取数,不在各步视图里各自记账。
///
/// 纯逻辑部分(triage 输入过滤、步骤闸门、撤销栈、账本计数)不依赖 SwiftUI,
/// 供 `VoiceTodoTests` 直测。
@MainActor
@Observable
final class ReviewFlowState {
    // MARK: 步骤

    enum Step: Int, CaseIterable, Sendable {
        case recap = 0
        case triage = 1
        case insights = 2
        case commit = 3
        case ledger = 4
    }

    /// 测试可直设(导航入口统一走 advance/retreat);UI 侧只读。
    var currentStep: Step = .recap
    /// 洞察步是否被降级阶梯跳过(<5 条完成记录 → 第 2 步直连第 4 步,§2.3)。
    /// 在流程启动拿到 insightContext 后设定;「上一步」同理跳过。
    private(set) var skipsInsights = false

    // MARK: 第 2 步 · 卡片堆

    /// triage 输入快照:未完成 && abandonedAt == nil && recurrenceRule == nil 的
    /// 一次性任务(拍板 4)。流程启动时过滤一次,之后 store 变动(如拆小产生的
    /// 子任务)不回流进卡堆,避免「拆完子任务又弹出子任务卡」。
    private(set) var deck: [TodoItemData]

    /// 已处理(排进下周 / 今天就做 / 划掉 / 拆小)的 todo id 集。
    private(set) var processedIDs: Set<UUID> = []

    /// 排进下周的任务(第 4 步的候选池,保留标题供账本渲染)。
    private(set) var scheduled: [TodoItemData] = []
    /// 「今天就做」的任务(不进第 4 步候选——候选只从「排进下周的」里挑)。
    private(set) var todayPicked: [TodoItemData] = []
    /// 划掉撤销栈(拍板 7:undo 只覆盖划掉)。栈顶是最近一次划掉。
    private(set) var abandonedStack: [TodoItemData] = []
    /// 拆小计数(账本用)。拆小的 undo 不提供(成本高,拍板 7)。
    private(set) var splitCount = 0

    /// 洞察步「跳回第 2 步对应卡片」的聚焦 id(腐烂卡点击设置,triage 步消费后清空)。
    var triageFocusID: UUID?

    // MARK: 第 3 步 · 观察

    /// 洞察原料(流程启动 `.task` 里 await 一次存进来,不放 body,§1.4)。
    var insightContextValue: InsightContext?
    /// 洞察步加载原料失败的显式错误态(不静默:展示错误 + 重试入口)。
    var insightLoadError: VoiceTodoError?
    /// 语音提问的文字回答。
    var voiceAnswerText = ""

    // MARK: 历史会话(阶段 4)

    /// 历史会话(`ReviewSessionStore.allSessions()`,升序)。冷却判定 / 跨期对照卡
    /// 的数据源。流程启动时注入一次,之后不变。
    private(set) var previousSessions: [ReviewSession]
    /// 本期洞察原料的取数区间(`loadInsightContext` 写入,session 落库带上)。
    private(set) var periodStart: Date = Date()
    private(set) var periodEnd: Date = Date()
    /// 第 3 步实际展示过的洞察快照(冷却历史;降级跳过时为空)。
    private(set) var shownInsights: [InsightSnapshot] = []

    // MARK: 第 4/5 步

    /// 第 4 步选中的「三件事」(提交置顶时读取)。
    private(set) var commitSelection: [TodoItemData] = []

    // MARK: Init

    /// - Parameters:
    ///   - todos: store 工作集快照(`store.todos`)。内部按 triage 口径过滤。
    ///   - previousSessions: 历史复盘会话(升序;阶段 4 冷却 / 跨期对照用,
    ///     注入而非自取,保持本类纯逻辑可测)。
    init(todos: [TodoItemData], previousSessions: [ReviewSession] = []) {
        self.deck = Self.triageInput(from: todos)
        self.previousSessions = previousSessions
    }

    /// triage 输入过滤(拍板 4):未完成 && 未划掉 && 一次性(recurrenceRule == nil)。
    static func triageInput(from todos: [TodoItemData]) -> [TodoItemData] {
        todos.filter { !$0.isCompleted && $0.abandonedAt == nil && $0.recurrenceRule == nil }
    }

    // MARK: 步骤闸门

    /// 第 4 步(下周三件事)主按钮闸门(2026-08-22 拍板放宽):**至少选 1 件**,
    /// 文案仍鼓励选满 3——强制凑满 3 件会把「只想清卡堆」的用户卡在半路,
    /// 养复盘习惯比单次产出更重要。候选池为空(一张都没排进下周)时无从
    /// 选起,放行——强迫回去排 3 件违背复盘自愿原则(§2.5 反 gaming)。
    var canPassCommit: Bool {
        scheduled.isEmpty || !commitSelection.isEmpty
    }

    /// 当前步骤主按钮是否可点。recap / triage / insights / ledger 恒可过
    /// (triage 允许一张不处理——「都留着」也是合法决定);只有 commit 有硬闸门。
    var canAdvanceCurrentStep: Bool {
        switch currentStep {
        case .commit: return canPassCommit
        default: return true
        }
    }

    // MARK: 导航

    /// 下一步。insights 在 skipsInsights 时被跳过。
    func advance() {
        let candidates = (currentStep.rawValue + 1)...Step.ledger.rawValue
        guard let raw = candidates.first else { return }
        var next = Step(rawValue: raw)!
        if next == .insights, skipsInsights { next = .commit }
        currentStep = next
    }

    /// 上一步。insights 在 skipsInsights 时被跳过。
    func retreat() {
        guard let raw = (Step.recap.rawValue..<currentStep.rawValue).last else { return }
        var prev = Step(rawValue: raw)!
        if prev == .insights, skipsInsights { prev = .triage }
        currentStep = prev
    }

    /// 洞察原料就绪后设定降级阶梯(§2.3)。<5 条完成记录 → 整步跳过。
    func configureInsightsLadder() {
        let completedCount = insightContextValue?.completedEvents.count ?? 0
        skipsInsights = InsightEngine.ladder(completedRecordCount: completedCount) == .skipStep
    }

    // MARK: 第 2 步决定

    /// 右滑 → 排进下周(dueDate 写入在视图层走 store.updateFull,origin = .review)。
    func markScheduled(_ todo: TodoItemData) {
        processedIDs.insert(todo.id)
        scheduled.append(todo)
        removeFromDeck(todo.id)
    }

    /// 「今天就做」。不进第 4 步候选池。
    func markToday(_ todo: TodoItemData) {
        processedIDs.insert(todo.id)
        todayPicked.append(todo)
        removeFromDeck(todo.id)
    }

    /// 左滑 → 划掉。入撤销栈(拍板 7:undo 只覆盖划掉)。
    func markAbandoned(_ todo: TodoItemData) {
        processedIDs.insert(todo.id)
        abandonedStack.append(todo)
        removeFromDeck(todo.id)
    }

    /// 拆小提交成功后调用。原任务不进撤销栈(拆小不提供 undo,拍板 7)。
    func markSplit(_ todo: TodoItemData) {
        processedIDs.insert(todo.id)
        splitCount += 1
        removeFromDeck(todo.id)
    }

    /// 撤销最近一次划掉(unabandon 写库在视图层)。返回被撤销的任务,nil = 栈空。
    func popAbandonForUndo() -> TodoItemData? {
        guard let todo = abandonedStack.popLast() else { return nil }
        processedIDs.remove(todo.id)
        deck.insert(todo, at: 0)
        return todo
    }

    private func removeFromDeck(_ id: UUID) {
        deck.removeAll { $0.id == id }
    }

    /// 洞察腐烂卡深链聚焦:把对应卡片稳定换到卡堆最前(不在卡堆时无操作——
    /// 已处理过的任务没有「对应卡片」可跳)。
    func bringToFrontOfDeck(_ id: UUID) {
        guard let index = deck.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let todo = deck.remove(at: index)
        deck.insert(todo, at: 0)
    }

    // MARK: 第 4 步决定

    /// 第 4 步选择切换。选中数已达上限(3)时切换到取消态仍允许(取消不受限)。
    func toggleCommitSelection(_ todo: TodoItemData) {
        if let index = commitSelection.firstIndex(where: { $0.id == todo.id }) {
            commitSelection.remove(at: index)
        } else if commitSelection.count < 3 {
            commitSelection.append(todo)
        }
    }

    // MARK: 第 5 步 · 账本

    /// 账本数字(第 5 步渲染,阶段 4 持久化)。
    struct Ledger: Equatable, Sendable {
        /// 流程开始时的待处理一次性任务数(N)。
        let inputCount: Int
        /// 处理后仍留在卡堆的(M,含撤销回来的)。
        let remainingCount: Int
        let scheduledCount: Int
        let abandonedCount: Int
        let splitCount: Int
        let todayCount: Int
        let pinnedCount: Int
    }

    var ledger: Ledger {
        Ledger(
            inputCount: processedIDs.count + deck.count,
            remainingCount: deck.count,
            scheduledCount: scheduled.count,
            abandonedCount: abandonedStack.count,
            splitCount: splitCount,
            todayCount: todayPicked.count,
            pinnedCount: commitSelection.count
        )
    }

    // MARK: 阶段 4 · 会话组装

    /// 清空展示快照(runEngine 每次重跑前调用):重试 / 原料重载后,上一轮展示过
    /// 但这一轮被冷却过滤的洞察不该留在历史里——没展示的不进 `shownInsights`。
    func resetShownInsights() {
        shownInsights = []
    }

    /// 记录一条本期展示过的洞察(第 3 步 runEngine 对每张实际展示的卡调用;
    /// 被冷却过滤掉的不记——没展示的不该进冷却历史)。upsert:重试 / 原料重载
    /// 会让 runEngine 再跑一遍,同一洞察只留最后一份快照。
    func recordShownInsight(_ result: InsightResult) {
        let snapshot = InsightSnapshot(id: result.id, effectSize: result.effectSize, strength: result.strength)
        if let index = shownInsights.firstIndex(where: { $0.id == snapshot.id }) {
            shownInsights[index] = snapshot
        } else {
            shownInsights.append(snapshot)
        }
    }

    /// 记录本期取数区间(`loadInsightContext` 调用)。
    func recordPeriod(start: Date, end: Date) {
        periodStart = start
        periodEnd = end
    }

    /// 上次复盘的「问问自己」回答(跨期对照卡数据源)。空白视同没有。
    var lastVoiceNote: String? {
        guard let note = previousSessions.last?.voiceNote?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    /// 收尾落库:从 State 组装 `ReviewSession`(`ReviewLedger` 从 `ledger` 映射)。
    /// 纯函数,`VoiceTodoTests` 直测账本 → session 的映射。
    func buildSession(completedAt: Date) -> ReviewSession {
        let ledger = ledger
        let trimmedNote = voiceAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewSession(
            completedAt: completedAt,
            periodStart: periodStart,
            periodEnd: periodEnd,
            voiceNote: trimmedNote.isEmpty ? nil : trimmedNote,
            ledger: ReviewLedger(
                inputCount: ledger.inputCount,
                remainingCount: ledger.remainingCount,
                scheduledCount: ledger.scheduledCount,
                todayCount: ledger.todayCount,
                abandonedCount: ledger.abandonedCount,
                splitCount: ledger.splitCount,
                pinnedCount: ledger.pinnedCount
            ),
            shownInsights: shownInsights
        )
    }
}

// MARK: - 流程容器

/// 五步复盘流程容器(阶段 3):步骤条、底部主按钮、步骤转场。
///
/// 数据流:`ReviewFlowState` 持本次全部决定;store 写入(dueDate / abandon /
/// split)在视图侧 do-catch,失败走 `coordinator.handleError`(显式 toast,不静默)。
/// 撤销只覆盖划掉(拍板 7);置顶走 `ReviewPinningStore`(拍板 6,不动 sortOrder)。
struct ReviewFlowView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let store: any ReviewFlowStore

    @State private var state: ReviewFlowState

    init(store: any ReviewFlowStore) {
        self.store = store
        // 工作集快照在 init 一次取齐:卡堆输入不随后续 store 写入回流
        // (拆小产生的子任务不该再弹回卡堆)。历史会话同批注入(冷却 /
        // 跨期对照的数据源,阶段 4)。
        _state = State(initialValue: ReviewFlowState(
            todos: store.todos,
            previousSessions: ReviewSessionStore.shared.allSessions()
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(spacing: 0) {
                    stepBar
                        .padding(.horizontal, WarmSpacing.lg)
                        .padding(.top, WarmSpacing.sm)

                    stepContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    bottomBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if state.currentStep == .recap {
                            dismiss()
                        } else {
                            withAnimation(WarmAnimation.springStandard) {
                                state.retreat()
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .accessibilityIdentifier("ReviewFlowBack")
                }
                ToolbarItem(placement: .principal) {
                    Text(stepTitle)
                        .font(WarmFont.headline(15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("ReviewFlowClose")
                }
            }
        }
        .task { await loadInsightContext() }
    }

    // MARK: 数据加载

    /// 洞察原料在流程启动时 await 一次(§1.4:不放 body)。失败显式记错误态,
    /// 洞察步展示错误 + 重试;triage 的推迟斜杠降级为「记下 N 天了」,不静默。
    private func loadInsightContext() async {
        let today = Date()
        let start = Calendar.current.date(byAdding: .month, value: -1, to: DayClock.startOfUserDay(for: today)) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: DayClock.startOfUserDay(for: today)) ?? today
        do {
            state.insightContextValue = try await store.insightContext(from: start, to: end)
            state.insightLoadError = nil
            state.recordPeriod(start: start, end: end)
            state.configureInsightsLadder()
        } catch {
            let wrapped = (error as? VoiceTodoError) ?? VoiceTodoError.wrapStorage(error, for: .read)
            VoiceTodoLog.coordinator.error("review.flow.insight_load.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            state.insightLoadError = wrapped
        }
    }

    // MARK: 错误呈现

    /// 流程内 store 写入失败的显式呈现(错误显式传播:日志 + toast,不静默)。
    /// 复盘里的写失败都是存储类错误,统一走 `ErrorMessages.storageError` 文案。
    private func presentError(_ error: Error) {
        VoiceTodoLog.coordinator.error("review.flow.store_op.failed step=\(state.currentStep.rawValue) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
    }

    // MARK: 步骤渲染

    private var stepTitle: String {
        switch state.currentStep {
        case .recap: return String(localized: "review.flow.step.recap")
        case .triage: return String(localized: "review.flow.step.triage")
        case .insights: return String(localized: "review.flow.step.insights")
        case .commit: return String(localized: "review.flow.step.commit")
        case .ledger: return String(localized: "review.flow.step.ledger")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch state.currentStep {
        case .recap:
            ReviewStepRecap()
        case .triage:
            ReviewStepTriage(
                state: state,
                store: store,
                onError: { presentError($0) },
                onUndoToast: { coordinator.showToast(message: $0, style: .info) }
            )
        case .insights:
            ReviewStepInsights(
                state: state,
                onRetryInsights: { Task { await loadInsightContext() } },
                onJumpToTriage: {
                    withAnimation(WarmAnimation.springStandard) {
                        state.retreat(toTriage: true)
                    }
                }
            )
        case .commit:
            ReviewStepCommit(state: state)
        case .ledger:
            ReviewStepLedger(state: state)
        }
    }

    /// 步骤条:5 段胶囊,当前及已过的段填充主色。insights 被跳过时该段显示为跳过态。
    private var stepBar: some View {
        HStack(spacing: WarmSpacing.xxs) {
            ForEach(ReviewFlowState.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(stepBarFill(step))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func stepBarFill(_ step: ReviewFlowState.Step) -> Color {
        if step == .insights && state.skipsInsights {
            return WarmTheme.divider.opacity(0.5)
        }
        return step.rawValue <= state.currentStep.rawValue
            ? WarmTheme.primary
            : WarmTheme.divider
    }

    // MARK: 底部主按钮

    @ViewBuilder
    private var bottomBar: some View {
        Button {
            advanceFromCurrentStep()
        } label: {
            Text(bottomButtonTitle)
                .font(WarmFont.headline(16))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: WarmSize.touch)
                .padding(.horizontal, WarmSpacing.lg)
                .background(
                    Capsule().fill(
                        state.canAdvanceCurrentStep ? WarmTheme.primary : WarmTheme.divider
                    )
                )
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.bottom, WarmSpacing.md)
        }
        .buttonStyle(.plain)
        .disabled(!state.canAdvanceCurrentStep)
        .accessibilityIdentifier("ReviewFlowPrimary")
    }

    private var bottomButtonTitle: String {
        switch state.currentStep {
        case .ledger: return String(localized: "review.flow.done")
        default: return String(localized: "review.flow.next")
        }
    }

    private func advanceFromCurrentStep() {
        if state.currentStep == .ledger {
            finishSession()
            return
        }
        // 第 4 步过闸时落地置顶(拍板 6:独立标记,不动 sortOrder)。
        if state.currentStep == .commit {
            ReviewPinningStore.shared.setPinned(Set(state.commitSelection.map(\.id)))
        }
        withAnimation(WarmAnimation.springStandard) {
            state.advance()
        }
    }

    // MARK: 收尾落库(阶段 4)

    /// 第 5 步「完成」:组装 session 落库 + 用**全量**任务 id
    /// prune 置顶集合(`TodoIDListing`,不用窗口化 `store.todos`——窗口外的置顶
    /// id 会被误删)。prune 与落库都走 UserDefaults 同步写,失败显式记日志
    /// (error/warning)不阻塞收尾;流程内的 store 写失败另有 toast(见 presentError)。
    private func finishSession() {
        let session = state.buildSession(completedAt: Date())
        ReviewSessionStore.shared.append(session)
        Task { @MainActor in
            do {
                let allIDs = Set(try await store.allTodoIDs())
                ReviewPinningStore.shared.prune(existingIDs: allIDs)
            } catch {
                VoiceTodoLog.coordinator.error("review.flow.finish.prune_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
        dismiss()
    }
}

extension ReviewFlowState {
    /// 洞察卡「跳回第 2 步对应卡片」(§阶段 3:指出腐烂却不给处理入口是最糟的设计)。
    /// 集中在 State 上而不是直接改 currentStep,让导航规则单一来源。
    func retreat(toTriage: Bool) {
        guard toTriage else { return }
        currentStep = .triage
    }
}
