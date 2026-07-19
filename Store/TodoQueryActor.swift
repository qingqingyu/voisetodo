import Foundation
import SwiftData

/// 只读重查询的后台执行器。
///
/// 把 `TodoStore`（`@MainActor`）里会阻塞主线程的 SwiftData fetch 下沉到独立 actor：
/// 每个 `@ModelActor` 持有自己专属的 `ModelContext`，跑在 actor 的 executor 上，
/// 与主线程上下文共享同一个持久化存储；主线程写操作保存后，这里 fetch 能读到最新数据。
///
/// - Invariants:
///   - 只做**只读**查询，绝不在此处写库（写操作仍走 `TodoStore` 主线程，避免并发写冲突）。
///   - 跨 actor 边界只返回值类型 DTO（`TodoItemData` 等），不返回 SwiftData 模型对象。
@ModelActor
actor TodoQueryActor {
    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）。
    /// - Returns: 按 sortOrder 升序的待处理条目 DTO。
    func pendingItems() throws -> [TodoItemData] {
        let startedAt = Date()
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.needsAIProcessing },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            VoiceTodoLog.store.debug("query_actor.pending.fetch_success count=\(items.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return items.map { $0.toData() }
        } catch {
            // 错误显式传播原则：不静默吞掉失败，向上抛出而不是返回空数组掩盖问题。
            // raw SwiftData 错误通过 VoiceTodoError.wrapStorage 归一化为 .storageReadFailed，
            // 让 AppCoordinator.handleError 命中 `.storageReadFailed` 显示统一文案。
            VoiceTodoLog.store.error("query_actor.pending.fetch_failed durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    /// 获取最近 N 条未完成待办（Widget / 桌面用）。
    /// - Parameter limit: 返回数量限制。
    /// - Returns: 当天可见的未完成待办 DTO。
    func recentUncompleted(limit: Int) throws -> [TodoItemData] {
        let startedAt = Date()
        guard limit > 0 else { return [] }

        let descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        let today = DayClock.startOfUserDay(for: Date())
        do {
            let items = try modelContext.fetch(descriptor)
            let completedToday = try fetchCompletionKeys(from: today, to: today)
            let visible = WidgetTodoFilter.visibleTodos(
                from: items.map { $0.toData() },
                completionKeys: completedToday,
                today: today,
                limit: limit
            )
            VoiceTodoLog.store.debug("query_actor.recent_uncompleted.fetch_success fetched=\(items.count) visible=\(visible.count) limit=\(limit) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return visible
        } catch {
            VoiceTodoLog.store.error("query_actor.recent_uncompleted.fetch_failed limit=\(limit) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    /// 获取日期区间内完成记录的 key 集合（供 `WidgetTodoFilter` 判断当天 occurrence 是否完成）。
    private func fetchCompletionKeys(from startDate: Date, to endDate: Date) throws -> Set<String> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        let descriptor = FetchDescriptor<TodoOccurrenceCompletion>(
            predicate: #Predicate { completion in
                completion.occurrenceDate >= start && completion.occurrenceDate < end
            }
        )
        let completions = try modelContext.fetch(descriptor)
        return Set(completions.map(\.occurrenceKey))
    }

    /// 获取日期区间内实际出现的待办（展开重复规则 / 对齐 dueDate）。
    /// - Parameters:
    ///   - startDate: 区间开始。
    ///   - endDate: 区间结束。
    /// - Returns: 区间内按日期 + sortOrder 排序的 occurrence 列表。
    /// - Note: actor 内自行 fetch TodoItem，不依赖主线程 todos 缓存，确保读到最新已保存数据。
    func calendarOccurrences(from startDate: Date, to endDate: Date) throws -> [TodoOccurrenceData] {
        let startedAt = Date()
        let calendar = Calendar.current
        let days = Self.daysBetween(startDate, endDate, calendar: calendar)
        guard let firstDay = days.first, let lastDay = days.last else { return [] }

        let descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        do {
            let items = try modelContext.fetch(descriptor)
            let completionKeys = try fetchCompletionKeys(from: firstDay, to: lastDay)
            let todos = items.map { $0.toData() }

            var occurrences: [TodoOccurrenceData] = []
            for todo in todos {
                if let recurrenceRule = todo.recurrenceRule {
                    let start = todo.dueDate ?? todo.createdAt
                    for day in days where recurrenceRule.occurs(on: day, startDate: start, calendar: calendar) {
                        let key = TodoOccurrenceCompletion.key(todoId: todo.id, occurrenceDate: day, calendar: calendar)
                        var occurrenceTodo = todo
                        occurrenceTodo.isCompleted = completionKeys.contains(key)
                        occurrences.append(TodoOccurrenceData(
                            todo: occurrenceTodo,
                            occurrenceDate: day,
                            isCompleted: completionKeys.contains(key)
                        ))
                    }
                } else if let dueDate = todo.dueDate,
                          days.contains(where: { calendar.isDate($0, inSameDayAs: dueDate) }) {
                    let day = calendar.startOfDay(for: dueDate)
                    occurrences.append(TodoOccurrenceData(
                        todo: todo,
                        occurrenceDate: day,
                        isCompleted: todo.isCompleted
                    ))
                }
            }

            return occurrences.sorted { lhs, rhs in
                if lhs.occurrenceDate != rhs.occurrenceDate {
                    return lhs.occurrenceDate < rhs.occurrenceDate
                }
                return lhs.todo.sortOrder < rhs.todo.sortOrder
            }
        } catch {
            VoiceTodoLog.store.error("query_actor.calendar.fetch_failed start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    /// 计算区间内按日历日对齐的天数序列（含两端）。
    private static func daysBetween(_ startDate: Date, _ endDate: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var days: [Date] = []
        var current = start
        while current <= end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }
}
