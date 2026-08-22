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
            // 与 App「没能识别」分组同口径(HomeCalendarState):原文兜底(.rawFallback)/
            // 未解析(.unparsed)条目不是普通待办,不进任何 widget。它们没有结构化字段、
            // 无 dueDate、sortOrder 又最新(新条目排在最前),放进来会抢占锁屏第一行,
            // 且超长原文会把整体字号拖到最小档。原文数据仍在 App「没能识别」组里,不丢。
            guard data.extractionOutcome == .parsed else { continue }
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
            // 跨天事件:用 TodoSpan.covers 判断该天是否落在事件覆盖区间内
            if let dueDate = data.dueDate,
               TodoSpan.covers(day: day, dueDate: dueDate, eventEndDate: data.eventEndDate, calendar: calendar) {
                scheduled.append(data)
            }
        }

        return Array((scheduled + unscheduled).prefix(limit))
    }
}
