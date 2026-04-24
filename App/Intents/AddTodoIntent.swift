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
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], isOffline: false)
            )
        }

        let extractor = TodoExtractorService()
        var extractedTodos: [ExtractedTodo]
        var isOffline = false

        do {
            let result = try await extractor.extract(from: trimmed, locale: .current)
            extractedTodos = result.todos
        } catch {
            let fallback = extractor.fallbackExtract(from: trimmed)
            extractedTodos = fallback.todos
            isOffline = true
        }

        guard !extractedTodos.isEmpty else {
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], isOffline: false)
            )
        }

        let context: ModelContext
        do {
            let schema = Schema([TodoItem.self])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                groupContainer: .identifier(AppGroupConfig.identifier)
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            context = ModelContext(container)
        } catch {
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, isOffline: true)
            )
        }

        let minSortOrder = fetchMinSortOrder(context: context)
        var baseSortOrder = minSortOrder - 1

        for extracted in extractedTodos {
            let item = TodoItem.from(extracted, rawTranscript: trimmed)
            item.needsAIProcessing = isOffline
            item.sortOrder = baseSortOrder
            baseSortOrder -= 1
            context.insert(item)
        }

        do {
            try context.save()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, isOffline: true)
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

    private func fetchMinSortOrder(context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = 1
        do {
            let items = try context.fetch(descriptor)
            return items.first?.sortOrder ?? 0
        } catch {
            return 0
        }
    }
}
