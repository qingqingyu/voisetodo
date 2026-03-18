import Foundation
import Combine
import SwiftData

/// 待办存储服务
final class TodoStore: TodoStoreProtocol {
    // MARK: - Properties

    /// SwiftData 模型上下文
    private let modelContext: ModelContext

    /// 所有待办（按创建时间倒序）
    @Published var todos: [TodoItemData] = []

    // MARK: - Initialization

    /// 初始化 TodoStore
    /// - Parameter modelContext: SwiftData 模型上下文
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshTodos()
    }

    // MARK: - TodoStoreProtocol Implementation

    /// 添加单条待办
    /// - Parameter item: AI 提取的待办
    func add(_ item: ExtractedTodo) throws {
        let todoItem = TodoItem.from(item)
        modelContext.insert(todoItem)

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 批量添加（确认界面用）
    /// - Parameter items: AI 提取的待办数组
    func addBatch(_ items: [ExtractedTodo]) throws {
        for item in items {
            let todoItem = TodoItem.from(item)
            modelContext.insert(todoItem)
        }

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 添加原始转写文本（离线降级用）[v2]
    /// - Parameter transcript: 原始语音转写文本
    func addRawTranscript(_ transcript: String) throws {
        let todoItem = TodoItem.rawTranscript(transcript)
        modelContext.insert(todoItem)

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 切换完成状态
    /// - Parameter id: 待办 ID
    func toggleComplete(_ id: UUID) throws {
        guard let todoItem = findTodoItem(by: id) else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }

        todoItem.isCompleted.toggle()

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 删除待办
    /// - Parameter id: 待办 ID
    func delete(_ id: UUID) throws {
        guard let todoItem = findTodoItem(by: id) else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }

        modelContext.delete(todoItem)

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 更新标题
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - title: 新标题
    func update(_ id: UUID, title: String) throws {
        guard let todoItem = findTodoItem(by: id) else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }

        todoItem.title = title

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）
    /// - Returns: 待处理条目数组
    func pendingItems() -> [TodoItemData] {
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.needsAIProcessing }
        )

        do {
            let items = try modelContext.fetch(descriptor)
            return items.map { $0.toData() }
        } catch {
            // 查询失败返回空数组
            return []
        }
    }

    /// 获取最近 N 条未完成待办（Widget 用）
    /// - Parameter limit: 返回数量限制
    /// - Returns: 未完成待办数组
    func recentUncompleted(limit: Int) -> [TodoItemData] {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            let items = try modelContext.fetch(descriptor)
            return items.map { $0.toData() }
        } catch {
            // 查询失败返回空数组
            return []
        }
    }

    /// 替换待处理条目为提取结果（网络恢复后用）[v2]
    /// - Parameters:
    ///   - pendingId: 待处理条目 ID
    ///   - items: AI 提取结果
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo]) throws {
        // 删除待处理条目
        guard let pendingItem = findTodoItem(by: pendingId) else {
            throw VoiceTodoError.storageReadFailed("未找到待处理 ID: \(pendingId)")
        }

        let rawTranscript = pendingItem.rawTranscript
        modelContext.delete(pendingItem)

        // 插入提取结果
        for item in items {
            let todoItem = TodoItem.from(item, rawTranscript: rawTranscript)
            modelContext.insert(todoItem)
        }

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    /// 刷新 todos 属性（从数据库重新加载）
    private func refreshTodos() {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            todos = items.map { $0.toData() }
        } catch {
            // 查询失败保持原数据
            print("Failed to refresh todos: \(error)")
        }
    }

    /// 根据 ID 查找 TodoItem
    /// - Parameter id: 待办 ID
    /// - Returns: TodoItem 实例（如果找到）
    private func findTodoItem(by id: UUID) -> TodoItem? {
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == id }
        )

        do {
            let items = try modelContext.fetch(descriptor)
            return items.first
        } catch {
            return nil
        }
    }
}
