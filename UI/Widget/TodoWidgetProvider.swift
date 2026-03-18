import WidgetKit
import SwiftUI

/// Widget Timeline Entry
struct TodoEntry: TimelineEntry {
    let date: Date
    let todos: [TodoItemData]
    let configuration: ConfigurationIntent
}

/// Widget Timeline Provider（Agent D 实现）
/// 从 App Group 读取数据，提供 Widget 显示内容
struct TodoTimelineProvider: IntentTimelineProvider {
    typealias Entry = TodoEntry
    typealias Intent = ConfigurationIntent

    func placeholder(in context: Context) -> TodoEntry {
        TodoEntry(
            date: Date(),
            todos: [
                TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
                TodoItemData(title: "准备面试", dueHint: "周三前", priority: .high, category: .work)
            ],
            configuration: ConfigurationIntent()
        )
    }

    func getSnapshot(for configuration: ConfigurationIntent, in context: Context, completion: @escaping (TodoEntry) -> Void) {
        let entry = TodoEntry(
            date: Date(),
            todos: getRecentTodos(limit: context.family.itemCount),
            configuration: configuration
        )
        completion(entry)
    }

    func getTimeline(for configuration: ConfigurationIntent, in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let currentDate = Date()
        let entry = TodoEntry(
            date: currentDate,
            todos: getRecentTodos(limit: context.family.itemCount),
            configuration: configuration
        )

        // 每 30 分钟刷新一次 [v2]
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    // MARK: - Data Loading

    /// 从 App Group 读取最近的待办
    private func getRecentTodos(limit: Int) -> [TodoItemData] {
        // 注意：这里使用 UserDefaults 作为临时方案
        // Agent C 会实现基于 SwiftData + App Group 的完整方案
        // 这里只是提供 Mock 数据，实际读取由 Agent C 实现

        // 临时 Mock 数据
        let mockTodos = [
            TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
            TodoItemData(title: "准备面试", dueHint: "周三前", priority: .high, category: .work),
            TodoItemData(title: "去健身房", dueHint: nil, priority: .normal, category: .health)
        ]

        return Array(mockTodos.prefix(limit))
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
