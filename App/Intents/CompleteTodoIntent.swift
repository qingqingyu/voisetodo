import AppIntents
import SwiftData
import WidgetKit

/// Siri App Intent:把指定待办标记为完成。
///
/// 与 Widget 用的 `ToggleTodoIntent` 区别:
/// - Widget 版本接收 `todoId: String`(Widget cell 直接构造),不返回对话,二态翻转。
/// - 此版本接收 `TodoEntity`(让 Siri 能用自然语言解析"完成 [买菜]"),
///   幂等置完成(已完成的任务不重复 save,不覆盖 `completedAt`),返回语音对话。
struct CompleteTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.complete.title"
    static var description = IntentDescription("siri.complete.description")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "siri.complete.param.todo")
    var todo: TodoEntity

    static var parameterSummary: some ParameterSummary {
        Summary("siri.complete.summary \(\.$todo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentID = VoiceTodoLog.makeID("complete-intent")
        let startedAt = Date()
        VoiceTodoLog.intent.info("intent.complete.start id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.writable()
        } catch {
            VoiceTodoLog.intent.error("intent.complete.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "complete", stage: "container"))
            return .result(dialog: "siri.complete.failed")
        }
        let context = ModelContext(container)

        let result: ToggleTodoMutationResult
        do {
            result = try ToggleTodoMutation.apply(
                todoID: todo.id,
                context: context,
                direction: .complete
            )
        } catch let error as ToggleTodoMutationError {
            VoiceTodoLog.intent.error("intent.complete.\(error.stage.rawValue, privacy: .public)_failed id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error.underlying), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "complete", stage: error.stage.rawValue))
            return .result(dialog: "siri.complete.failed")
        } catch {
            VoiceTodoLog.intent.error("intent.complete.unknown_failed id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "complete", stage: "unknown"))
            return .result(dialog: "siri.complete.failed")
        }

        switch result {
        case let .toggled(recurrence, isCompleted):
            AppGroupConfig.markExternalDataChanged()
            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.intent.info("intent.complete.success id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public) recurrence=\(recurrence) isCompleted=\(isCompleted) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return .result(dialog: "siri.complete.success \(todo.title)")
        case .notFound:
            VoiceTodoLog.intent.warning("intent.complete.not_found id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public)")
            return .result(dialog: "siri.complete.not_found")
        case .nonOccurringToday:
            VoiceTodoLog.intent.info("intent.complete.non_occurring id=\(intentID, privacy: .public) todoID=\(todo.id.uuidString, privacy: .public)")
            return .result(dialog: "siri.complete.non_occurring")
        }
    }
}
