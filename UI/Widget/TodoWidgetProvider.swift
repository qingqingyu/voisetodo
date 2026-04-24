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

    // MARK: - App Group Configuration

    /// App Group 标识符（与主 App 保持一致）
    private let appGroupIdentifier = WidgetConfig.appGroupIdentifier

    /// 缓存的 ModelContainer，避免每次 getTimeline 都重新创建
    /// Widget Extension 的 TimelineProvider 方法由系统单线程调度，无需额外同步
    nonisolated(unsafe) private static var cachedContainer: ModelContainer?

    private func getModelContainer() throws -> ModelContainer {
        if let cached = Self.cachedContainer {
            return cached
        }

        let schema = Schema([TodoItem.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: false,
            groupContainer: .identifier(appGroupIdentifier)
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        Self.cachedContainer = container
        return container
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

            var descriptor = FetchDescriptor<TodoItem>(
                predicate: #Predicate { !$0.isCompleted },
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            descriptor.fetchLimit = limit

            let items = try context.fetch(descriptor)
            let todos = items.map { $0.toData() }

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
