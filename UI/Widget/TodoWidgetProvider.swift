import WidgetKit
import SwiftUI
import SwiftData

/// Widget Timeline Entry
struct TodoEntry: TimelineEntry {
    let date: Date
    let todos: [TodoItemData]
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
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        let entry = TodoEntry(
            date: Date(),
            todos: getRecentTodos(limit: context.family.itemCount)
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let currentDate = Date()
        let entry = TodoEntry(
            date: currentDate,
            todos: getRecentTodos(limit: context.family.itemCount)
        )

        // 每 30 分钟刷新一次
        let nextUpdate = Calendar.current.date(byAdding: .second, value: Int(WidgetConfig.refreshInterval), to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    // MARK: - Data Loading

    /// 从 App Group SwiftData 读取最近的未完成待办
    /// - Parameter limit: 返回数量限制
    /// - Returns: 未完成待办数组
    private func getRecentTodos(limit: Int) -> [TodoItemData] {
        do {
            let container = try getModelContainer()
            let context = ModelContext(container)
            let todos = try WidgetTodoFetch.recentTodos(context: context, limit: limit)

            #if DEBUG
            print("Widget: 成功读取 \(todos.count) 条待办")
            #endif
            return todos

        } catch {
            #if DEBUG
            print("Widget: 读取数据失败 - \(error.localizedDescription)")
            #endif
            return []
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
