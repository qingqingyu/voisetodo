import AppIntents
import SwiftData
import WidgetKit

/// Siri App Intent:删除指定待办。
///
/// 删除时同步清理所有 `TodoOccurrenceCompletion` 记录(重复任务的历史完成记录),
/// 保持与 `TodoStore.delete` 的数据完整性约定一致(`delete` 内 `deleteCompletions(for:)`)。
/// 不处理系统日历事件清理:store 层的 `TodoStore.delete` 不碰 EventKit,但主 App 的
/// 完整删除路径 `AppCoordinator.deleteTodo` **会**经 CalendarSyncService 清理镜像事件;
/// intent 不复刻它,是补审拍板(复刻需把 EventKit 权限请求引入 Siri 上下文,
/// 见 docs/review-findings-unreviewed-modules.md #8)——代价是 Siri 删除留孤儿事件,
/// 待后续前台孤儿对账收口,不在 Siri intent 里独立实现。
struct DeleteTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.delete.title"
    static var description = IntentDescription("siri.delete.description")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "siri.delete.param.todo")
    var todo: TodoEntity

    static var parameterSummary: some ParameterSummary {
        Summary("siri.delete.summary \(\.$todo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentID = VoiceTodoLog.makeID("delete-intent")
        let startedAt = Date()
        VoiceTodoLog.intent.info("intent.delete.start id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.writable()
        } catch {
            VoiceTodoLog.intent.error("intent.delete.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "delete", stage: "container"))
            return .result(dialog: "siri.delete.failed")
        }
        let context = ModelContext(container)

        // 把 entity 的 ID 提取到局部常量,#Predicate 闭包里直接捕获 entity 实例
        // 会触发"cannot convert to StandardPredicateExpression<Bool>"——SwiftData Predicate
        // 只支持简单值类型的捕获。同坑在 AddTodoIntent 用 `targetIDs.contains(...)` 绕开。
        let todoID = todo.id

        // 先 fetch 待办本体。未找到时按"已删除"语义返回成功对话,避免 Siri 二次追问
        // (用户可能刚在另一台设备上删过,Siri 缓存的 entity 引用过期)。
        var itemDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == todoID }
        )
        itemDescriptor.fetchLimit = 1
        let item: TodoItem?
        do {
            item = try context.fetch(itemDescriptor).first
        } catch {
            VoiceTodoLog.intent.error("intent.delete.fetch_failed id=\(intentID, privacy: .public) todoID=\(todoID.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "delete", stage: "fetch_todo"))
            return .result(dialog: "siri.delete.failed")
        }

        guard let item else {
            VoiceTodoLog.intent.info("intent.delete.already_gone id=\(intentID, privacy: .public) todoID=\(todoID.uuidString, privacy: .public)")
            return .result(dialog: "siri.delete.not_found")
        }

        // 清理重复任务的历史完成记录 —— 与 TodoStore.deleteCompletions(for:) 同策略。
        let completionDescriptor = FetchDescriptor<TodoOccurrenceCompletion>(
            predicate: #Predicate { $0.todoId == todoID }
        )
        do {
            let completions = try context.fetch(completionDescriptor)
            for completion in completions {
                context.delete(completion)
            }
            VoiceTodoLog.intent.debug("intent.delete.completions_cleaned id=\(intentID, privacy: .public) count=\(completions.count)")
        } catch {
            VoiceTodoLog.intent.error("intent.delete.fetch_completions_failed id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "delete", stage: "fetch_completion"))
            return .result(dialog: "siri.delete.failed")
        }

        context.delete(item)

        do {
            try context.save()
        } catch {
            VoiceTodoLog.intent.error("intent.delete.save_failed id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "delete", stage: "save"))
            return .result(dialog: "siri.delete.failed")
        }

        AppGroupConfig.markExternalDataChanged()
        WidgetCenter.shared.reloadAllTimelines()
        // 撤销该待办已排提醒:同 Toggle/Complete 的洞——intent 写库不走活着的
        // TodoStore,$todos 不发布,主 App 不回前台就不会对账,已删待办的提醒
        // 会照响到原定时刻。这里在 intent 进程内就地撤销(只删不排)。
        await IntentNotificationReconciler.removeNotifications(todoID: todoID, port: UNNotificationPort())
        VoiceTodoLog.intent.info("intent.delete.success id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return .result(dialog: "siri.delete.success \(todo.title)")
    }
}
