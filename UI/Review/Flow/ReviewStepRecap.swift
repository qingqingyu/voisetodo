import SwiftUI
import SwiftData

/// 第 1 步 · 回顾(阶段 3;v6 视觉改版:A2 原型落地——主卡置顶逐条列表 +
/// 三数字分窗口 + 当天完成卡 + 上期笔记卡)。
/// 数字口径与出卡条件全部不变(R1:第 1/2 块=上次复盘以来,「还挂着」=全部
/// 积压;不加算式);`RecapHeroSection` / `RecapStatCard` 不再被本步使用,
/// 回顾页(`ReviewView`)继续用它们,外观零变化(R11)。
struct ReviewStepRecap: View {
    /// 上次复盘日期(2026-08-23 从回顾页入口卡移入)。nil(首次复盘)时该行隐藏。
    var lastReviewDate: Date? = nil
    /// 上次定的重点在本期快照里的结局(2026-08-25 轻修:plan-do-review 闭环)。
    /// nil(上次没置顶过)时主卡回退完成数句式。
    var lastPinnedOutcome: (completed: Int, pending: Int)? = nil
    /// 上次置顶任务的逐条快照(v6:主卡标题下逐条列出,✓/○ + 任务名 + 结局)。
    /// 已删除的置顶任务不在其中(与 `lastPinnedOutcome` 计数同口径)。
    var lastPinnedTasks: [ReviewFlowState.LastPinnedTask] = []
    /// 上期笔记原话(v5 D2 对质区):最近一条非空复盘笔记,容器从
    /// previousSessions 取。nil(上期没写)时整块隐藏——没写就没得对质,
    /// 不放占位。版面顺序=先本期事实后上期原话(D2)。
    var lastNote: String? = nil
    /// 上期笔记是否为原样保存的 AI 草稿(v6 §3.2):true 时小标题旁挂
    /// 「AI 草稿(你保留的)」chip——原样草稿冒充「用户写的」违背 v5 D9。
    var lastNoteIsUneditedAIDraft: Bool = false
    /// 对质区展开态(默认收 4 行,点击「展开全文」看完整原话——长笔记的
    /// 「原话」不能截死,对质价值就在完整原话)。
    @State private var noteExpanded = false

    @Query(
        filter: #Predicate<TodoItem> { $0.isCompleted },
        sort: [SortDescriptor(\TodoItem.completedAt, order: .reverse)]
    )
    private var completedTodos: [TodoItem]

    @Query(sort: [SortDescriptor(\TodoOccurrenceCompletion.completedAt, order: .reverse)])
    private var recurringCompletions: [TodoOccurrenceCompletion]

    @Query private var allTodos: [TodoItem]

    private let calendar = Calendar.current

    private var summary: ReviewSummary {
        // v3 拍板 1:窗口 = 上次复盘至今(与每周一的提醒节奏对齐;首次复盘
        // 回落近 7 天)。回顾页/统计页仍走 monthSummary(滚动 30 天),两窗
        // 有意不同——复盘回答「这一段做了什么」,统计页看长趋势。
        RecapSummaryBuilder.weekSummary(
            since: lastReviewDate,
            today: Date(),
            calendar: calendar,
            allTodos: allTodos.map { $0.toData() },
            completedTodos: completedTodos.map { $0.toData() },
            recurringCompletions: recurringCompletions.map {
                (id: $0.id, todoId: $0.todoId, completedAt: $0.completedAt)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                scopeHeader

                if let outcome = lastPinnedOutcome {
                    pinnedMainCard(outcome: outcome)
                } else {
                    // 无上次置顶(首次复盘/上次没选/上次选的已全删)→ 回退
                    // 完成数句式,不硬造「上次没有承诺」的空标题(v3 拍板 2)。
                    countFallbackHeader
                }

                statsSection

                sameDayCard

                if let lastNote {
                    lastNoteCard(lastNote)
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// 口径行(v3 拍板 1:窗口随上次复盘走,首次复盘是近 7 天)——文案与
    /// `weekSummary` 的回落规则必须同源,别出现「上次复盘以来」配 7 天数。
    /// 顺带承载上次复盘日期(原入口卡第四行)。v6:样式不变。
    private var scopeHeader: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Text(String(localized: lastReviewDate != nil
                ? "review.flow.recap.scope_since"
                : "review.flow.recap.scope_first"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let date = lastReviewDate {
                Text(String(
                    localized: "review.flow.recap.last_review_\(date.formatted(.dateTime.year().month().day()))"
                ))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 主卡(v6:上次定的重点)

    /// 主卡:小标题 + 一级标题(兑现判词)+ 逐条置顶列表。标题不嵌任务名
    /// (原型 A2:长任务名只会把标题拆碎,任务名自己换行)。
    private func pinnedMainCard(outcome: (completed: Int, pending: Int)) -> some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                ReviewEyebrow(text: String(localized: "review.flow.recap.pinned.title"))

                Text(String(
                    localized: "review.flow.recap.pinned_outcome_hero_\(outcome.completed + outcome.pending)_\(outcome.completed)"
                ))
                    .font(WarmFont.title(24))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ReviewHeroPinnedOutcome")

                pinnedRows
            }
        }
    }

    /// 逐条置顶列表:✓(已完成,绿)/ ○(未完成)+ 任务名 + 右侧灰字结局。
    private var pinnedRows: some View {
        VStack(spacing: WarmSpacing.sm) {
            Rectangle()
                .fill(WarmTheme.rowHairline)
                .frame(height: 1)

            ForEach(lastPinnedTasks) { task in
                pinnedRow(task)
            }
        }
        .padding(.top, WarmSpacing.xxs)
    }

    private func pinnedRow(_ task: ReviewFlowState.LastPinnedTask) -> some View {
        HStack(alignment: .top, spacing: WarmSpacing.sm) {
            pinnedMarker(isCompleted: task.isCompleted)

            Text(task.title)
                .font(WarmFont.body(15))
                .foregroundColor(task.isCompleted ? WarmTheme.textSecondary : WarmTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: WarmSpacing.xs)

            Text(String(localized: task.isCompleted
                ? "review.flow.recap.pinned.done"
                : "review.flow.recap.pinned.open"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .padding(.top, 2)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// ✓ / ○ 圆标(20pt;完成=绿底白勾,未完成=灰圈)。
    private func pinnedMarker(isCompleted: Bool) -> some View {
        ZStack {
            if isCompleted {
                Circle()
                    .fill(WarmTheme.success)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .strokeBorder(WarmTheme.textMuted, lineWidth: 2)
            }
        }
        .frame(width: 20, height: 20)
        .padding(.top, 1)
    }

    /// 无上次置顶的回退头:完成数句式(v3 拍板 2 的回退路径,字体改一级
    /// 无衬线、颜色 textPrimary——v6 §2 第 1 步)。
    private var countFallbackHeader: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Text(String(localized: "review.hero.count_\(summary.total)"))
                .font(WarmFont.title(24))
                .foregroundColor(WarmTheme.textPrimary)
                .accessibilityIdentifier("ReviewHeroCount")

            Text(summary.periodLabel)
                .font(WarmFont.caption(14))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 三个数字(v6:分窗口成组)

    /// 一行三块:「本期完成」「新增」白卡 +「还挂着」深色重点块(稍宽)。
    /// 下方一行灰色说明,左对前两块「上次复盘以来」,右对第三块「全部积压」
    /// (R1:两组口径不同必须说出口;**不写算式**)。
    /// 原 `review.stat.pending_note` 说明行不再显示(回顾页不受影响)。
    private var statsSection: some View {
        VStack(spacing: WarmSpacing.xs) {
            GeometryReader { proxy in
                let unit = (proxy.size.width - WarmSpacing.xs * 2) / 3.25
                HStack(spacing: WarmSpacing.xs) {
                    statBlock(
                        value: "\(summary.total)",
                        label: String(localized: "review.stat.done")
                    )
                    .frame(width: unit)

                    statBlock(
                        value: "\(summary.createdCount)",
                        label: String(localized: "review.stat.created")
                    )
                    .frame(width: unit)

                    keyStatBlock(
                        value: "\(summary.pendingOneOffCount)",
                        label: String(localized: "review.stat.pending")
                    )
                    .frame(width: unit * 1.25)
                }
            }
            .frame(height: 76)

            GeometryReader { proxy in
                let unit = (proxy.size.width - WarmSpacing.xs * 2) / 3.25
                HStack(spacing: WarmSpacing.xs) {
                    Text(String(localized: "review.flow.recap.stats.window"))
                        .frame(width: unit * 2 + WarmSpacing.xs, alignment: .leading)

                    Text(String(localized: "review.flow.recap.stats.backlog"))
                        .frame(width: unit * 1.25, alignment: .leading)
                }
            }
            .frame(height: 16)
            .font(WarmFont.caption(12))
            .foregroundColor(WarmTheme.textMuted)
        }
    }

    /// 普通统计块:大数字(24pt)+ 标签,白卡。
    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Text(verbatim: value)
                .font(WarmFont.title(24))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, WarmSpacing.sm)
        .padding(.vertical, WarmSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
        )
    }

    /// 重点统计块(「还挂着」):深色底(textPrimary)+ 反色字,数字 28pt。
    private func keyStatBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Text(verbatim: value)
                .font(WarmFont.title(28))
                .foregroundColor(WarmTheme.background)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.background.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, WarmSpacing.sm)
        .padding(.vertical, WarmSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                .fill(WarmTheme.textPrimary)
        )
    }

    // MARK: 当天完成卡

    /// 「其中 N 件是当天记下、当天做完的」+ 判词放进一张卡。出卡条件不变
    /// (`showsSameDayLine` / `showsSameDayJudgment` 门槛含同口径分母,v3)。
    private var sameDayCard: some View {
        Group {
            if summary.showsSameDayLine {
                RecapCard {
                    VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                        Text(String(localized: "review.hero.sameday_\(summary.sameDayCount)"))
                            .font(WarmFont.headline(16))
                            .foregroundColor(WarmTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if summary.showsSameDayJudgment {
                            Text(String(localized: "review.hero.sameday_judgment"))
                                .font(WarmFont.body(14))
                                .foregroundColor(WarmTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: 上期你写了(D2 对质区)

    /// 对质区卡:引用样式不变(左侧细线 + verbatim);4 行折叠,展开入口是
    /// 可见的文字按钮「展开全文 / 收起」(v6 §2;整卡点按展开的现有行为保留)。
    /// 原样保存的 AI 草稿在小标题旁挂 chip(§3.2)。
    private func lastNoteCard(_ note: String) -> some View {
        // 与原型同尺的「可能超 4 行」判定:多段或超 60 字符才给展开按钮——
        // 短笔记的「展开全文」是噪音。
        let isLong = note.contains("\n") || note.count > 60
        return RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                HStack(spacing: WarmSpacing.sm) {
                    ReviewEyebrow(text: String(localized: "review.flow.recap.last_note.title"))
                        .layoutPriority(1)

                    if lastNoteIsUneditedAIDraft {
                        AIKeptDraftChip()
                    }
                }

                HStack(alignment: .top, spacing: WarmSpacing.sm) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(WarmTheme.textMuted.opacity(0.4))
                        .frame(width: 2)

                    Text(verbatim: note)
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(noteExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }

                if isLong {
                    Button {
                        withAnimation(WarmAnimation.springStandard) { noteExpanded.toggle() }
                    } label: {
                        Text(String(localized: noteExpanded
                            ? "review.flow.recap.last_note.collapse"
                            : "review.flow.recap.last_note.expand"))
                            .font(WarmFont.headline(13))
                            .foregroundColor(WarmTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ReviewRecapLastNoteExpand")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isLong else { return }
            withAnimation(WarmAnimation.springStandard) { noteExpanded.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(String(localized: "review.flow.recap.last_note.expand_hint"))
        .accessibilityIdentifier("ReviewRecapLastNote")
    }
}
