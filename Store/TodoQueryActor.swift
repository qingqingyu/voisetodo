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
            // 已划掉(abandonedAt != nil)的任务从日历 occurrence 源头排除:
            // 月网格 / 今日列表 / 周条图例全部消费这里的输出,一处过滤全覆盖。
            let todos = items.filter { $0.abandonedAt == nil }.map { $0.toData() }

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
                } else if let dueDate = todo.dueDate {
                    // 跨天事件:用 TodoSpan.coveredDays 展开为 per-day occurrence,
                    // 与查询窗口 days 求交后逐日 append,带上 spanIndex/spanCount。
                    // ⚠️ spanCount 是事件总天数(不是窗口内天数),跨月时"第 2/4 天"才不会算错。
                    let covered = TodoSpan.coveredDays(
                        dueDate: dueDate,
                        eventEndDate: todo.eventEndDate,
                        calendar: calendar
                    )
                    let spanCount = covered.count
                    for (spanIndex, spanDay) in covered.enumerated() {
                        guard days.contains(where: { calendar.isDate($0, inSameDayAs: spanDay) }) else { continue }
                        occurrences.append(TodoOccurrenceData(
                            todo: todo,
                            occurrenceDate: spanDay,
                            isCompleted: todo.isCompleted,
                            spanIndex: spanIndex,
                            spanCount: spanCount
                        ))
                    }
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

    /// 区间内完成的「无安排」任务(dueDate == nil && recurrenceRule == nil),按 completedAt 倒序。
    /// 供首页「已完成」分区按需加载工作集(近 `TodoStore.completedWindowDays` 天)之外的历史数据,
    /// 口径与 `HomeCalendarState.completedUnscheduledTodos` 严格一致:
    ///   - 过滤:`isCompleted && dueDate == nil && recurrenceRule == nil`
    ///   - 排序:`completedAt` 倒序(`.distantPast` 兜底 nil,与 HomeCalendarState.swift:188 一致)
    /// - Parameters:
    ///   - startDate: 区间开始(闭区间,通常为月初用户日起点)
    ///   - endDate: 区间结束(开区间,通常为下月初用户日起点)
    /// - Returns: 区间内匹配的 TodoItemData(按 completedAt 倒序)
    /// - Throws: `VoiceTodoError.storageReadFailed` 数据库读取错误
    /// - Note: 谓词 `isCompleted && completedAt >= startDate && completedAt < endDate` 命中
    ///   Step 1 加的 `isCompleted` / `completedAt` 索引,代价与工作集大小无关。
    func completedUnscheduled(from startDate: Date, to endDate: Date) throws -> [TodoItemData] {
        let startedAt = Date()
        // SwiftData #Predicate 不支持 ForcedUnwrap(`!`) 和 inline 静态成员(如 `.distantPast`);
        // 必须把常量提到闭包外作为局部 let,才能在谓词里用 `??` 兜底 Optional。
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                $0.isCompleted
                && ($0.completedAt ?? distantPast) >= startDate
                && ($0.completedAt ?? distantFuture) < endDate
            }
        )
        do {
            let items = try modelContext.fetch(descriptor)
            let filtered = items
                .filter { $0.dueDate == nil && $0.recurrenceRule == nil }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .map { $0.toData() }
            VoiceTodoLog.store.debug("query_actor.completed_unscheduled.fetch_success range_start=\(startDate.ISO8601Format(), privacy: .public) range_end=\(endDate.ISO8601Format(), privacy: .public) raw=\(items.count) filtered=\(filtered.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return filtered
        } catch {
            VoiceTodoLog.store.error("query_actor.completed_unscheduled.fetch_failed range_start=\(startDate.ISO8601Format(), privacy: .public) range_end=\(endDate.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    /// 洞察引擎的原料查询(阶段 1 数据地基,见 docs/todo-review-flow-design.md §1.4)。
    ///
    /// 一次性取齐阶段 2 规则要的原料,组装成 `Sendable` 的 `InsightContext` 值类型
    /// 跨 actor 返回;UI 侧在 `.task` 里 await 一次存 `@State`,不放 body。
    /// 口径:
    /// - 完成事件 / 未完成 / 到期任务都**只取一次性任务**(`recurrenceRule == nil`,
    ///   拍板 4:规律父任务永远 isCompleted == false,且 occurrence 缺 per-occurrence
    ///   createdAt,洞察算不出来)。
    /// - 未完成任务排除已划掉(`abandonedAt == nil`);完成率分母(ReviewView @Query)
    /// 不排除——两处方向相反,别改串(拍板 1)。
    /// - 推迟计数排除 `origin == .review`:复盘里的主动排期不算推迟。
    /// - Parameters:
    ///   - startDate: 区间开始(闭)。
    ///   - endDate: 区间结束(开)。
    /// - Returns: 原料级 DTO(规则形状由阶段 2 定,此处不做形状设计)。
    /// - Throws: `VoiceTodoError.storageReadFailed` 数据库读取错误(显式传播,不静默回退)。
    func insightContext(from startDate: Date, to endDate: Date) throws -> InsightContext {
        let startedAt = Date()
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        // 谓词外提常量:#Predicate 闭包不能引用 enum case 成员,提到局部 let 防字符串漂移。
        let deferredRaw = TaskEventType.deferred.rawValue
        let reviewRaw = TaskEventOrigin.review.rawValue
        let completedDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                $0.isCompleted
                && ($0.completedAt ?? distantPast) >= startDate
                && ($0.completedAt ?? distantFuture) < endDate
            }
        )
        let dueDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                ($0.dueDate ?? distantPast) >= startDate
                && ($0.dueDate ?? distantFuture) < endDate
            }
        )
        let deferredDescriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate {
                $0.typeRaw == deferredRaw
                && $0.at >= startDate
                && $0.at < endDate
                && $0.originRaw != reviewRaw
            }
        )
        do {
            let completedItems = try modelContext.fetch(completedDescriptor)
                .filter { $0.recurrenceRule == nil }
                .map { item in
                    InsightCompletedEvent(
                        todoId: item.id,
                        createdAt: item.createdAt,
                        completedAt: item.completedAt ?? item.createdAt,
                        category: item.category,
                        priority: item.priority,
                        hasDueTime: item.hasDueTime,
                        dueDate: item.dueDate
                    )
                }
            let openItems = try modelContext.fetch(FetchDescriptor<TodoItem>(
                predicate: #Predicate { !$0.isCompleted && $0.abandonedAt == nil }
            ))
            let openTasks = openItems
                .filter { $0.recurrenceRule == nil }
                .map { item in
                    InsightOpenTask(todoId: item.id, createdAt: item.createdAt, dueDate: item.dueDate)
                }
            let dueTasks = try modelContext.fetch(dueDescriptor)
                .filter { $0.recurrenceRule == nil }
                .map { item in
                    // dueDescriptor 谓词已保证 dueDate != nil,这里的兜底仅安抚类型系统。
                    InsightDueTask(
                        todoId: item.id,
                        dueDate: item.dueDate ?? distantPast,
                        hasDueTime: item.hasDueTime,
                        isCompleted: item.isCompleted,
                        abandonedAt: item.abandonedAt
                    )
                }
            let deferredEvents = try modelContext.fetch(deferredDescriptor)
            var deferCounts: [UUID: Int] = [:]
            for event in deferredEvents {
                deferCounts[event.todoId, default: 0] += 1
            }
            let context = InsightContext(
                from: startDate,
                to: endDate,
                completedEvents: completedItems,
                openTasks: openTasks,
                dueTasks: dueTasks,
                deferCounts: deferCounts
            )
            VoiceTodoLog.store.debug("query_actor.insight_context.fetch_success range_start=\(startDate.ISO8601Format(), privacy: .public) range_end=\(endDate.ISO8601Format(), privacy: .public) completed=\(context.completedEvents.count) open=\(context.openTasks.count) due=\(context.dueTasks.count) deferredTodos=\(deferCounts.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return context
        } catch {
            VoiceTodoLog.store.error("query_actor.insight_context.fetch_failed range_start=\(startDate.ISO8601Format(), privacy: .public) range_end=\(endDate.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
