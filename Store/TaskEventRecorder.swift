import Foundation
import SwiftData

/// 复盘埋点薄写入器(见 docs/todo-review-flow-design.md §1.3)。
///
/// 只负责把 `TaskEvent` insert 进调用方传入的 `ModelContext`;
/// **不负责 save**——事件必须与主操作同 context 同事务,insert 后随现有
/// `saveOrRollback()` 一起存,失败一起回滚、错误显式传播。
/// 推迟判定复用 `TaskEventRules.isDeferral`(纯函数,单测友好)。
@MainActor
struct TaskEventRecorder {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 记一条 deferred 事件(是否该记由调用方用 `TaskEventRules.isDeferral` 判定,
    /// 本方法不重复判定,避免两处规则漂移)。
    func recordDeferred(todoId: UUID, from: Date?, to: Date?, origin: TaskEventOrigin) {
        modelContext.insert(TaskEvent(
            todoId: todoId,
            type: .deferred,
            fromDate: from,
            toDate: to,
            origin: origin
        ))
        VoiceTodoLog.store.info("task_event.record.deferred todoID=\(todoId.uuidString, privacy: .public) origin=\(origin.rawValue, privacy: .public)")
    }

    /// 记一条 abandoned 事件(与 `TodoStore.abandon` 的 `abandonedAt = Date()` 同事务)。
    func recordAbandoned(todoId: UUID, at: Date = Date(), origin: TaskEventOrigin) {
        modelContext.insert(TaskEvent(
            todoId: todoId,
            type: .abandoned,
            fromDate: nil,
            toDate: nil,
            at: at,
            origin: origin
        ))
        VoiceTodoLog.store.info("task_event.record.abandoned todoID=\(todoId.uuidString, privacy: .public) origin=\(origin.rawValue, privacy: .public)")
    }

    /// 记一条 split 事件。阶段 3 的复盘拆小 UI 才会触发(拆小时同时写子任务的
    /// `parentTodoId`、原任务标 `abandonedAt`),本阶段无调用方,先提供写入能力。
    func recordSplit(todoId: UUID, at: Date = Date(), origin: TaskEventOrigin) {
        modelContext.insert(TaskEvent(
            todoId: todoId,
            type: .split,
            fromDate: nil,
            toDate: nil,
            at: at,
            origin: origin
        ))
        VoiceTodoLog.store.info("task_event.record.split todoID=\(todoId.uuidString, privacy: .public) origin=\(origin.rawValue, privacy: .public)")
    }

    // 注:不提供 un-abandoned 事件——拍板 3 的事件集里没有该类型,
    // 「撤销划掉」从 abandonedAt == nil 即可推导,不需要事件行。
}
