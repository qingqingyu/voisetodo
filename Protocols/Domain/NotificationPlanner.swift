import Foundation

/// 一条到点提醒的计划（纯数据，供调度器排程）。
struct PlannedReminder: Equatable, Sendable {
    let id: UUID
    let fireDate: Date
    let title: String
    let body: String?
}

/// 从待办列表算出"应存在的到点提醒集合"的纯函数。
/// 只提醒**带明确钟点、未完成、非规律、未过期**的待办；结果按触发时间升序、截断到 limit。
/// 与调度器解耦，便于单测。
enum NotificationPlanner {
    static func plannedReminders(
        from todos: [TodoItemData],
        now: Date,
        limit: Int = 60
    ) -> [PlannedReminder] {
        todos
            .compactMap { todo -> PlannedReminder? in
                guard !todo.isCompleted,
                      todo.hasDueTime,
                      todo.recurrenceRule == nil,
                      let due = todo.dueDate,
                      due > now else {
                    return nil
                }
                let trimmedDetail = todo.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PlannedReminder(
                    id: todo.id,
                    fireDate: due,
                    title: todo.title,
                    body: (trimmedDetail?.isEmpty ?? true) ? nil : trimmedDetail
                )
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
