import Foundation

/// 洞察原料:区间内完成的一次性任务事件。
/// 「一次性」= recurrenceRule == nil(拍板 4:规律任务排除在洞察之外)。
struct InsightCompletedEvent: Sendable {
    let todoId: UUID
    let createdAt: Date
    let completedAt: Date
    let category: TodoCategory
    let priority: Priority
    let hasDueTime: Bool
    let dueDate: Date?
}

/// 洞察原料:当前未完成的一次性任务(recurrenceRule == nil && abandonedAt == nil)。
struct InsightOpenTask: Sendable {
    let todoId: UUID
    let createdAt: Date
    let dueDate: Date?
}

/// 洞察原料:区间内到期的一次性任务。
struct InsightDueTask: Sendable {
    let todoId: UUID
    let dueDate: Date
    let hasDueTime: Bool
    let isCompleted: Bool
    let abandonedAt: Date?
}

/// 洞察引擎的共享输入 DTO(原料级,非规则级)。
///
/// 由 `TodoQueryActor.insightContext(from:to:)` 一次性取齐,`Sendable` 值类型,
/// 跨 actor 传递;UI 侧在 `.task` 里 await 一次存 `@State`,不放 body。
/// 阶段 2 的规则在这个原料上算,本类型**不**替规则做形状设计
/// (见 docs/todo-review-flow-design.md §1.4)。
struct InsightContext: Sendable {
    /// 查询区间(闭开:[from, to))。
    let from: Date
    let to: Date
    /// 区间内完成的一次性任务事件。
    let completedEvents: [InsightCompletedEvent]
    /// 当前未完成的一次性任务(不含已划掉)。
    let openTasks: [InsightOpenTask]
    /// 区间内到期的一次性任务。
    let dueTasks: [InsightDueTask]
    /// 每 todoId 的有效推迟计数(deferred 事件,**排除 origin == .review**——
    /// 复盘里的主动排期不算推迟)。键为出现推迟事件的 todoId。
    let deferCounts: [UUID: Int]
}
