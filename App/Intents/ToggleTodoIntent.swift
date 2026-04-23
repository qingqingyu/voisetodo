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

        let schema = Schema([TodoItem.self])
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier("group.com.voicetodo.shared")
        )
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == uuid }
        )
        descriptor.fetchLimit = 1

        if let item = try context.fetch(descriptor).first {
            item.isCompleted.toggle()
            try context.save()
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
