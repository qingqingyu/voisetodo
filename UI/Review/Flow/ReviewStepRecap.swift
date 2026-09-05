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
        RecapSummaryBuilder.monthSummary(
            today: Date(),
            calendar: calendar,
            // 标签锚定「近 30 天」(2026-09-04 拍板 B2):滚动窗口配日历月名是
            // 错配,且统计页 Hero 已同口径——两处标签/数字一致。
            periodLabel: String(localized: "review.window.last30d"),
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
                RecapHeroSection(summary: summary, promotesSameDay: true, heroContent: heroContent)
                RecapEvidenceRow(summary: summary)
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// Hero 主标题(v3 拍板 2):有上次置顶结局 → 兑现判词;nil(首次复盘 /
    /// 上次没置顶 / 上次置顶的已全删)→ 回退完成数句式,不硬造空承诺文案。
    /// 数据来自流程启动时注入的快照(与本步其他 @Query 区块的实时聚合口径
    /// 不同——有意的快照语义:结局是对「上次定的那批」的静态对账)。
    private var heroContent: RecapHeroContent {
        guard let outcome = lastPinnedOutcome else { return .countSummary }
        return .pinnedOutcome(total: outcome.completed + outcome.pending, completed: outcome.completed)
    }

    /// 口径行:点明本流程固定「近 30 天」——回顾页顶部的周/月切换器管不到复盘,
    /// 消歧义小字 2026-08-23 从入口卡移入(放卡里读起来像废话,放流程首屏才有上下文)。
    /// 顺带承载上次复盘日期(原入口卡第四行)。
    /// (v3 拍板 2:原「上次定的重点」11pt 闭环行升格为 Hero 主标题,此处不再重复。)
    private var scopeHeader: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Text(String(localized: "review.flow.recap.scope"))
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
}
