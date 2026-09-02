import SwiftUI

/// 第 5 步 · 收尾账本(v2 改版 2026-09-01,docs/todo-review-flow-v2.md「第 5 步」:
/// 收尾是确认,不是审判)。
///
/// - 主角「你决定了 N 件」(N = 逐张决定四去向之和);批量推后单独一行,不合并。
/// - 决策明细降级成一行小字,**零值不渲染**;全零时整张卡不出。
/// - 「历次笔记」卡与「问问自己」输入框从第 3 步随迁至此(2026-09-02 实施补注:
///   承诺「下次复盘会给你看」的兑现位在流程内必须可见——洞察步被降级跳过时
///   第 3 步整步不出,放在那里承诺会落空;放在收尾,回看上次→写下这次,
///   动线也顺)。答案持久化不变(`ReviewFlowState.voiceAnswerText`,阶段 4)。
struct ReviewStepLedger: View {
    @Bindable var state: ReviewFlowState

    private let calendar = Calendar.current

    /// 下次复盘日期:复盘提醒现有节奏是每周一(App/ReviewNotificationScheduler),
    /// 账本对齐同一节奏——下一个周一。第 5 步渲染时点即会话收尾时点
    /// (阶段 4:`finishSession` 在「完成」点击时落库),与 scheduler 语义一致。
    private var nextReviewDate: Date {
        var components = DateComponents()
        components.weekday = 2 // 周一
        return calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) ?? Date()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                summaryCard
                crossPeriodCard
                askYourselfSection
                nextReviewCard
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    // MARK: 主卡(拍板 4:决定了 N 件,批量推后单独一行)

    /// 全零(没决定任何一件、也没批量推后)时整卡不出——「你决定了 0 件」
    /// 是审判,不是确认。
    @ViewBuilder
    private var summaryCard: some View {
        let ledger = state.ledger
        if state.decidedCount > 0 || ledger.somedayCount > 0 {
            RecapCard {
                VStack(spacing: WarmSpacing.xs) {
                    if state.decidedCount > 0 {
                        Text(String(localized: "review.flow.ledger.decided_\(state.decidedCount)"))
                            .font(WarmFont.headline(17))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(String(localized: "review.flow.ledger.summary_caption"))
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }

                    // 批量推后单独一行:与逐张决定分开计数、分开庆祝。
                    if ledger.somedayCount > 0 {
                        Text(String(localized: "review.flow.ledger.someday_\(ledger.somedayCount)"))
                            .font(WarmFont.caption(13))
                            .foregroundColor(WarmTheme.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !detailFragments.isEmpty {
                        Text(verbatim: detailFragments.joined(separator: " · "))
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 决策明细一行小字:只拼非零片段(docs v2 例:「今天做 2 · 拆小 1 · 下周 3 · 推后 27」)。
    private var detailFragments: [String] {
        let ledger = state.ledger
        var parts: [String] = []
        if ledger.todayCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.today_\(ledger.todayCount)"))
        }
        if ledger.splitCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.split_\(ledger.splitCount)"))
        }
        if ledger.scheduledCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.scheduled_\(ledger.scheduledCount)"))
        }
        if ledger.abandonedCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.abandoned_\(ledger.abandonedCount)"))
        }
        if ledger.somedayCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.someday_\(ledger.somedayCount)"))
        }
        if ledger.pinnedCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.pinned_\(ledger.pinnedCount)"))
        }
        return parts
    }

    private var nextReviewCard: some View {
        RecapCard {
            HStack(spacing: WarmSpacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: 18))
                    .foregroundColor(WarmTheme.primary)

                Text(String(
                    localized: "review.flow.ledger.next_review_\(nextReviewDate.formatted(.dateTime.month().day().weekday(.abbreviated)))"
                ))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 历次笔记卡(2026-08-23 拍板「全量可见」;2026-09-02 从第 3 步随迁至此)

    /// 「历次复盘,你说过」:全部写过笔记的会话,新→旧。没有笔记时不显示。
    /// 最新一条若带语义对照关注点(收尾 AI 提取回写),在其下渲染对照行
    /// (「本期 N 件(上期 M 件)」纯本地现算);洞察原料缺失(降级跳过 /
    /// 加载失败)时对照行不出,笔记列表照常。
    @ViewBuilder
    private var crossPeriodCard: some View {
        let entries = ReviewNotesEntry.make(from: state.previousSessions)
        if !entries.isEmpty {
            RecapCard {
                VStack(alignment: .leading, spacing: WarmSpacing.md) {
                    Label(String(localized: "review.flow.insights.notes.title"), systemImage: "quote.opening")
                        .font(WarmFont.headline(14))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .flipsForRightToLeftLayoutDirection(true)

                    ReviewNotesListView(entries: entries)

                    if let topics = entries.first?.topics, !topics.isEmpty,
                       let context = state.insightContextValue {
                        topicCompareRows(topics, context: context)
                    }
                }
            }
        }
    }

    /// 最新一条笔记的语义对照行。本期数用当前洞察原料现算(与收尾存
    /// `periodCount` 同一 `ReviewTopicMatching` 口径,两期可比);
    /// 不可统计的维度跳过。
    @ViewBuilder
    private func topicCompareRows(_ topics: [ReviewTopic], context: InsightContext) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Rectangle()
                .fill(WarmTheme.rowHairline)
                .frame(height: 1)

            // id 用「text + 维度」组合:AI 可能返回同 text 的两条关注点,
            // 单用 \.text 会撞 id(ForEach 丢行)。
            ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                if let current = ReviewTopicMatching.periodCount(
                    category: topic.category,
                    timeBucket: topic.timeBucket,
                    in: context.completedEvents,
                    calendar: Calendar.current
                ) {
                    Text(String(
                        format: String(localized: "review.notes.compare"),
                        Self.topicDimensionLabel(topic),
                        current,
                        topic.periodCount
                    ))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
        }
    }

    /// 对照行的维度标签:分类名优先,否则时段名。两个维度都 nil 的 topic
    /// 不会出现在存储里(prompt + 解析双侧过滤),这里只是防御。
    private static func topicDimensionLabel(_ topic: ReviewTopic) -> String {
        if let category = topic.category {
            return category.displayName
        }
        if let bucket = topic.timeBucket {
            switch bucket {
            case .morning: return String(localized: "time_bucket.morning")
            case .afternoon: return String(localized: "time_bucket.afternoon")
            case .evening, .anytime: return String(localized: "time_bucket.evening")
            }
        }
        return ""
    }

    // MARK: 问问自己(2026-09-01 从第 3 步随迁;收尾才填,且说明会被回看)

    /// 「问问自己」:纯文字输入(accessibility 兜底 + 唯一入口,见类型注释)。
    /// 答案存 `state.voiceAnswerText`(阶段 4 持久化)。标题下有领域提示行
    /// (2026-08-25 轻修④):只在快照出现过的分类里按历史会话数轮换——
    /// 承接实际复盘「心里过一遍分领域进度」的口问习惯。随输入框一起搬到
    /// 第 5 步(留在第 3 步等于轻修④跟着输入框一起失效)。
    private var askYourselfSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "review.flow.insights.ask.title"))
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                if let category = state.askDomainHintCategory {
                    Text(String(
                        format: String(localized: "review.flow.insights.ask.domain_hint"),
                        category.displayName
                    ))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

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

                // 具体承诺(docs v2:「放最后、且说清楚会被回看,才有填的理由」):
                // 收尾语义对照会把这句话提取成关注点,下次复盘跨期对照行兑现。
                Text(String(localized: "review.flow.insights.ask.promise"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
