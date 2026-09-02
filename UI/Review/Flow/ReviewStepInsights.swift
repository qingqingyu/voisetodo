import SwiftUI

/// 第 3 步 · 观察(阶段 3;2026-09-01 v2 改版:只留洞察)。
///
/// 原料在流程启动时已存进 `state.insightContextValue`(不放 body,§1.4);
/// 本视图把它跑过引擎(降级阶梯 §2.3:5–14 只跑腐烂;≥15 跑 01/02/03/05),
/// 结果 score 降序。未达阈值的不显示(不是「无异常」)。
///
/// 「历次笔记」卡与「问问自己」输入框已随迁第 5 步(2026-09-02 实施补注:
/// 收尾带「下次复盘会给你看」承诺,且洞察步被降级跳过时第 3 步整步不出,
/// 承诺需要收尾位兜底)。
struct ReviewStepInsights: View {
    @Bindable var state: ReviewFlowState
    let onRetryInsights: () -> Void
    let onJumpToTriage: () -> Void
    /// 腐烂卡当场动作「不做了」(2026-09-01 v2「洞察卡带当场动作」:对一个
    /// 具体任务执行一个具体动作,有下游行为——与 2026-08-22 移除的「只存档
    /// 不驱动」的存规则链路不是一回事,docs v2 已辨析)。
    let onAbandonTask: (UUID) -> Void

    /// 引擎跑出的结果(.task 里算一次存 State,不放 body)。
    @State private var rankedResults: [InsightResult] = []
    /// 已实现规则的占位行(「还需 N 条」,§2.3:必须写清还差多少)。
    @State private var placeholders: [(id: InsightID, needMore: Int)] = []
    /// 降级阶梯的「再记 N 条」提示(5–14 档,只跑 02 时的预告)。
    @State private var ladderNeedMore: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                if let error = state.insightLoadError {
                    errorCard(error)
                } else if let context = state.insightContextValue {
                    cards
                    ladderHint(context: context)
                } else {
                    ProgressView()
                        .padding(.top, WarmSpacing.xxl)
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
        .task { runEngine() }
        // 原料是异步到达的(流程启动 .task 加载/失败重试):挂载时可能还没就绪,
        // 就绪或重试成功后必须重算,否则卡片区空白(错误恢复路径)。
        .onChange(of: state.insightContextValue) { _, _ in runEngine() }
    }

    // MARK: 引擎

    /// 跑四条规则(02/03 v1 + 01/05 2026-08-23 拍板启用),按 ladder 裁剪,
    /// score 降序(§阶段 3);触发后先过冷却(§2.4,阶段 4 接真历史):不满足
    /// 任一放行条件的本期不展示,也不进 `shownInsights` 历史。效应量**变好**的
    /// 放行换 improving 文案。
    private func runEngine() {
        guard let context = state.insightContextValue else { return }
        let calendar = Calendar.current
        let ladder = InsightEngine.ladder(completedRecordCount: context.completedEvents.count)

        var results: [InsightResult] = []
        var newPlaceholders: [(InsightID, Int)] = []

        let rotting = RottingRule().evaluate(context, calendar: calendar)
        collect(rotting, id: .rotting, into: &results, &newPlaceholders)

        if ladder == .full {
            let reactive = ReactiveVsPlannedRule().evaluate(context, calendar: calendar)
            collect(reactive, id: .reactiveVsPlanned, into: &results, &newPlaceholders)

            // 2026-08-23 拍板:01 先易后难 + 05 精力窗口启用(04 对谁失约违反
            // 反 gaming 章程继续搁置,06 周内衰减待 ≥4 完整周)。
            let effort = EffortOrderingRule().evaluate(context, calendar: calendar)
            collect(effort, id: .effortOrdering, into: &results, &newPlaceholders)

            let energy = EnergyWindowRule().evaluate(context, calendar: calendar)
            collect(energy, id: .energyWindow, into: &results, &newPlaceholders)
        }

        // 冷却过滤(§2.4):02 腐烂占比 / 03 救火占比都是「越小越好」。
        let cooled = results.compactMap { result -> InsightResult? in
            applyCooldown(result)
        }
        let ranked = InsightEngine.rank(cooled)
        // 展示过的才进冷却历史(被过滤掉的不记)。重跑先清空:上一轮展示过、
        // 这一轮被冷却过滤的洞察不该留在历史里。
        state.resetShownInsights()
        ranked.forEach { state.recordShownInsight($0) }

        rankedResults = ranked
        placeholders = newPlaceholders
        ladderNeedMore = ladder.rottingOnlyNeedMore
    }

    /// 对一条触发的洞察套冷却判定。无历史(第一次展示)直接放行;有历史按
    /// `InsightEngine.cooldown` 三条件。`.effectChanged(improved: true)` 换 improving 文案。
    private func applyCooldown(_ result: InsightResult) -> InsightResult? {
        guard let input = ReviewCooldownHistory.input(
            insightID: result.id,
            sessions: state.previousSessions,
            currentEffectSize: result.effectSize,
            lowerIsBetter: true
        ) else {
            return result // 无历史:第一次展示,放行
        }
        switch InsightEngine.cooldown(input) {
        case .success(let reason):
            if case .effectChanged(let improved) = reason, improved {
                return result.withTone(.improving)
            }
            return result
        case .failure:
            return nil // 冷却中:本期不展示
        }
    }

    private func collect(
        _ availability: InsightAvailability,
        id: InsightID,
        into results: inout [InsightResult],
        _ placeholders: inout [(InsightID, Int)]
    ) {
        switch availability {
        case .fired(let result):
            results.append(result)
        case .placeholder(let needMore):
            placeholders.append((id, needMore))
        case .hidden:
            break
        }
    }

    // MARK: 卡片

    @ViewBuilder
    private var cards: some View {
        ForEach(Array(rankedResults.enumerated()), id: \.element.id) { _, result in
            InsightCardView(
                result: result,
                onOpenTask: result.id == .rotting ? { todoId in
                    // 腐烂卡任务跳回第 2 步对应卡片(§阶段 3)。
                    state.triageFocusID = todoId
                    onJumpToTriage()
                } : nil,
                onAbandonTask: result.id == .rotting ? { todoId in
                    onAbandonTask(todoId)
                } : nil
            )
        }

        placeholderSummaryRow
    }

    /// 占位合并(2026-09-01 拍板 6):不再逐条 ForEach 堆叠——刺眼的是四行
    /// 「再记 N 条」的堆叠,不是单条文案。取最严的一条门槛,一行说完。
    @ViewBuilder
    private var placeholderSummaryRow: some View {
        if let maxNeedMore = placeholders.map(\.needMore).max() {
            Text(String(localized: "review.flow.insights.need_more_merged_\(maxNeedMore)"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 5–14 档的最小事实(2026-09-01 v2:「数据不够时显示当下能算出的最小
    /// 事实,而不是锁」)——「你目前只有约 N 周记录,先说说这周」。
    /// N = 完成事件里最早的记录距今天的周数(向上取整,至少 1)。
    @ViewBuilder
    private func ladderHint(context: InsightContext) -> some View {
        if ladderNeedMore != nil {
            Text(String(localized: "review.flow.insights.minimal_fact_\(weeksOfRecords(context))"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weeksOfRecords(_ context: InsightContext) -> Int {
        guard let oldest = context.completedEvents.map(\.createdAt).min() else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
        return max(1, Int(ceil(Double(days) / 7)))
    }

    // MARK: 错误态

    private func errorCard(_ error: VoiceTodoError) -> some View {
        RecapCard {
            VStack(spacing: WarmSpacing.md) {
                Text(String(localized: "review.flow.insights.load_failed"))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                Button(String(localized: "common.retry")) {
                    onRetryInsights()
                }
                .font(WarmFont.headline(14))
                .foregroundColor(WarmTheme.primaryText)
            }
        }
    }

}

// MARK: - 降级阶梯便捷取值

extension InsightEngine.Ladder {
    /// rottingOnly 档的 needMore(其他档 nil)。
    var rottingOnlyNeedMore: Int? {
        if case .rottingOnly(let needMore) = self { return needMore }
        return nil
    }
}
