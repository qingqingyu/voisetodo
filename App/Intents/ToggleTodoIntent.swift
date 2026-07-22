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
    /// 操作意图。Widget 复用此 mutation 时传 `.toggle`;Siri 的 CompleteTodoIntent 传 `.complete`。
    /// - `.toggle`: 幂等翻转(原 Widget 行为,保持兼容)
    /// - `.complete`: 幂等置完成(已完成的重复任务 occurrence 不重复写、不覆盖 `completedAt`)
    /// - `.uncomplete`: 幂等置未完成(保留扩展能力,当前未在 Siri 暴露)
    enum Direction {
        case toggle
        case complete
        case uncomplete
    }

    static func apply(
        todoID: UUID,
        context: ModelContext,
        today: Date = Date(),
        calendar: Calendar = .current,
        completedAt: Date = Date(),
        direction: Direction = .toggle
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

            let completion: TodoOccurrenceCompletion?
            do {
                completion = try context.fetch(completionDescriptor).first
            } catch {
                throw ToggleTodoMutationError(stage: .fetchCompletion, underlying: error)
            }

            // 根据方向算出目标状态。`.toggle` 沿用原逻辑(无记录→完成 / 有记录→未完成)。
            // `.complete` / `.uncomplete` 为幂等置位:目标状态固定,不依赖 completion 是否存在。
            let wantComplete: Bool
            switch direction {
            case .toggle: wantComplete = completion == nil
            case .complete: wantComplete = true
            case .uncomplete: wantComplete = false
            }

            // 只在状态真正需要变化时写库,避免无谓 save 覆盖 completion 原本的 completedAt。
            if wantComplete && completion == nil {
                context.insert(TodoOccurrenceCompletion(
                    todoId: item.id,
                    occurrenceDate: day,
                    completedAt: completedAt,
                    calendar: calendar
                ))
            } else if !wantComplete && completion != nil {
                context.delete(completion!)
            }

            do {
                try context.save()
            } catch {
                throw ToggleTodoMutationError(stage: .save, underlying: error)
            }
            return .toggled(recurrence: true, isCompleted: wantComplete)
        } else {
            // 非重复任务:同上,根据方向算出目标状态。
            // `.toggle` 走原翻转语义;`.complete`/`.uncomplete` 走幂等置位。
            // 与重复分支保持一致的"目标状态已等于当前状态则不写"策略,
            // 避免已完成的 todo 被覆盖一个新的 completedAt。
            let wantComplete: Bool
            switch direction {
            case .toggle: wantComplete = !item.isCompleted
            case .complete: wantComplete = true
            case .uncomplete: wantComplete = false
            }

            guard item.isCompleted != wantComplete else {
                return .toggled(recurrence: false, isCompleted: item.isCompleted)
            }

            item.isCompleted = wantComplete
            item.completedAt = wantComplete ? completedAt : nil
            do {
                try context.save()
            } catch {
                throw ToggleTodoMutationError(stage: .save, underlying: error)
            }
            return .toggled(recurrence: false, isCompleted: wantComplete)
        }
    }
}
