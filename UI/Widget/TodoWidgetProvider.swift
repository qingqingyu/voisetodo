import WidgetKit
import SwiftUI
import SwiftData

/// Widget Timeline Entry
enum TodoWidgetLoadState: Equatable {
    case loading
    case empty
    case error
    case success
}

struct TodoEntry: TimelineEntry {
    let date: Date
    let todos: [TodoItemData]
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?

    init(
        date: Date,
        todos: [TodoItemData],
        loadState: TodoWidgetLoadState,
        interactionError: WidgetInteractionError? = nil
    ) {
        self.date = date
        self.todos = todos
        self.loadState = loadState
        self.interactionError = interactionError
    }
}

/// Widget Timeline Provider
/// 从 App Group 读取数据，提供 Widget 显示内容
///
/// **实现说明：**
/// - 使用 SwiftData 从 App Group 共享容器读取待办数据
/// - 只读取未完成的待办，按 sortOrder 升序排列
/// - 每 30 分钟自动刷新
struct TodoTimelineProvider: TimelineProvider {
    typealias Entry = TodoEntry

    private func getModelContainer() throws -> ModelContainer {
        try AppGroupModelContainerProvider.readOnly()
    }

    // MARK: - TimelineProvider Methods

    func placeholder(in context: Context) -> TodoEntry {
        TodoEntry(
            date: Date(),
            todos: [
                TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
                TodoItemData(title: "准备面试", dueHint: "周三前", priority: .high, category: .work)
            ],
            loadState: .loading
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(loadRecentTodos(limit: context.family.itemCount, date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let currentDate = Date()
        let completionRetention = WidgetConfig.completionAnimationRetention
        let currentEntry = loadRecentTodos(
            limit: context.family.itemCount,
            date: currentDate,
            recentCompletionCutoff: currentDate.addingTimeInterval(-completionRetention)
        )

        // 每 30 分钟刷新一次
        let nextUpdate = Calendar.current.date(byAdding: .second, value: Int(WidgetConfig.refreshInterval), to: currentDate)!
        var entries = [currentEntry]
        if currentEntry.todos.contains(where: \.isCompleted),
           let filteredDate = Calendar.current.date(byAdding: .nanosecond, value: Int(completionRetention * 1_000_000_000), to: currentDate) {
            let filteredEntry = loadRecentTodos(limit: context.family.itemCount, date: filteredDate)
            entries.append(filteredEntry)
        }
        if let interactionError = currentEntry.interactionError {
            let clearDate = interactionError.expiresAt.addingTimeInterval(0.001)
            if !entries.contains(where: { abs($0.date.timeIntervalSince(clearDate)) < 0.001 }) {
                entries.append(loadRecentTodos(limit: context.family.itemCount, date: clearDate))
            }
        }

        let timeline = Timeline(entries: entries.sorted { $0.date < $1.date }, policy: .after(nextUpdate))
        completion(timeline)
    }

    // MARK: - Data Loading

    /// 从 App Group SwiftData 读取最近的未完成待办
    /// - Parameter limit: 返回数量限制
    /// - Returns: 未完成待办数组
    private func loadRecentTodos(limit: Int, date: Date, recentCompletionCutoff: Date? = nil) -> TodoEntry {
        let startedAt = Date()
        do {
            let container = try getModelContainer()
            let context = ModelContext(container)
            let todos = try WidgetTodoFetch.recentTodos(
                context: context,
                limit: limit,
                recentCompletionCutoff: recentCompletionCutoff
            )

            VoiceTodoLog.widget.info("widget.todos.fetch_success limit=\(limit) count=\(todos.count) recentCutoffSet=\(recentCompletionCutoff != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return TodoEntry(
                date: date,
                todos: todos,
                loadState: todos.isEmpty ? .empty : .success,
                interactionError: AppGroupConfig.currentWidgetInteractionError(now: date)
            )

        } catch {
            VoiceTodoLog.widget.error("widget.todos.fetch_failed limit=\(limit) recentCutoffSet=\(recentCompletionCutoff != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return TodoEntry(date: date, todos: [], loadState: .error)
        }
    }
}

// MARK: - Widget Family Extension

extension WidgetFamily {
    /// 根据 Widget 尺寸返回显示条数
    var itemCount: Int {
        switch self {
        case .systemSmall:
            return WidgetConfig.smallItemCount
        case .systemMedium:
            return WidgetConfig.mediumItemCount
        case .systemLarge, .systemExtraLarge:
            return WidgetConfig.largeItemCount
        case .accessoryRectangular, .accessoryCircular:
            return WidgetConfig.lockscreenItemCount
        case .accessoryInline:
            return 1
        @unknown default:
            return WidgetConfig.mediumItemCount
        }
    }
}
