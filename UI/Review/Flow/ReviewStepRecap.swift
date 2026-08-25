import SwiftUI
import SwiftData

/// 第 1 步 · 回顾(阶段 3):复用 `RecapComponents`,压到 10 秒能看完。
/// 只放口径行 + Hero + stats + 分类横条(每日趋势/最忙一天留在回顾页,这里是「快扫」)。
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
                RecapHeroSection(summary: summary)
                RecapStatsRow(summary: summary)
                RecapCategoryChartSection(byCategory: summary.byCategory)
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// 口径行:点明本流程固定「近 30 天」——回顾页顶部的周/月切换器管不到复盘,
    /// 消歧义小字 2026-08-23 从入口卡移入(放卡里读起来像废话,放流程首屏才有上下文)。
    /// 顺带承载上次复盘日期(原入口卡第四行)。
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

            // 数据来自流程启动时注入的快照(与本步其他 @Query 区块的实时聚合
            // 口径不同——有意的快照语义:结局是对「上次定的那批」的静态对账)。
            if let outcome = lastPinnedOutcome {
                Text(String(
                    format: String(localized: "review.flow.recap.last_pinned_outcome"),
                    outcome.completed,
                    outcome.pending
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
