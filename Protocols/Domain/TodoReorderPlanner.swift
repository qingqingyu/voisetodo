import Foundation

/// 无日期任务拖拽排序的纯计算：把「无日期任务的新相对顺序」填回全局未完成序列，
/// 已排期 / 已完成任务的位置（槽位）保持不动 —— 只在无日期任务之间互换全局位置，
/// 从而不打乱 Widget 依赖的全局 sortOrder。
enum TodoReorderPlanner {
    /// - Parameters:
    ///   - uncompleted: 当前全部**未完成**待办，按全局 sortOrder 升序。
    ///   - newUnscheduledOrder: 无日期未完成任务按拖拽后的新相对顺序排列的 id。
    /// - Returns: 重排后的全部未完成待办 id（交给 `reorder(ids:)` 重写 sortOrder）。
    static func reorderedUncompletedIDs(
        uncompleted: [TodoItemData],
        newUnscheduledOrder: [UUID]
    ) -> [UUID] {
        var queue = newUnscheduledOrder
        return uncompleted.map { todo in
            if isUnscheduled(todo), !queue.isEmpty {
                return queue.removeFirst()
            }
            return todo.id
        }
    }

    /// 无日期判定：既无截止日、也非规律任务。与 `HomeCalendarState.unscheduledTodos` 一致。
    static func isUnscheduled(_ todo: TodoItemData) -> Bool {
        todo.dueDate == nil && todo.recurrenceRule == nil
    }
}
