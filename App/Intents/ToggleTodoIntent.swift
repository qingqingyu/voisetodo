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
        guard let uuid = UUID(uuidString: todoId) else {
            return .result()
        }

        let schema = Schema([TodoItem.self, TodoOccurrenceCompletion.self])
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(AppGroupConfig.identifier)
        )
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == uuid }
        )
        descriptor.fetchLimit = 1

        if let item = try context.fetch(descriptor).first {
            if let recurrenceRule = item.recurrenceRule {
                let today = Calendar.current.startOfDay(for: Date())
                guard recurrenceRule.occurs(on: today, startDate: item.dueDate ?? item.createdAt) else {
                    return .result()
                }

                let key = TodoOccurrenceCompletion.key(todoId: item.id, occurrenceDate: today)
                var completionDescriptor = FetchDescriptor<TodoOccurrenceCompletion>(
                    predicate: #Predicate { $0.occurrenceKey == key }
                )
                completionDescriptor.fetchLimit = 1

                if let completion = try context.fetch(completionDescriptor).first {
                    context.delete(completion)
                } else {
                    context.insert(TodoOccurrenceCompletion(todoId: item.id, occurrenceDate: today))
                }
            } else {
                item.isCompleted.toggle()
            }
            try context.save()
            AppGroupConfig.markExternalDataChanged()
            WidgetCenter.shared.reloadAllTimelines()
        }

        return .result()
    }
}
