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
    /// 2026-09-01 拍板 1:排序后只取前 `TriageRanking.deckSize` 张;第 9 名以后
    /// 进 `tail`(批量出口候选 / 原样留着)。
    private(set) var deck: [TodoItemData]

    /// 排序尾部(不进卡堆,docs v2「第 2 步」):其中停滞 ≥ 30 天且 AI 识别成功
    /// 的走批量出口,其余既不进卡堆也不进批量出口——「不动」也是合法状态,
    /// UI 必须把这个说清楚,否则用户以为「其他都被处理了」。
    private(set) var tail: [TodoItemData] = []

    /// 最近一次批量推「稍后」的原字段快照(整批撤销,拍板 7 的唯一扩展:
    /// 一键操作没有 undo 不可接受)。nil = 本期尚未执行。一次性——撤销后清空。
    private(set) var somedayUndoSnapshot: [TodoItemData]?

    /// 本期批量推「稍后」的累计条数(账本单独一行「另有 M 件推到以后」,
    /// 不并进「决定了 N 件」,拍板 4)。
    private(set) var somedayCount = 0

    /// 已处理(排进下周 / 今天就做 / 划掉 / 拆小)的 todo id 集。
    /// 批量推「稍后」**不进**此集——推后不是逐张决定,不占决定数。
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

    /// 本来就排在下周的未完成任务(2026-09-01 拍板「第 4 步」:候选池不能
    /// 只有刚才排的——第 2 步被跳过时池子照样有内容,空池死路消失)。
    /// init 快照口径:`dueDate` 落在下周 && `!isCompleted` && `abandonedAt == nil`。
    /// 不按 recurrenceRule 排除(文档字面口径):锚点在过去的规律任务自然
    /// 不命中;锚点恰在下周的允许被置顶——置顶标记按 id 对账,语义成立。
    /// ⚠️ 右滑「排下周」是即时写库,但快照取自 init——第 2 步新排的走
    /// `scheduled`,两路靠 `processedIDs` 去重(不去重会双行)。
    private(set) var nextWeekCommitted: [TodoItemData] = []

    // MARK: 上次定的重点(2026-08-25 轻修:plan-do-review 闭环)

    /// 上次复盘第 4 步置顶的 todo id(流程启动时快照注入)。`ReviewPinningStore
    /// .setPinned` 整体覆写、`prune` 只清已删 id——新会话启动时集合恰好就是
    /// 上次定的那批。注入而非自取,保持本类纯逻辑可测。
    private(set) var lastPinnedIDs: Set<UUID>

    /// 上次定的重点在本期快照里的结局(nil = 上次没置顶过,第 1 步结局行隐藏)。
    private(set) var lastPinnedOutcome: LastPinnedOutcome?

    /// 上次定的重点的结局(第 1 步结局行的数据源)。
    struct LastPinnedOutcome: Equatable, Sendable {
        /// 已完成(不在卡堆里,只能从原始快照数出来)。
        let completed: Int
        /// 仍未完成(会再次出现在第 2 步卡堆里,带「上次重点」标记)。
        let pending: Int
    }

    /// 「问问自己」的领域提示分类(nil = 快照里没有任何分类可问,提示行隐藏)。
    private(set) var askDomainHintCategory: TodoCategory?

    // MARK: Init

    /// - Parameters:
    ///   - todos: store 工作集快照(`store.todos`)。内部按 triage 口径过滤。
    ///   - previousSessions: 历史复盘会话(升序;阶段 4 冷却 / 跨期对照用,
    ///     注入而非自取,保持本类纯逻辑可测)。
    ///   - lastPinnedIDs: 上次复盘置顶的 id 集(第 2 步卡堆标记 + 第 1 步结局行用)。
    init(
        todos: [TodoItemData],
        previousSessions: [ReviewSession] = [],
        lastPinnedIDs: Set<UUID> = []
    ) {
        // 冷启动帧:推迟数据(insightContext)异步到达,init 只有空字典可排——
        // 字典序排序在主键全 0 时退化为纯停滞天数,这一帧已经比原序(原始
        // sortOrder)合理;context 到位后 `rankDeck` 用真实推迟数重排一次。
        let ranked = TriageRanking.rank(
            Self.triageInput(from: todos), deferCounts: [:], now: Date()
        )
        self.deck = Array(ranked.prefix(TriageRanking.deckSize))
        self.tail = Array(ranked.dropFirst(TriageRanking.deckSize))
        self.previousSessions = previousSessions
        self.lastPinnedIDs = lastPinnedIDs
        // todos / previousSessions / lastPinnedIDs init 后不变,派生值一次算好,
        // 不留整份快照。
        self.lastPinnedOutcome = Self.lastPinnedOutcome(todos: todos, pinnedIDs: lastPinnedIDs)
        self.askDomainHintCategory = Self.askDomainHintCategory(
            todos: todos,
            rotationSeed: previousSessions.count
        )
        self.nextWeekCommitted = Self.nextWeekCommitted(
            from: todos, now: Date(), calendar: Calendar.current
        )
    }

    /// 快照里本来就排在下周的未完成任务。下周窗口与「排下周」的落点同语义:
    /// 下一个周一的用户日起点起 7 天(与 ReviewStepTriage.nextMondayStart 一致,
    /// 排期写库与候选池取数必须同一坐标系)。
    static func nextWeekCommitted(
        from todos: [TodoItemData],
        now: Date,
        calendar: Calendar
    ) -> [TodoItemData] {
        var components = DateComponents()
        components.weekday = 2 // 周一(gregorian),与 nextMondayStart 一致
        guard let nextMonday = calendar.nextDate(
            after: now, matching: components, matchingPolicy: .nextTime
        ) else { return [] }
        let weekStart = DayClock.startOfUserDay(for: nextMonday, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        return todos.filter { todo in
            guard let due = todo.dueDate,
                  !todo.isCompleted,
                  todo.abandonedAt == nil else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay >= weekStart && dueDay < weekEnd
        }
    }

    /// 上次置顶的结局计数(2026-08-25)。从**原始快照**数,不是 deck——完成的重点
    /// 不在 deck 里。已删除的 id 两边都不计;快照里一条都找不到(全删了)时返回
    /// nil——「0 完成、0 待处理」读起来像定了重点一件没动,实际是全删,属误导噪音。
    static func lastPinnedOutcome(todos: [TodoItemData], pinnedIDs: Set<UUID>) -> LastPinnedOutcome? {
        guard !pinnedIDs.isEmpty else { return nil }
        var completed = 0
        var pending = 0
        for todo in todos where pinnedIDs.contains(todo.id) {
            if todo.isCompleted { completed += 1 } else { pending += 1 }
        }
        guard completed > 0 || pending > 0 else { return nil }
        return LastPinnedOutcome(completed: completed, pending: pending)
    }

    /// 领域提示轮换(2026-08-25 拍板):只在快照中出现过的分类里按声明序轮换,
    /// seed = 历史会话数——每次复盘前进一格,不问从未使用的领域,无需新存储。
    static func askDomainHintCategory(todos: [TodoItemData], rotationSeed: Int) -> TodoCategory? {
        let present = TodoCategory.allCases.filter { category in
            todos.contains { $0.category == category }
        }
        guard !present.isEmpty else { return nil }
        return present[abs(rotationSeed) % present.count]
    }

    /// triage 输入过滤(拍板 4):未完成 && 未划掉 && 一次性(recurrenceRule == nil)。
    static func triageInput(from todos: [TodoItemData]) -> [TodoItemData] {
        todos.filter { !$0.isCompleted && $0.abandonedAt == nil && $0.recurrenceRule == nil }
    }

    // MARK: 步骤闸门

    /// 第 4 步候选池(2026-09-01 拍板「第 4 步」):本会话排进下周的 ∪ 快照里
    /// 本来就在下周且本会话没动过的。第二路排除 processedIDs——右滑「排下周」
    /// 即时写库,不排掉会双行(审阅缺口 B);「今天就做/不做了/拆小」处理过的
    /// 同样不该再当选下周三件事。
    var preexistingNextWeek: [TodoItemData] {
        nextWeekCommitted.filter { !processedIDs.contains($0.id) }
    }

    /// 完整候选池(视图分组渲染:scheduled 一组、preexistingNextWeek 一组)。
    var commitPool: [TodoItemData] {
        scheduled + preexistingNextWeek
    }

    /// 第 4 步(下周三件事)主按钮闸门(2026-08-22 拍板放宽):**至少选 1 件**,
    /// 文案仍鼓励选满 3——强制凑满 3 件会把「只想清卡堆」的用户卡在半路,
    /// 养复盘习惯比单次产出更重要。候选池(含本来就排在下周的,v2)为空时
    /// 无从选起,放行——强迫回去排 3 件违背复盘自愿原则(§2.5 反 gaming)。
    var canPassCommit: Bool {
        commitPool.isEmpty || !commitSelection.isEmpty
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

    /// 洞察腐烂卡的当场动作「不做了」(2026-09-01 v2「洞察卡带当场动作」;
    /// 写库在视图层,本方法只改状态)。条目可能在前 8 卡堆或排序尾部,
    /// 两处都清;不在(已处理过)时返回 false。决定数照常 +1(拍板 4)。
    @discardableResult
    func abandonFromInsight(id: UUID) -> Bool {
        if let todo = deck.first(where: { $0.id == id }) {
            markAbandoned(todo)
            return true
        }
        if let todo = tail.first(where: { $0.id == id }) {
            markAbandoned(todo)
            tail.removeAll { $0.id == id }
            return true
        }
        return false
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

    /// insightContext 到位后重排卡堆与尾部(2026-09-01 拍板 2 的时序落地:
    /// deck 在 init 用空推迟数据排过一次,context 异步到达后必须用真实
    /// deferCounts 重排,否则冷启动那帧排出来的是错的)。已处理条目不在
    /// deck/tail 里,天然不回流。
    func rankDeck(deferCounts: [UUID: Int], now: Date = Date()) {
        let pool = deck + tail
        guard !pool.isEmpty else { return }
        let ranked = TriageRanking.rank(pool, deferCounts: deferCounts, now: now)
        deck = Array(ranked.prefix(TriageRanking.deckSize))
        tail = Array(ranked.dropFirst(TriageRanking.deckSize))
    }

    // MARK: 第 2 步 · 批量出口(拍板 3:复用「稍后」,不新增 somedayAt 终态)

    /// 尾部里可一键推「稍后」的:停滞 ≥ 30 天 **且** AI 识别成功。
    /// `.rawFallback` / `.unparsed` 即使清了三字段也只落「没能识别」而不是
    /// 「稍后」,不承诺做不到的落点,排除在外。
    var somedayBatchCandidates: [TodoItemData] {
        tail.filter {
            TriageRanking.stagnationDays(of: $0, now: Date()) >= TriageRanking.batchStagnationDays
                && $0.extractionOutcome == .parsed
        }
    }

    /// 尾部里既不进卡堆也不进批量出口的条数(UI 呈现「其余 N 件先不动」,
    /// 防止用户误以为所有积压都被处理了)。
    var untouchedTailCount: Int {
        tail.count - somedayBatchCandidates.count
    }

    /// 批量出口执行(视图层 store 全部写成功后调用):快照原字段(整批撤销用)、
    /// 计数累加、尾部清掉对应条目。不进 processedIDs / abandonedStack——
    /// 推后不是「决定」(拍板 4),也不是划掉。
    func markSomedayBatchExecuted() {
        let batch = somedayBatchCandidates
        guard !batch.isEmpty else { return }
        somedayUndoSnapshot = batch
        somedayCount += batch.count
        let ids = Set(batch.map(\.id))
        tail.removeAll { ids.contains($0.id) }
    }

    /// 整批撤销(视图层把快照原字段写回 store 成功后调用):条目回尾部、
    /// 计数回退、快照清空(一次性,重复撤销无操作)。
    func undoSomedayBatch() {
        guard let batch = somedayUndoSnapshot else { return }
        somedayUndoSnapshot = nil
        somedayCount -= batch.count
        tail.append(contentsOf: batch)
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
        /// 卡堆侧总数 = 逐张决定的 + 仍留在卡堆的。2026-09-01 拍板 1 截断后
        /// 尾部不计入——「N / M」计数器只对用户真正面对过的卡有意义。
        let inputCount: Int
        /// 处理后仍留在卡堆的(M,含撤销回来的)。
        let remainingCount: Int
        let scheduledCount: Int
        let abandonedCount: Int
        let splitCount: Int
        let todayCount: Int
        let pinnedCount: Int
        /// 批量推「稍后」条数(单独一行,不并决定数,拍板 4)。
        let somedayCount: Int
    }

    var ledger: Ledger {
        Ledger(
            inputCount: processedIDs.count + deck.count,
            remainingCount: deck.count,
            scheduledCount: scheduled.count,
            abandonedCount: abandonedStack.count,
            splitCount: splitCount,
            todayCount: todayPicked.count,
            pinnedCount: commitSelection.count,
            somedayCount: somedayCount
        )
    }

    /// 「你决定了 N 件」的 N(2026-09-01 拍板 4):逐张决定的四种去向之和。
    /// 批量推「稍后」**不算**——逐张决定的 28 件 ≠ 一键扫掉的 28 件,
    /// 不能用同一句话庆祝。
    var decidedCount: Int {
        scheduled.count + todayPicked.count + abandonedStack.count + splitCount
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
            // 洞察步被降级跳过时原料为 nil → 完成数不可统计,存 nil(2026-08-23)。
            completedCount: insightContextValue?.completedEvents.count,
            ledger: ReviewLedger(
                inputCount: ledger.inputCount,
                remainingCount: ledger.remainingCount,
                scheduledCount: ledger.scheduledCount,
                todayCount: ledger.todayCount,
                abandonedCount: ledger.abandonedCount,
                splitCount: ledger.splitCount,
                pinnedCount: ledger.pinnedCount,
                somedayCount: ledger.somedayCount
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
    /// 拆小 sheet 的 AI 候选源(2026-08-23 拆小改版)。nil → sheet 直接手写降级。
    var splitter: (any TodoSplitterProtocol)? = nil
    /// 拆小 sheet 的麦克风(与首页共用同一实例)。nil → 「说一句」行隐藏。
    var voiceInput: (any VoiceInputProtocol)? = nil
    /// 笔记语义对照的提取器(2026-08-23,任务 #4)。nil → 收尾不做 AI 分析,
    /// 笔记照存,下期退化为纯文本。
    var noteAnalyzer: (any ReviewNoteAnalyzerProtocol)? = nil

    @State private var state: ReviewFlowState

    init(
        store: any ReviewFlowStore,
        splitter: (any TodoSplitterProtocol)? = nil,
        voiceInput: (any VoiceInputProtocol)? = nil,
        noteAnalyzer: (any ReviewNoteAnalyzerProtocol)? = nil
    ) {
        self.store = store
        self.splitter = splitter
        self.voiceInput = voiceInput
        self.noteAnalyzer = noteAnalyzer
        // 工作集快照在 init 一次取齐:卡堆输入不随后续 store 写入回流
        // (拆小产生的子任务不该再弹回卡堆)。历史会话同批注入(冷却 /
        // 跨期对照的数据源,阶段 4);上次置顶 id 同批快照(setPinned 整体
        // 覆写 → 集合即「上次定的重点」,2026-08-25)。
        _state = State(initialValue: ReviewFlowState(
            todos: store.todos,
            previousSessions: ReviewSessionStore.shared.allSessions(),
            lastPinnedIDs: ReviewPinningStore.shared.pinnedIDs()
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
            let context = try await store.insightContext(from: start, to: end)
            state.insightContextValue = context
            state.insightLoadError = nil
            state.recordPeriod(start: start, end: end)
            state.configureInsightsLadder()
            // 拍板 2 的时序要求:deck 在 init 用空推迟数据排过,真实 deferCounts
            // 到位后重排一次(已处理条目不回流,见 rankDeck)。
            state.rankDeck(deferCounts: context.deferCounts)
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
            ReviewStepRecap(
                lastReviewDate: state.previousSessions.last?.completedAt,
                lastPinnedOutcome: state.lastPinnedOutcome.map { outcome in
                    (completed: outcome.completed, pending: outcome.pending)
                }
            )
        case .triage:
            ReviewStepTriage(
                state: state,
                store: store,
                onError: { presentError($0) },
                onUndoToast: { coordinator.showToast(message: $0, style: .info) },
                splitter: splitter,
                voiceInput: voiceInput
            )
        case .insights:
            ReviewStepInsights(
                state: state,
                onRetryInsights: { Task { await loadInsightContext() } },
                onJumpToTriage: {
                    withAnimation(WarmAnimation.springStandard) {
                        state.retreat(toTriage: true)
                    }
                },
                // 腐烂卡当场「不做了」:先写库后改状态,与第 2 步 abandon 同序
                // (失败只报错,状态不动)。id 已不在卡堆/尾部(处理过)时
                // 状态侧无操作——重复 abandon 只会刷新时间戳,无事件重复。
                onAbandonTask: { todoId in
                    do {
                        try store.abandon(todoId)
                        _ = state.abandonFromInsight(id: todoId)
                        HapticFeedback.light()
                    } catch {
                        presentError(error)
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
        analyzeNoteTopicsInBackground(session: session)
        dismiss()
    }

    /// 收尾后的语义对照提取(2026-08-23 拍板,任务 #4):存完会话立刻异步做
    /// 一次 AI 分析(不计费),把「关注点 + 当期计数」按 id 回写进会话;下次
    /// 复盘纯本地拼对照。失败只记日志——对照是增强,离线/失败退化为纯文本
    /// 笔记(拍板口径);洞察原料缺失(降级跳过)时本期计数算不了,同样跳过。
    private func analyzeNoteTopicsInBackground(session: ReviewSession) {
        guard let noteAnalyzer,
              let note = session.voiceNote,
              let context = state.insightContextValue else { return }
        let calendar = Calendar.current
        Task { @MainActor in
            do {
                let drafts = try await noteAnalyzer.analyzeNoteTopics(note: note, locale: .current)
                let topics = drafts.prefix(3).map { draft in
                    ReviewTopic(
                        text: draft.text,
                        category: draft.category,
                        timeBucket: draft.timeBucket,
                        periodCount: ReviewTopicMatching.periodCount(
                            category: draft.category,
                            timeBucket: draft.timeBucket,
                            in: context.completedEvents,
                            calendar: calendar
                        ) ?? 0
                    )
                }
                guard !topics.isEmpty else { return }
                ReviewSessionStore.shared.updateTopics(sessionID: session.id, topics: Array(topics))
            } catch {
                // 降级不弹错:笔记本体已存好,对照行下期自然不出现。
                VoiceTodoLog.coordinator.warning("review.flow.note_analyze.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
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
