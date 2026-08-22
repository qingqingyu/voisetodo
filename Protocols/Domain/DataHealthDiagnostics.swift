import Foundation

/// 数据体检统计结果——回答设计文档「阶段 0」的四个问题,
/// 决定洞察 01/05(依赖 `Priority.high`)何时值得启用。
/// 纯数据,无 SwiftData 依赖,DEBUG 诊断与单测共用。
struct DataHealthStats: Hashable, Sendable {
    /// 库内任务总数。
    let totalCount: Int
    /// `priority == .high` 的任务总数。
    let highPriorityCount: Int
    /// `priority == .high` 且已完成的任务数(洞察 01/05 的判据分子)。
    let highPriorityCompletedCount: Int
    /// high 任务占全部任务的比例(0...1;空库为 0)。
    let highPriorityRatio: Double
    /// `hasDueTime == true` 的任务占比(0...1;空库为 0)。
    /// 洞察 05 需要重要任务带明确钟点,否则退化用 `completedAt` 小时。
    let hasDueTimeRatio: Double
    /// 已完成任务总数。
    let completedCount: Int
    /// 已完成且带 `dueDate` 的任务数。
    let completedWithDueDateCount: Int
    /// 已完成任务的分类分布(每类 n)。
    let completedByCategory: [TodoCategory: Int]
    /// 最早一条 `createdAt` 到参考日的整周数(向下取整;空库为 0)。
    /// 洞察 06 需要 ≥4 个完整周。
    let libraryAgeWeeks: Int
}

/// 纯函数数据体检——输入 `[TodoItemData]` + 参考日期,输出统计,无副作用。
enum DataHealthAnalyzer {
    /// 对全量任务做数据体检统计。
    ///
    /// - Parameters:
    ///   - items: 全量任务(已从 SwiftData 转换好)
    ///   - now: 参考日期(库龄以此为终点)
    ///   - calendar: 日历,默认 `.current`
    /// - Returns: 统计结果;空库时各计数为 0、各比例为 0、库龄为 0
    static func analyze(
        _ items: [TodoItemData],
        asOf now: Date,
        calendar: Calendar = .current
    ) -> DataHealthStats {
        let totalCount = items.count

        let highPriority = items.filter { $0.priority == .high }
        let highPriorityCompleted = highPriority.filter(\.isCompleted)

        let hasDueTimeCount = items.filter(\.hasDueTime).count

        let completed = items.filter(\.isCompleted)
        var completedByCategory: [TodoCategory: Int] = [:]
        for item in completed {
            completedByCategory[item.category, default: 0] += 1
        }

        let libraryAgeWeeks: Int
        if let earliest = items.map(\.createdAt).min() {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: earliest),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
            libraryAgeWeeks = max(0, days) / 7
        } else {
            libraryAgeWeeks = 0
        }

        return DataHealthStats(
            totalCount: totalCount,
            highPriorityCount: highPriority.count,
            highPriorityCompletedCount: highPriorityCompleted.count,
            highPriorityRatio: totalCount == 0 ? 0 : Double(highPriority.count) / Double(totalCount),
            hasDueTimeRatio: totalCount == 0 ? 0 : Double(hasDueTimeCount) / Double(totalCount),
            completedCount: completed.count,
            completedWithDueDateCount: completed.filter { $0.dueDate != nil }.count,
            completedByCategory: completedByCategory,
            libraryAgeWeeks: libraryAgeWeeks
        )
    }
}
