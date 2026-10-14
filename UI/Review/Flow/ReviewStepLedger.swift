import SwiftUI

/// 第 5 步 · 收尾账本(v2 改版 2026-09-01;v6 A2 视觉改版:顶部小结去卡改
/// 一段左对齐文字、「问问自己」卡重排 + 麦克风内嵌输入框、历次笔记全文、
/// 下次复盘一行灰字)。收尾是确认,不是审判——数字口径与出卡条件全不变
/// (拍板 4:v3 拍板 10 三态;R10:下次复盘固定下周一,不可改)。
///
/// - 「你决定了 N 件」(三级标题)+ 明细一行灰字,零值不出;全零态文案不变。
///   「推后 N」只在明细里出现一次:`.decided` 态不再单独渲染 someday_ 行
///   (`.batchOnly` 态仍用它当主句)。`summary_caption` 去掉。
/// - 「问问自己」卡:小标题 → 领域问题(二级)→ AI 草稿标记行 → 输入框
///   (麦克风内嵌右下角)→ 灰字「下次复盘会给你看」。
/// - 历次笔记全文显示(与回顾页共用 `ReviewNotesListView`,参数化全文)。
/// - 答案持久化不变(`ReviewFlowState.voiceAnswerText`,阶段 4)。
struct ReviewStepLedger: View {
    @Bindable var state: ReviewFlowState
    /// 草稿是否仍是 AI 原样(D9:用户一动笔即退场)。init 播种:预填发生
    /// 在 onAppear(此时 deepReadResult 可能还没回来,种子恒 false,预填时再置)。
    @State private var showingAIDraftHint = false
    /// 是否已预填过(D9「首次进入且笔记为空」):用户手动清空笔记后回跳
    /// 再进第 5 步,onAppear 会重跑——不设防会把用户刚删掉的草稿塞回去。
    @State private var hasPrefilledAIDraft = false
    /// 「问问自己」麦克风(v5 T4/D8 同款复用;v6:外观换成输入框内嵌,
    /// 状态机共用 `ReviewMicSession`)。nil → 麦克风不渲染(注入链缺失/
    /// 降级),手打兜底始终在场。
    var voiceInput: (any VoiceInputProtocol)? = nil
    /// 错误显式传播(S2:权限拒绝/转写失败如实上报,降级手打不静默)。
    /// 必传无默认——默认 `{ _ in }` 会静默吞错,与 S2 矛盾(与
    /// `ReviewStepTriage.onError` 同口径)。
    let onError: (Error) -> Void
    /// AI 同意 gate(E6 三入口同 gate:录音起步前)。
    var ensureConsent: (() async -> Bool)? = nil

    /// 内嵌麦克风的会话状态(与拆小 sheet 的 ReviewMicRow 同一状态机)。
    @State private var micSession: ReviewMicSession?

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
                summarySection
                askYourselfSection
                crossPeriodCard
                nextReviewLine
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
        .onAppear {
            prefillAIDraftIfNeeded()
            prepareMicSession()
        }
        .onDisappear {
            // 第 5 步在录时退出(返回上一步/xmark 关闭/完成落 cover)要停录音
            // ——录音机与首页共享同一实例(coordinator.reviewVoiceInput),不复
            // 位会把「还在收音」泄漏给封面下的首页,直到静音 watchdog 超时才停。
            // 与拆小 sheet 的 stopSplitSession(v4)同一模式,同一理由。
            if voiceInput?.isRecording == true {
                voiceInput?.cancelRecordingByUser()
            }
        }
        .onChange(of: state.voiceAnswerText) { _, newValue in
            // 用户动笔(与预填不同)→ AI 草稿标记退场;清空也退场
            if showingAIDraftHint, newValue != state.deepReadResult?.draft {
                showingAIDraftHint = false
            }
        }
    }

    /// 内嵌麦克风会话:注入链在场时创建(外观 overlay 从这里取)。
    private func prepareMicSession() {
        guard micSession == nil, let voiceInput else { return }
        micSession = ReviewMicSession(voiceInput: voiceInput)
    }

    // MARK: 顶部小结(v6:去卡,一段左对齐文字)

    /// 三态判定收敛在 `state.ledgerCardContent`(v3 拍板 10;边界:全零且
    /// 零积压不出),本视图只按态渲染。`.decided` → 「你决定了 N 件」(三级)
    /// + 明细一行灰字;`.batchOnly` → someday_ 句当主句;`.noneDecided` →
    /// 全零态文案不变。`summary_caption` 不再显示。
    @ViewBuilder
    private var summarySection: some View {
        switch state.ledgerCardContent {
        case .decided:
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(String(localized: "review.flow.ledger.decided_\(state.decidedCount)"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !detailFragments().isEmpty {
                    Text(verbatim: detailFragments().joined(separator: " · "))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarmSpacing.xxs)
        case .batchOnly:
            // 零决定但有批量推后 → 只出批量行(someday_ 在此仍是主句;主句已
            // 说「推后」,明细不再重复它——「推后 N」整屏只出现一次)。
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(String(localized: "review.flow.ledger.someday_\(state.ledger.somedayCount)"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !detailFragments(excludingSomeday: true).isEmpty {
                    Text(verbatim: detailFragments(excludingSomeday: true).joined(separator: " · "))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarmSpacing.xxs)
        case .noneDecided:
            // 全零态(v3 拍板 10):N 用 init 快照(与 ② 屏 lede 同源同恒定),
            // 回答「那 25 件去哪了」;文案不变。
            Text(String(localized: "review.flow.ledger.decided_none_\(state.initialBacklogCount)"))
                .font(WarmFont.headline(16))
                .foregroundColor(WarmTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WarmSpacing.xxs)
        case .omitted:
            EmptyView()
        }
    }

    /// 决策明细一行小字:只拼非零片段(docs v2 例:「今天做 2 · 拆小 1 · 下周 3 · 推后 27」)。
    /// v6:「推后 N」只在明细里出现一次(decided 态不再叠加 someday_ 单独行;
    /// batchOnly 态主句已是 someday_,经 `excludingSomeday` 再排除一次)。
    private func detailFragments(excludingSomeday: Bool = false) -> [String] {
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
        if ledger.somedayCount > 0, !excludingSomeday {
            parts.append(String(localized: "review.flow.ledger.detail.someday_\(ledger.somedayCount)"))
        }
        if ledger.pinnedCount > 0 {
            parts.append(String(localized: "review.flow.ledger.detail.pinned_\(ledger.pinnedCount)"))
        }
        return parts
    }

    // MARK: 下次复盘(v6:去卡,居中一行灰字 + 时钟图标,不可点——R10)

    private var nextReviewLine: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "clock")
                .font(.system(size: 14))
                .flipsForRightToLeftLayoutDirection(true)

            Text(String(
                localized: "review.flow.ledger.next_review_\(nextReviewDate.formatted(.dateTime.month().day().weekday(.abbreviated)))"
            ))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(WarmFont.caption(13))
        .foregroundColor(WarmTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.top, WarmSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    // MARK: 历次笔记卡(2026-08-23 拍板「全量可见」;2026-09-02 从第 3 步随迁至此)

    /// 「历次复盘,你说过」:全部写过笔记的会话,新→旧,v6 全文显示。没有
    /// 笔记时不显示。最新一条若带语义对照关注点(收尾 AI 提取回写),在其下
    /// 渲染对照行(「本期 N 件(上期 M 件)」纯本地现算);洞察原料缺失
    /// (降级跳过/加载失败)时对照行不出,笔记列表照常。
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

                    ReviewNotesListView(entries: entries, showsFullText: true)

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
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: 问问自己(v6 A2:小标题 → 领域问题 → 草稿标记 → 输入框(内嵌麦克风)→ 承诺)

    /// 「问问自己」卡:有领域提示时小标题「问问自己」+ 二级标题 = 领域问题;
    /// 无领域提示时用「问问自己」本身作标题、不重复小标题。AI 草稿标记行
    /// (仅预填且未改动,灰色 + 小星标)在输入框上方;麦克风是输入框右下角
    /// 的珊瑚色实心圆按钮。答案存 `state.voiceAnswerText`(阶段 4 持久化)。
    private var askYourselfSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                if let category = state.askDomainHintCategory {
                    ReviewEyebrow(text: String(localized: "review.flow.insights.ask.title"))

                    Text(String(
                        format: String(localized: "review.flow.insights.ask.domain_hint"),
                        category.displayName
                    ))
                        .font(WarmFont.headline(19))
                        .foregroundColor(WarmTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(localized: "review.flow.insights.ask.title"))
                        .font(WarmFont.headline(19))
                        .foregroundColor(WarmTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showingAIDraftHint {
                    // AI 草稿标记行(D9:用户一动笔即退场):灰色 + 小星标。
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))

                        Text(String(localized: "review.flow.note.draft.hint"))
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
                    .accessibilityIdentifier("ReviewFlowAIDraftHint")
                }

                noteEditor

                // 具体承诺(docs v2:「放最后、且说清楚会被回看,才有填的理由」):
                // 收尾语义对照会把这句话提取成关注点,下次复盘跨期对照行兑现。
                Text(String(localized: "review.flow.insights.ask.promise"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 笔记输入框(麦克风内嵌右下角;录音中左下「在听…」+「取消」)。
    private var noteEditor: some View {
        TextEditor(text: $state.voiceAnswerText)
            .font(WarmFont.body(16))
            .frame(minHeight: 124)
            .scrollContentBackground(.hidden)
            .padding(.leading, WarmSpacing.sm)
            .padding(.top, WarmSpacing.sm)
            .padding(.trailing, WarmSpacing.sm)
            .padding(.bottom, 60)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                    .fill(WarmTheme.inputFieldBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                            .strokeBorder(
                                micSession?.isRecording == true ? WarmTheme.primary : WarmTheme.rowHairline,
                                lineWidth: micSession?.isRecording == true ? 1.5 : 1
                            )
                    )
            )
            .overlay(alignment: .topLeading) {
                if state.voiceAnswerText.isEmpty {
                    Text(String(localized: "review.flow.insights.ask.placeholder"))
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.textMuted)
                        .padding(WarmSpacing.sm)
                        .padding(.top, WarmSpacing.xxs)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let micSession {
                    ReviewMicInputOverlay(session: micSession)
                        .padding(WarmSpacing.xs)
                        .onAppear {
                            micSession.bind(
                                onError: onError,
                                onAdopt: { adoptTranscriptIntoNote($0) },
                                // E10:中断/错误时已说出的部分转写预填笔记框,不丢弃。
                                onAdoptPartialOnError: { adoptTranscriptIntoNote($0) },
                                // E6:录音起点过同意 gate(与首页 startRecording 同口径)。
                                ensureConsent: ensureConsent
                            )
                        }
                }
            }
            .accessibilityIdentifier("ReviewFlowAskYourself")
    }

    /// 转写采纳进「问问自己」笔记框(v5 T4):已有内容则换行接续——笔记是
    /// 自由文本,多段转写逐行追加比挤一行可读;VoiceOver 由 TextEditor 承载。
    /// AI 草稿预填(v5 T5/D9):首次进入且笔记为空+深读草稿非空 → 预填并
    /// 挂标记;用户改/删/说一句(voiceAnswerText 变化)标记退场。存进
    /// voiceNote 的原文是否为原样草稿,由 buildSession 的 §3.2 判定落库。
    private func prefillAIDraftIfNeeded() {
        guard !hasPrefilledAIDraft,
              state.voiceAnswerText.isEmpty,
              let draft = state.deepReadResult?.draft,
              !draft.isEmpty else { return }
        state.voiceAnswerText = draft
        showingAIDraftHint = true
        hasPrefilledAIDraft = true
    }

    private func adoptTranscriptIntoNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if state.voiceAnswerText.isEmpty {
            state.voiceAnswerText = trimmed
        } else {
            state.voiceAnswerText += "\n" + trimmed
        }
    }
}
