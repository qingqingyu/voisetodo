import SwiftUI

/// 第 3 步 · 观察(阶段 3;2026-09-01 v2 改版:只留洞察;v3 拍板 7:只读 State)。
///
/// 引擎已在流程启动时跑完(`ReviewFlowState.runInsightEngine`,与
/// `configureInsightsLadder()` 同一时机——空结果在进本步之前就定好整步跳过,
/// 不会出现「进了第 3 步再被弹走」的闪屏);本视图只读
/// `state.rankedResults` / `insightPlaceholders` / `ladderNeedMore`,
/// 失败态展示错误 + 重试(重试随 `loadInsightContext` 重跑引擎)。
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
    }

    // MARK: 卡片

    @ViewBuilder
    private var cards: some View {
        ForEach(Array(state.rankedResults.enumerated()), id: \.element.id) { _, result in
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

    /// 占位行(v3 拍板 7:仍然只出一行——拍板 6 反对的是四行堆叠——但这一行
    /// 说真话):按 `InsightID.placeholderPriority` 固定优先序选条,不比
    /// needMore 数值(三条规则缺口量纲不同,比大小会随机推荐更难达成的条件);
    /// 按 id 出对应文案,文案里的动作照做能真的解锁(effortOrdering 的解锁
    /// 是**完成** 3 条高优——「标」优先级不解锁,写「做完」)。
    @ViewBuilder
    private var placeholderSummaryRow: some View {
        if let pick = InsightID.firstPlaceholder(in: state.insightPlaceholders) {
            Text(String(
                localized: "review.flow.insights.need_more.\(pick.id.rawValue)_\(pick.needMore)"
            ))
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
        if state.ladderNeedMore != nil {
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
