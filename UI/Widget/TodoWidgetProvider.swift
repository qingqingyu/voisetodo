import WidgetKit
import SwiftUI

/// Widget Timeline Entry
struct TodoEntry: TimelineEntry {
    let date: Date
    let todos: [TodoItemData]
}

/// Widget Timeline Provider
/// 从 App Group 读取数据，提供 Widget 显示内容
///
/// **V1 架构决策说明：**
/// - 使用 `TimelineProvider` 而非 `IntentTimelineProvider`，简化 V1 版本
/// - V2 可扩展为可配置 Widget（用户选择显示分类、排序方式等）
/// - 当前使用 Mock 数据，后续需要实现 App Group SwiftData 读取
///
/// **TODO (V1 后续)：**
/// - [ ] 实现 App Group SwiftData 共享容器
/// - [ ] 添加 IntentConfiguration 支持用户自定义
/// - [ ] 考虑 Deep Link 支持点击跳转
struct TodoTimelineProvider: TimelineProvider {
    typealias Entry = TodoEntry

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
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    // MARK: - Data Loading

    /// 从 App Group 读取最近的待办
    private func getRecentTodos(limit: Int) -> [TodoItemData] {
        // V1: 临时 Mock 数据
        // TODO: 从 App Group SwiftData 读取实际数据
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
