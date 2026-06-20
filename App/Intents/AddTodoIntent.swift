import AppIntents
import SwiftData
import WidgetKit

/// Siri App Intent：通过语音快速记录待办
/// 用户对 Siri 说"用 VoiceTodo 记录..."时触发
struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.intent.title"
    static var description: IntentDescription = IntentDescription("siri.intent.description")

    @Parameter(title: "siri.param.transcript")
    var transcript: String

    static var parameterSummary: some ParameterSummary {
        Summary("siri.summary \(\.$transcript)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let intentID = VoiceTodoLog.makeID("add-intent")
        let startedAt = Date()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceTodoLog.intent.info("intent.add.start id=\(intentID, privacy: .public) \(VoiceTodoLog.textSummary(trimmed), privacy: .public)")
        guard !trimmed.isEmpty else {
            VoiceTodoLog.intent.info("intent.add.empty id=\(intentID, privacy: .public)")
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], isOffline: false)
            )
        }

        let extractor = TodoExtractorService()
        var extractedTodos: [ExtractedTodo]
        var isOffline = false
        let inputLocale = Locale.current

        do {
            let result = try await extractor.extract(from: trimmed, locale: inputLocale)
            extractedTodos = Self.todosWithInputLocale(result.todos, localeIdentifier: inputLocale.identifier)
            VoiceTodoLog.intent.info("intent.add.extract_success id=\(intentID, privacy: .public) locale=\(inputLocale.identifier, privacy: .public) todoCount=\(extractedTodos.count)")
        } catch let error as VoiceTodoError {
            VoiceTodoLog.intent.error("intent.add.extract_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            switch error {
            case .networkUnavailable, .apiTimeout:
                let fallback = extractor.fallbackExtract(from: trimmed)
                extractedTodos = Self.todosWithInputLocale(fallback.todos, localeIdentifier: inputLocale.identifier)
                isOffline = true
                VoiceTodoLog.intent.warning("intent.add.fallback id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count)")
            default:
                return .result(
                    dialog: "siri.result.extract_failed",
                    view: AddTodoIntentView(todos: [], isOffline: false)
                )
            }
        } catch {
            VoiceTodoLog.intent.error("intent.add.extract_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .result(
                dialog: "siri.result.extract_failed",
                view: AddTodoIntentView(todos: [], isOffline: false)
            )
        }

        guard !extractedTodos.isEmpty else {
            VoiceTodoLog.intent.info("intent.add.no_todos id=\(intentID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], isOffline: false)
            )
        }

        let context: ModelContext
        do {
            let container = try AppGroupModelContainerProvider.writable()
            context = ModelContext(container)
        } catch {
            VoiceTodoLog.intent.error("intent.add.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "add", stage: "container"))
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, isOffline: isOffline)
            )
        }

        let minSortOrder: Int
        do {
            minSortOrder = try fetchMinSortOrder(context: context)
        } catch {
            VoiceTodoLog.intent.error("intent.add.fetch_min_sort_order.blocked_save id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, isOffline: isOffline)
            )
        }
        var baseSortOrder = minSortOrder - 1

        for extracted in extractedTodos {
            let item = TodoItem.from(extracted, rawTranscript: trimmed)
            item.sortOrder = baseSortOrder
            baseSortOrder -= 1
            context.insert(item)
        }

        do {
            try context.save()
            AppGroupConfig.markExternalDataChanged()
            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.intent.info("intent.add.save_success id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            Telemetry.record(.todoSaved(source: .siriAdd, count: extractedTodos.count))
        } catch {
            VoiceTodoLog.intent.error("intent.add.save_failed id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "add", stage: "save"))
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, isOffline: isOffline)
            )
        }

        let count = extractedTodos.count
        let dialog: IntentDialog = isOffline
            ? "siri.result.offline"
            : "siri.result.added \(count)"

        return .result(
            dialog: dialog,
            view: AddTodoIntentView(todos: extractedTodos, isOffline: isOffline)
        )
    }

    private func fetchMinSortOrder(context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = 1
        do {
            let items = try context.fetch(descriptor)
            VoiceTodoLog.intent.debug("intent.add.fetch_min_sort_order.success value=\(items.first?.sortOrder ?? 0)")
            return items.first?.sortOrder ?? 0
        } catch {
            VoiceTodoLog.intent.error("intent.add.fetch_min_sort_order.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            if let voiceError = error as? VoiceTodoError {
                throw voiceError
            }
            throw VoiceTodoError.storageReadFailed(error.localizedDescription)
        }
    }

    private static func todosWithInputLocale(_ todos: [ExtractedTodo], localeIdentifier: String) -> [ExtractedTodo] {
        todos.map { todo in
            var localized = todo
            localized.localeIdentifier = localeIdentifier
            return localized
        }
    }
}
