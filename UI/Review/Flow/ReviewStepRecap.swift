import SwiftUI
import SwiftData

/// 第 1 步 · 回顾(阶段 3;2026-09-01 v2 改版:从数字墙改成判词)。
/// 只放口径行 + Hero(sameDay 判词主体化)+ 三数证据行(完成/新增/还挂着)。
/// streak 卡与分类横条从本步下岗(拍板 5 /「分类是描述不是判断」);
/// 组件不删——回顾页(`ReviewView`)仍在用,那里才是给人随手看描述的地方
/// (审阅缺口 A:两页共用组件,回顾页行为零变化)。
struct ReviewStepRecap: View {
    /// 上次复盘日期(2026-08-23 从回顾页入口卡移入)。nil(首次复盘)时该行隐藏。
    var lastReviewDate: Date? = nil
    /// 上次定的重点在本期快照里的结局(2026-08-25 轻修:plan-do-review 闭环)。
    /// nil(上次没置顶过)时该行隐藏。
    var lastPinnedOutcome: (completed: Int, pending: Int)? = nil
    /// 上期笔记原话(v5 D2 对质区):最近一条非空复盘笔记,容器从
    /// previousSessions 取。nil(上期没写)时整块隐藏——没写就没得对质,
    /// 不放占位。版面顺序=先本期事实(Hero/证据行)后上期原话(D2)。
    var lastNote: String? = nil
    /// 对质区展开态(默认收 4 行,点击展开全文——长笔记的「原话」不能截死,
    /// 对质价值就在完整原话)。
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
                // Hero 三态判定收在 `RecapHeroContent.make`(v3 拍板 2,可单测):
                // 有上次置顶结局 → 兑现判词;nil → 回退完成数句式。数据来自流程
                // 启动时注入的快照(与本步其他 @Query 区块的实时聚合口径不同——
                // 有意的快照语义:结局是对「上次定的那批」的静态对账)。
                RecapHeroSection(
                    summary: summary,
                    promotesSameDay: true,
                    heroContent: RecapHeroContent.make(lastPinnedOutcome: lastPinnedOutcome)
                )
                RecapEvidenceRow(summary: summary)

                // 对质区(v5 D2):「上期你写了」+中性引用——先本期事实后上期
                // 原话;框架文案禁差距评判语句(验收=负面笔记首屏无指责性表述),
                // 引用样式中性(左侧细线+原文 verbatim,不是引用语气的弯引号
                // 装饰——克制,原话自己说话)。
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
    /// 顺带承载上次复盘日期(原入口卡第四行)。
    /// (v3 拍板 2:原「上次定的重点」11pt 闭环行升格为 Hero 主标题,此处不再重复。)
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

    /// 对质区卡(D2/D9):全量原话逐条 lineLimit+minimumScaleFactor(文本
    /// 布局规则),点按展开/收起;VoiceOver 整块 combine 成一句。
    private func lastNoteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            Text(String(localized: "review.flow.recap.last_note.title"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(alignment: .top, spacing: WarmSpacing.sm) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(WarmTheme.textMuted.opacity(0.4))
                    .frame(width: 2)

                Text(verbatim: note)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(noteExpanded ? nil : 4)
                    .minimumScaleFactor(noteExpanded ? 1 : 0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
        }
        .padding(WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(WarmAnimation.springStandard) { noteExpanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "review.flow.recap.last_note.expand_hint"))
        .accessibilityIdentifier("ReviewRecapLastNote")
    }
}
