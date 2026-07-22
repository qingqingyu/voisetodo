import AppIntents
import Foundation
import SwiftData

/// Siri 查询过滤维度。
///
/// 用 AppEnum 而非 Boolean,是为了让 Siri 能用自然语言区分:
/// - "我的待办" → `.incomplete`
/// - "我完成了哪些" → `.completed`
/// - "我所有的待办" → `.all`
enum TodoStatusFilter: String, AppEnum {
    case incomplete
    case completed
    case all

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "siri.query.status.title"
    static var caseDisplayRepresentations: [TodoStatusFilter: DisplayRepresentation] = [
        .incomplete: DisplayRepresentation("siri.query.status.incomplete"),
        .completed: DisplayRepresentation("siri.query.status.completed"),
        .all: DisplayRepresentation("siri.query.status.all")
    ]
}

/// Siri App Intent:查询待办列表并显示 snippet。
///
/// 设计取舍:不直接复用 `WidgetTodoFilter.visibleTodos` —— 那个是"今天 Widget 显示哪些"
/// 的专用过滤(按 occurrence 日历日 / completion cut-off 等),语义偏窄。
/// Siri 查询的语义是"我的列表里有什么",所以这里走更直接的 fetch + isCompleted 过滤。
/// 未来若 Siri 要做"今天我有什么"这类带时间的查询,再考虑复用 Widget 过滤。
struct QueryTodosIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.query.title"
    static var description = IntentDescription("siri.query.description")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "siri.query.param.status", default: TodoStatusFilter.incomplete)
    var status: TodoStatusFilter

    static var parameterSummary: some ParameterSummary {
        Summary("siri.query.summary \(\.$status)")
    }

    /// snippet 中最多展示多少条。fetch 拉这个数量的 2x,前 5 条渲染,其余用"还有 N 条..."兜底。
    private static let fetchLimit = 10
    private static let displayLimit = 5

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let intentID = VoiceTodoLog.makeID("query-intent")
        let startedAt = Date()
        VoiceTodoLog.intent.info("intent.query.start id=\(intentID, privacy: .public) status=\(status.rawValue, privacy: .public)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.readOnly()
        } catch {
            VoiceTodoLog.intent.error("intent.query.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "query", stage: "container"))
            return .result(
                dialog: "siri.query.failed",
                view: QueryTodosIntentView(todos: [], status: status)
            )
        }
        let context = ModelContext(container)

        let todos = fetchTodos(context: context, status: status)
        VoiceTodoLog.intent.info("intent.query.success id=\(intentID, privacy: .public) status=\(status.rawValue, privacy: .public) count=\(todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

        let dialog: IntentDialog
        if todos.isEmpty {
            dialog = "siri.query.empty"
        } else {
            dialog = "siri.query.result \(todos.count)"
        }
        return .result(
            dialog: dialog,
            view: QueryTodosIntentView(todos: todos.prefix(Self.displayLimit).map { $0 }, status: status)
        )
    }

    /// 按 status 拉取 + 过滤,返回前 `fetchLimit` 条。
    /// - `.incomplete` / `.all`:按 sortOrder 升序(与 Home 列表一致)
    /// - `.completed`:按 completedAt 降序(最近完成的在前)
    private func fetchTodos(context: ModelContext, status: TodoStatusFilter) -> [TodoEntity] {
        let descriptor: FetchDescriptor<TodoItem>
        switch status {
        case .incomplete:
            var d = FetchDescriptor<TodoItem>(
                predicate: #Predicate { !$0.isCompleted },
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            d.fetchLimit = Self.fetchLimit
            descriptor = d
        case .completed:
            var d = FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.isCompleted },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            )
            d.fetchLimit = Self.fetchLimit
            descriptor = d
        case .all:
            var d = FetchDescriptor<TodoItem>(
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            d.fetchLimit = Self.fetchLimit
            descriptor = d
        }

        do {
            let items = try context.fetch(descriptor)
            return items.map { TodoEntity(from: $0.toData()) }
        } catch {
            VoiceTodoLog.intent.error("intent.query.fetch_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "query", stage: "fetch"))
            return []
        }
    }
}
