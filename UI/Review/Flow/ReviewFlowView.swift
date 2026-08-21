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
    /// 语音提问的文字回答(阶段 4 持久化,本阶段只存 State)。
    var voiceAnswerText = ""

    // MARK: 第 4/5 步

    /// 本次存下的规则(规则按钮 → 第 4 步展示 → 账本计数;持久化在阶段 4)。
    private(set) var savedRules: [ReviewRule] = []
    /// 第 4 步选中的「三件事」(提交置顶时读取)。
    private(set) var commitSelection: [TodoItemData] = []

    // MARK: Init

    /// - Parameter todos: store 工作集快照(`store.todos`)。内部按 triage 口径过滤。
    init(todos: [TodoItemData]) {
        self.deck = Self.triageInput(from: todos)
    }

    /// triage 输入过滤(拍板 4):未完成 && 未划掉 && 一次性(recurrenceRule == nil)。
    static func triageInput(from todos: [TodoItemData]) -> [TodoItemData] {
        todos.filter { !$0.isCompleted && $0.abandonedAt == nil && $0.recurrenceRule == nil }
    }

    // MARK: 步骤闸门

    /// 第 4 步(下周三件事)主按钮闸门:**不选够不给过**。
    /// 应选数 = min(3, 排进下周的任务数);候选为空时(用户一张都没排)
    /// 无从选起,放行——强迫用户回去排 3 件违背复盘自愿原则(§2.5 反 gaming)。
    var commitRequiredCount: Int {
        min(3, scheduled.count)
    }

    var canPassCommit: Bool {
        commitSelection.count == commitRequiredCount
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

    // MARK: 第 3/4 步决定

    /// 存下一条规则(同一条洞察重复存会去重——按 insightID 一条洞察只留一规则)。
    func saveRule(_ rule: ReviewRule) {
        if !savedRules.contains(where: { $0.insightID == rule.insightID }) {
            savedRules.append(rule)
        }
    }

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
        let savedRuleCount: Int
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
            savedRuleCount: savedRules.count,
            pinnedCount: commitSelection.count
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
        // (拆小产生的子任务不该再弹回卡堆)。
        _state = State(initialValue: ReviewFlowState(todos: store.todos))
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
            dismiss()
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
}

extension ReviewFlowState {
    /// 洞察卡「跳回第 2 步对应卡片」(§阶段 3:指出腐烂却不给处理入口是最糟的设计)。
    /// 集中在 State 上而不是直接改 currentStep,让导航规则单一来源。
    func retreat(toTriage: Bool) {
        guard toTriage else { return }
        currentStep = .triage
    }
}
