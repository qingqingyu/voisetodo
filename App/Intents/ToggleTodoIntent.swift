import AppIntents
import SwiftData
import WidgetKit

/// Widget 内打勾完成待办的 AppIntent
/// 运行在 Widget Extension 进程中，独立访问 App Group SwiftData
struct ToggleTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Todo"

    @Parameter(title: "Todo ID")
    var todoId: String

    init() {}

    init(todoId: String) {
        self.todoId = todoId
    }

    func perform() async throws -> some IntentResult {
        let intentID = VoiceTodoLog.makeID("toggle-intent")
        let startedAt = Date()
        VoiceTodoLog.intent.info("intent.toggle.start id=\(intentID, privacy: .public) todoId=\(todoId, privacy: .public)")
        guard let uuid = UUID(uuidString: todoId) else {
            VoiceTodoLog.intent.warning("intent.toggle.invalid_id id=\(intentID, privacy: .public) todoId=\(todoId, privacy: .public)")
            return .result()
        }

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.writable()
        } catch {
            VoiceTodoLog.intent.error("intent.toggle.container_failed id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "toggle", stage: "container"))
            recordInteractionFailure(todoID: uuid)
            return .result()
        }
        let context = ModelContext(container)

        do {
            let result = try ToggleTodoMutation.apply(todoID: uuid, context: context)
            switch result {
            case let .toggled(recurrence, isCompleted):
                AppGroupConfig.clearWidgetInteractionError()
                AppGroupConfig.markExternalDataChanged()
                WidgetCenter.shared.reloadAllTimelines()
                VoiceTodoLog.intent.info("intent.toggle.save_success id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public) recurrence=\(recurrence) isCompleted=\(isCompleted) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            case .notFound:
                VoiceTodoLog.intent.warning("intent.toggle.not_found id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public)")
            case .nonOccurringToday:
                VoiceTodoLog.intent.info("intent.toggle.ignored id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public) reason=non_occurring_today")
            }
        } catch let error as ToggleTodoMutationError {
            VoiceTodoLog.intent.error("intent.toggle.\(error.stage.rawValue, privacy: .public)_failed id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error.underlying), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "toggle", stage: error.stage.rawValue))
            recordInteractionFailure(todoID: uuid)
        } catch {
            VoiceTodoLog.intent.error("intent.toggle.failed id=\(intentID, privacy: .public) todoID=\(uuid.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "toggle", stage: "unknown"))
            recordInteractionFailure(todoID: uuid)
        }

        return .result()
    }

    private func recordInteractionFailure(todoID: UUID) {
        AppGroupConfig.recordWidgetInteractionError(operation: .toggleTodo, todoID: todoID)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum ToggleTodoMutationResult: Equatable {
    case toggled(recurrence: Bool, isCompleted: Bool)
    case notFound
    case nonOccurringToday
}

struct ToggleTodoMutationError: Error {
    enum Stage: String {
        case fetchTodo = "fetch_todo"
        case fetchCompletion = "fetch_completion"
        case save
    }

    let stage: Stage
    let underlying: Error
}

enum ToggleTodoMutation {
    static func apply(
        todoID: UUID,
        context: ModelContext,
        today: Date = Date(),
        calendar: Calendar = .current,
        completedAt: Date = Date()
    ) throws -> ToggleTodoMutationResult {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == todoID }
        )
        descriptor.fetchLimit = 1

        let item: TodoItem?
        do {
            item = try context.fetch(descriptor).first
        } catch {
            throw ToggleTodoMutationError(stage: .fetchTodo, underlying: error)
        }

        guard let item else {
            return .notFound
        }

        if let recurrenceRule = item.recurrenceRule {
            let day = calendar.startOfDay(for: today)
            guard recurrenceRule.occurs(on: day, startDate: item.dueDate ?? item.createdAt, calendar: calendar) else {
                return .nonOccurringToday
            }

            let key = TodoOccurrenceCompletion.key(todoId: item.id, occurrenceDate: day, calendar: calendar)
            var completionDescriptor = FetchDescriptor<TodoOccurrenceCompletion>(
                predicate: #Predicate { $0.occurrenceKey == key }
            )
            completionDescriptor.fetchLimit = 1

            let isCompleted: Bool
            let completion: TodoOccurrenceCompletion?
            do {
                completion = try context.fetch(completionDescriptor).first
            } catch {
                throw ToggleTodoMutationError(stage: .fetchCompletion, underlying: error)
            }

            if let completion {
                context.delete(completion)
                isCompleted = false
            } else {
                context.insert(TodoOccurrenceCompletion(
                    todoId: item.id,
                    occurrenceDate: day,
                    completedAt: completedAt,
                    calendar: calendar
                ))
                isCompleted = true
            }
            do {
                try context.save()
            } catch {
                throw ToggleTodoMutationError(stage: .save, underlying: error)
            }
            return .toggled(recurrence: true, isCompleted: isCompleted)
        } else {
            item.isCompleted.toggle()
            item.completedAt = item.isCompleted ? completedAt : nil
            do {
                try context.save()
            } catch {
                throw ToggleTodoMutationError(stage: .save, underlying: error)
            }
            return .toggled(recurrence: false, isCompleted: item.isCompleted)
        }
    }
}
