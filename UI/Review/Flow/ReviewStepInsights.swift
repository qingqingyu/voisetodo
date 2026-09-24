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
    /// 地板 A 当场「排下周」(v4 批 1):写库在容器层,落点与第 2 步右滑一致。
    let onScheduleTask: (UUID) -> Void
    /// 地板 A「拆小」(v4 批 1):深链跳回第 2 步自动开拆小 sheet(复用既有链路)。
    let onSplitTask: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                if let error = state.insightLoadError {
                    errorCard(error)
                } else if let context = state.insightContextValue {
                    cards(context: context)
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
    private func cards(context: InsightContext) -> some View {
        // 地板层(v4:事实永远算得出来,兜住警报层集体沉默的空屏)先出,
        // 规则层洞察卡随后——极端模式的警报比事实更值得被先看到时,用户
        // 可以滚动;两层的相对顺序不承载「谁更重要」的判断。
        if let fact = state.backlogAgeFact {
            BacklogAgeFloorCard(
                fact: fact,
                liveIDs: state.liveTriageIDs,
                onAbandonTask: onAbandonTask,
                onScheduleTask: onScheduleTask,
                onSplitTask: onSplitTask
            )
        }

        // 地板 B(v4 批 4):本期进出——净变化的方向。与第 1 步成绩单的差别
        // 在语气:这里回答「清单在缩还是在涨」。零进零出 → nil 不渲染。
        if let flow = state.backlogFlowFact {
            BacklogFlowFloorCard(fact: flow)
        }

        // 地板 C(v4 批 3):积压集中在哪——直接指向「该砍哪边」的事实,
        // 与第 5 步领域提示同口径(问的正是这一块)。
        if let categoryFact = state.backlogCategoryFact {
            BacklogCategoryFloorCard(fact: categoryFact)
        }

        // 脚注(v4 批 2 拍板 5 连带):占位行与最小事实行从「撑起一屏的
        // 内容」降级为地板块下方的脚注——不再参与整步存活判定;地板与
        // 规则都空时整步已跳,脚注不再单独出现(无孤儿态)。挂在地板层
        // **整体**之后而不是地板 A 里面——零积压 + 5–14 档完成时 B/C 仍
        // 可在场,脚注不该随 A 的 nil 一起消失(v4 复盘审阅发现 5:那正是
        // v3 审阅发现 1「最小事实行成死代码」的窄化重现)。
        placeholderSummaryRow
        ladderHint(context: context)

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

        // 规则层事实行(v4 批 3 拍板 3:03 中间地带只报占比;排在洞察卡后——
        // 极端模式的警报先说,中性事实收尾)。
        ForEach(state.insightFactLines, id: \.id) { line in
            Text(line.text)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 占位行(v3 拍板 7:仍然只出一行——拍板 6 反对的是四行堆叠——但这一行
    /// 说真话;v4 批 2:降级为地板块下方的**脚注**,不再参与整步存活判定):
    /// 按 `InsightID.placeholderPriority` 固定优先序选条,不比
    /// needMore 数值(三条规则缺口量纲不同,比大小会随机推荐更难达成的条件);
    /// 文案经 `InsightID.placeholderText(needMore:)`——键里的 id 段必须是
    /// 静态字面量(String 插值进键会变 %@,catalog 按 id 命名,查不到整串
    /// 回落键名),文案里的动作照做能真的解锁(effortOrdering 的解锁是
    /// **完成** 3 条高优——「标」优先级不解锁,写「做完」)。
    @ViewBuilder
    private var placeholderSummaryRow: some View {
        if let pick = InsightID.firstPlaceholder(in: state.insightPlaceholders),
           let text = pick.id.placeholderText(needMore: pick.needMore) {
            Text(text)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 5–14 档的最小事实(2026-09-01 v2:「数据不够时显示当下能算出的最小
    /// 事实,而不是锁」;v4 批 2:同样降级为地板块下方的脚注,不再参与
    /// 整步存活判定)——「你目前只有约 N 周记录,先说说这周」。
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
        // 「现在」用快照的 ctx.now(发现 3 同款口径):同屏地板层年龄与这里
        // 的周数必须同一个现在,别拿取数后的 Date() 另开一灶。
        let days = Calendar.current.dateComponents([.day], from: oldest, to: context.now).day ?? 0
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

// MARK: - 地板 B · 本期进出(v4 批 4,docs/todo-review-flow-v4.md)

/// 一行净变化方向。只报方向与数字,不带判断;**展示数字**与第 1 步证据行
/// 同源(`weekSummary` 的 createdCount / total),**方向**用
/// `BacklogFlowFact.backlogDelta`(同总体口径,别拿展示数相减——见其注释)。
/// 趋势线待 ≥3 期 `ReviewLedger.backlogCount` 攒够再开(批 4 明确不做)。
private struct BacklogFlowFloorCard: View {
    let fact: ReviewFlowState.BacklogFlowFact

    var body: some View {
        RecapCard {
            Text(flowLine)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("ReviewFlowBacklogFlowFloor")
    }

    /// 方向三态:在涨 / 在缩 / 相抵(`backlogDelta` 的正负决定选键,数字同键序)。
    private var flowLine: String {
        if fact.backlogDelta > 0 {
            return String(localized: "review.floor.backlog_flow.grew_\(fact.createdCount)_\(fact.completedCount)")
        }
        if fact.backlogDelta < 0 {
            return String(localized: "review.floor.backlog_flow.shrank_\(fact.createdCount)_\(fact.completedCount)")
        }
        return String(localized: "review.floor.backlog_flow.flat_\(fact.createdCount)_\(fact.completedCount)")
    }
}

// MARK: - 地板 C · 积压集中在哪(v4 批 3,docs/todo-review-flow-v4.md)

/// 最集中分类一行 + 对照组一行(本期完成过、当前零积压的领域)。只报事实;
/// 口径说明由上方地板 A 的 sample_note 承载(A 恒先渲染且必在场)。
private struct BacklogCategoryFloorCard: View {
    let fact: InsightEngine.BacklogCategoryFact

    var body: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                Text(String(
                    localized: "review.floor.backlog_focus.line_\(fact.focusCategory.displayName)_\(fact.focusCount)_\(fact.focusOldestAgeDays)"
                ))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                if let contrast = fact.contrastCategory {
                    Text(String(
                        localized: "review.floor.backlog_focus.contrast_\(contrast.displayName)_\(fact.contrastCount)"
                    ))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("ReviewFlowBacklogFocusFloor")
    }
}

// MARK: - 地板 A · 积压年龄(v4 批 1,docs/todo-review-flow-v4.md)

/// 三档分布条(0–7 / 8–20 / 21+)+ 最老 3 条点名(每条带「不做了 / 排下周 /
/// 拆小」当场动作)。只报事实、零值不渲染;腐烂卡本期展示时点名让位
/// (`BacklogAgeFact.oldestItems` 为空),只剩分布条。点名行是引擎跑时快照,
/// 按「仍在卡堆 ∪ 尾部」过滤(`liveIDs`)——已处理的与批量推「稍后」的
/// 一起消失,快照不回改;整批撤销后随尾部回流自然重现。
private struct BacklogAgeFloorCard: View {
    let fact: InsightEngine.BacklogAgeFact
    /// 仍在流程内(卡堆 ∪ 尾部)的条目 id。不用 `processedIDs`:批量推
    /// 「稍后」不进 processedIDs(拍板 4),只按它过滤会点名已推稍后的条目,
    /// 而三个当场动作在卡堆/尾部都找不到条目,全部静默失灵
    /// (v4 复盘审阅发现 1)。
    let liveIDs: Set<UUID>
    let onAbandonTask: (UUID) -> Void
    let onScheduleTask: (UUID) -> Void
    let onSplitTask: (UUID) -> Void

    /// 快照里仍在流程内的最老 3 条。
    private var liveItems: [InsightEngine.BacklogAgeFact.Item] {
        fact.oldestItems.filter { liveIDs.contains($0.todoId) }
    }

    var body: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.floor.backlog_age.headline_\(fact.total)"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                distributionBar
                legendRow

                // 「说真话」行:21+ 档为 0 时不开一扇锁着的门,报最久的实际天数
                // (v4 方案;腐烂卡自己有话可说时不再叠加,判定收在 fact 里)。
                if fact.showsNoOldLine {
                    Text(String(localized: "review.floor.backlog_age.no_old_\(fact.total)_\(fact.oldestAgeDays)"))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !liveItems.isEmpty {
                    oldestList
                }

                // 口径说明与腐烂卡同款(§2.2):总数与首页「待处理」差规律任务时,
                // 这里说清楚,数字不打架。
                Text(String(localized: "review.insight.rotting.sample_note_\(fact.total)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("ReviewFlowBacklogAgeFloor")
    }

    // MARK: 分布条 + 图例

    /// 三段堆叠横条,零值段不渲染(宽度 0 的段连缝隙都不留)。RTL:HStack
    /// 自动镜像,不用绝对坐标。
    private var distributionBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                barSegment(count: fact.freshCount, totalWidth: proxy.size.width, color: WarmTheme.subtleControlBackground)
                barSegment(count: fact.agingCount, totalWidth: proxy.size.width, color: WarmTheme.warning.opacity(0.7))
                barSegment(count: fact.oldCount, totalWidth: proxy.size.width, color: WarmTheme.urgentText.opacity(0.85))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func barSegment(count: Int, totalWidth: CGFloat, color: Color) -> some View {
        // 零值段 width 0:HStack 的 spacing 只在有可见子视图间生效,但 0 宽
        // 子视图仍占一个间隙——用 Group 条件渲染彻底不出现。
        Group {
            if count > 0 {
                Capsule()
                    .fill(color)
                    .frame(width: max(totalWidth * CGFloat(count) / CGFloat(max(fact.total, 1)), 6))
            }
        }
    }

    /// 图例行:与分布条同色系,零值档不出(「21+ 天:0」是噪音行)。
    private var legendRow: some View {
        HStack(spacing: WarmSpacing.md) {
            if fact.freshCount > 0 {
                legendDot(
                    color: WarmTheme.subtleControlBackground,
                    label: String(localized: "review.floor.backlog_age.bucket.fresh_\(fact.freshCount)")
                )
            }
            if fact.agingCount > 0 {
                legendDot(
                    color: WarmTheme.warning.opacity(0.7),
                    label: String(localized: "review.floor.backlog_age.bucket.aging_\(fact.agingCount)")
                )
            }
            if fact.oldCount > 0 {
                legendDot(
                    color: WarmTheme.urgentText.opacity(0.85),
                    label: String(localized: "review.floor.backlog_age.bucket.old_\(fact.oldCount)")
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: WarmSpacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 点名行

    private var oldestList: some View {
        VStack(spacing: WarmSpacing.xs) {
            ForEach(Array(liveItems.enumerated()), id: \.element.todoId) { index, item in
                itemRow(item)
                if index < liveItems.count - 1 {
                    Rectangle()
                        .fill(WarmTheme.rowHairline)
                        .frame(height: 1)
                }
            }
        }
    }

    /// 行 = 标题 + 放置天数;尾随「不做了」(与腐烂卡同款 xmark)+ 菜单
    /// (排下周 / 拆小)。三动作文案复用第 2 步既有键。
    private func itemRow(_ item: InsightEngine.BacklogAgeFact.Item) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Text(String(localized: "review.flow.rotting.age_\(item.ageDays)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: WarmSpacing.xs)

            Button {
                onAbandonTask(item.todoId)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WarmTheme.urgentText.opacity(0.8))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "review.flow.triage.action.drop"))
            .accessibilityIdentifier("ReviewFlowBacklogAgeDrop_\(item.todoId.uuidString)")

            Menu {
                Button(String(localized: "review.flow.triage.action.keep")) {
                    onScheduleTask(item.todoId)
                }
                Button(String(localized: "review.flow.triage.action.split")) {
                    onSplitTask(item.todoId)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WarmTheme.primaryText.opacity(0.8))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(String(localized: "review.floor.backlog_age.item.actions"))
            .accessibilityIdentifier("ReviewFlowBacklogAgeMenu_\(item.todoId.uuidString)")
        }
    }
}
