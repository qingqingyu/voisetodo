import SwiftUI
import SwiftData

/// 第 1 步 · 回顾(阶段 3):复用 `RecapComponents`,压到 10 秒能看完。
/// 只放 Hero + stats + 分类横条(每日趋势/最忙一天留在回顾页,这里是「快扫」)。
struct ReviewStepRecap: View {
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
                RecapHeroSection(summary: summary)
                RecapStatsRow(summary: summary)
                RecapCategoryChartSection(byCategory: summary.byCategory)
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }
}
