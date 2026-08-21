import SwiftUI

/// 第 3 步 · 观察(阶段 3)。
///
/// 原料在流程启动时已存进 `state.insightContextValue`(不放 body,§1.4);
/// 本视图把它跑过引擎(降级阶梯 §2.3:5–14 只跑腐烂;≥15 跑 02+03),
/// 结果 score 降序。未达阈值的不显示(不是「无异常」)。
///
/// 语音提问:本阶段**只提供纯文字输入**——额度已核实(转写走本地 SFSpeechRecognizer,
/// 不经代理,不耗 AI 额度),但 `VoiceInputProtocol` 由 AppCoordinator 私有持有、
/// 与首页录音状态机强耦合,注入不干净;麦克风按钮留待注入解耦后再加。
/// 纯文字输入同时是 accessibility 兜底。答案存 State(阶段 4 持久化)。
struct ReviewStepInsights: View {
    @Bindable var state: ReviewFlowState
    let onRetryInsights: () -> Void
    let onJumpToTriage: () -> Void

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
                    askYourselfSection
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

    /// 跑 v1 两条规则(拍板 2),按 ladder 裁剪,score 降序(§阶段 3)。
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
        }

        rankedResults = InsightEngine.rank(results)
        placeholders = newPlaceholders
        ladderNeedMore = ladder.rottingOnlyNeedMore
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
                onSaveRule: { state.saveRule($0) },
                onOpenTask: result.id == .rotting ? { todoId in
                    // 腐烂卡任务跳回第 2 步对应卡片(§阶段 3)。
                    state.triageFocusID = todoId
                    onJumpToTriage()
                } : nil
            )
        }

        ForEach(placeholders, id: \.id) { placeholder in
            placeholderRow(placeholder)
        }
    }

    /// 占位行:写清还差多少(「还需 11 条」,不是「数据不足」,§2.3)。
    private func placeholderRow(_ placeholder: (id: InsightID, needMore: Int)) -> some View {
        RecapCard {
            Text(String(localized: "review.flow.insights.need_more_tasks_\(placeholder.needMore)"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 5–14 档的预告:「再记 N 条,就能看出你的做事习惯了」(§2.3)。
    @ViewBuilder
    private func ladderHint(context: InsightContext) -> some View {
        if let needMore = ladderNeedMore {
            Text(String(localized: "review.flow.insights.ladder_hint_\(needMore)"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: 语音/文字提问

    /// 「问问自己」:纯文字输入(accessibility 兜底 + 唯一入口,见类型注释)。
    /// 答案存 `state.voiceAnswerText`(阶段 4 持久化)。
    private var askYourselfSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "review.flow.insights.ask.title"))
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $state.voiceAnswerText)
                    .font(WarmFont.body(14))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(WarmSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                            .fill(WarmTheme.inputFieldBackground)
                    )
                    .overlay(alignment: .topLeading) {
                        if state.voiceAnswerText.isEmpty {
                            Text(String(localized: "review.flow.insights.ask.placeholder"))
                                .font(WarmFont.caption(12))
                                .foregroundColor(WarmTheme.textMuted)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .padding(WarmSpacing.sm)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("ReviewFlowAskYourself")
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
