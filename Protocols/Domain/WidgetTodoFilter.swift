import Foundation

enum WidgetTodoFilter {
    static func visibleTodos(
        from items: [TodoItemData],
        completionKeys: Set<String>,
        today: Date,
        limit: Int,
        calendar: Calendar = .current,
        recentCompletionCutoff: Date? = nil,
        completionDatesByKey: [String: Date] = [:]
    ) -> [TodoItemData] {
        guard limit > 0 else { return [] }

        // day 用"用户日"起点（如 hour=3 时是当日 03:00）。
        // 下游 rule.occurs / TodoOccurrenceData.dayKey 内部都会 startOfDay 归一化为该自然日 0 点，
        // 所以传 userDay 起点等价于判断"用户日开始的那一自然日"——与 occurrenceKey 存储语义一致。
        let day = DayClock.startOfUserDay(for: today, calendar: calendar)
        var scheduled: [TodoItemData] = []
        var unscheduled: [TodoItemData] = []

        for item in items {
            var data = item
            if let rule = data.recurrenceRule {
                guard rule.occurs(on: day, startDate: data.dueDate ?? data.createdAt, calendar: calendar) else {
                    continue
                }
                let key = "\(data.id.uuidString)-\(TodoOccurrenceData.dayKey(for: day, calendar: calendar))"
                if completionKeys.contains(key) {
                    guard let cutoff = recentCompletionCutoff,
                          let completedAt = completionDatesByKey[key],
                          completedAt >= cutoff else {
                        continue
                    }
                    data.isCompleted = true
                    scheduled.append(data)
                    continue
                }
                data.isCompleted = false
                scheduled.append(data)
                continue
            }
            if data.isCompleted {
                guard let cutoff = recentCompletionCutoff,
                      let completedAt = data.completedAt,
                      completedAt >= cutoff else {
                    continue
                }
            }
            if data.dueDate == nil {
                unscheduled.append(data)
                continue
            }
            if calendar.isDate(data.dueDate ?? day, inSameDayAs: day) {
                scheduled.append(data)
            }
        }

        return Array((scheduled + unscheduled).prefix(limit))
    }
}
