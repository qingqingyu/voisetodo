import Foundation
import Combine
import SwiftData

/// 待办存储服务
@MainActor
final class TodoStore: TodoStoreProtocol {
    // MARK: - Properties

    /// SwiftData 模型上下文
    private let modelContext: ModelContext

    /// 所有待办（按 sortOrder 升序排列）
    @Published var todos: [TodoItemData] = []

    // MARK: - Initialization

    /// 初始化 TodoStore
    /// - Parameter modelContext: SwiftData 模型上下文
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        migrateOldSortOrder()
        refreshTodos()
    }

    // MARK: - TodoStoreProtocol Implementation

    /// 添加单条待办
    /// - Parameter item: AI 提取的待办
    func add(_ item: ExtractedTodo) throws {
        let todoItem = TodoItem.from(item)
        todoItem.sortOrder = nextSortOrderForNewItem()
        modelContext.insert(todoItem)

        do {
            try modelContext.save()
            todos.insert(todoItem.toData(), at: 0)
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 批量添加（确认界面用）
    /// - Parameter items: AI 提取的待办数组
    func addBatch(_ items: [ExtractedTodo]) throws {
        var baseSortOrder = nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            let todoItem = TodoItem.from(item)
            todoItem.sortOrder = baseSortOrder
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        do {
            try modelContext.save()
            todos.insert(contentsOf: newTodos.reversed(), at: 0)
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 添加原始转写文本（离线降级用）[v2]
    /// - Parameter transcript: 原始语音转写文本
    func addRawTranscript(_ transcript: String) throws {
        let todoItem = TodoItem.rawTranscript(transcript)
        todoItem.sortOrder = nextSortOrderForNewItem()
        modelContext.insert(todoItem)

        do {
            try modelContext.save()
            todos.insert(todoItem.toData(), at: 0)
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 切换完成状态
    /// - Parameter id: 待办 ID
    func toggleComplete(_ id: UUID) throws {
        let todoItem = try findTodoItem(by: id)

        todoItem.isCompleted.toggle()

        do {
            try modelContext.save()
            // 增量更新：修改对应条目
            if let index = todos.firstIndex(where: { $0.id == id }) {
                todos[index] = todoItem.toData()
            }
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 删除待办
    /// - Parameter id: 待办 ID
    func delete(_ id: UUID) throws {
        let todoItem = try findTodoItem(by: id)

        modelContext.delete(todoItem)

        do {
            try modelContext.save()
            // 增量更新：移除对应条目
            todos.removeAll { $0.id == id }
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 更新待办
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - title: 新标题
    ///   - category: 新分类（nil 表示不修改）
    ///   - priority: 新优先级（nil 表示不修改）
    ///   - dueHint: 新时间提示（nil 表示不修改，空字符串清除）
    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil) throws {
        let todoItem = try findTodoItem(by: id)

        todoItem.title = title
        if let category = category {
            todoItem.category = category
        }
        if let priority = priority {
            todoItem.priority = priority
        }
        if let dueHint = dueHint {
            let normalizedDueHint = dueHint.trimmingCharacters(in: .whitespacesAndNewlines)
            todoItem.dueHint = normalizedDueHint.isEmpty ? nil : normalizedDueHint
            todoItem.dueDate = TodoDueDateResolver.resolve(
                dueHint: todoItem.dueHint,
                title: todoItem.title,
                detail: todoItem.detail ?? ""
            )
        }

        do {
            try modelContext.save()
            // 增量更新：修改对应条目
            if let index = todos.firstIndex(where: { $0.id == id }) {
                todos[index] = todoItem.toData()
            }
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）
    /// - Returns: 待处理条目数组
    func pendingItems() -> [TodoItemData] {
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.needsAIProcessing },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            return items.map { $0.toData() }
        } catch {
            #if DEBUG
            print("Failed to fetch pending items: \(error)")
            #endif
            return todos
                .filter { $0.needsAIProcessing }
                .sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    /// 获取最近 N 条未完成待办（Widget 用）
    /// - Parameter limit: 返回数量限制
    /// - Returns: 未完成待办数组
    func recentUncompleted(limit: Int) -> [TodoItemData] {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = limit

        do {
            let items = try modelContext.fetch(descriptor)
            return items.map { $0.toData() }
        } catch {
            #if DEBUG
            print("Failed to fetch recent uncompleted todos: \(error)")
            #endif
            return Array(todos.filter { !$0.isCompleted }.prefix(limit))
        }
    }

    /// 替换待处理条目为提取结果（网络恢复后用）[v2]
    /// SwiftData 在 save() 前只在内存中操作，crash 不会持久化部分数据
    /// - Parameters:
    ///   - pendingId: 待处理条目 ID
    ///   - items: AI 提取结果
    ///   - rawTranscript: 合并的原始转写文本（多个 pending 合并时覆盖 pending 自身的）
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String? = nil) throws {
        try replacePendingBatchWithExtracted([pendingId], items, rawTranscript: rawTranscript)
    }

    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String? = nil) throws {
        guard !pendingIds.isEmpty else {
            throw VoiceTodoError.storageReadFailed("未提供待处理 ID")
        }

        let pendingItems = try pendingIds.map { try findTodoItem(by: $0) }
        let effectiveTranscript = rawTranscript ?? pendingItems.compactMap(\.rawTranscript).joined(separator: "\n---\n")

        var baseSortOrder = nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            let todoItem = TodoItem.from(item, rawTranscript: effectiveTranscript)
            todoItem.sortOrder = baseSortOrder
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        for pendingItem in pendingItems {
            modelContext.delete(pendingItem)
        }

        do {
            try modelContext.save()
            let pendingSet = Set(pendingIds)
            todos.removeAll { pendingSet.contains($0.id) }
            todos.insert(contentsOf: newTodos.reversed(), at: 0)
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    func resetForUITests() throws {
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            for item in items {
                modelContext.delete(item)
            }
            try modelContext.save()
            todos = []
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    func seedForUITests(_ items: [TodoItemData]) throws {
        for item in items {
            let todoItem = TodoItem(
                id: item.id,
                title: item.title,
                detail: item.detail,
                dueHint: item.dueHint,
                dueDate: item.dueDate,
                priority: item.priority,
                category: item.category,
                isCompleted: item.isCompleted,
                createdAt: item.createdAt,
                rawTranscript: item.rawTranscript,
                needsAIProcessing: item.needsAIProcessing,
                sortOrder: item.sortOrder
            )
            modelContext.insert(todoItem)
        }

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    /// 重新排序未完成待办（拖拽排序后调用）
    /// - Parameter ids: 按新顺序排列的待办 ID 数组
    func reorder(ids: [UUID]) throws {
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted }
        )
        let allUncompleted = try modelContext.fetch(descriptor)
        let itemMap = Dictionary(uniqueKeysWithValues: allUncompleted.map { ($0.id, $0) })

        var itemsToUpdate = [(TodoItem, Int)]()
        for (index, id) in ids.enumerated() {
            guard let item = itemMap[id] else {
                throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
            }
            itemsToUpdate.append((item, index))
        }

        for (item, order) in itemsToUpdate {
            item.sortOrder = order
        }

        do {
            try modelContext.save()
            refreshTodos()
        } catch {
            throw VoiceTodoError.storageWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Internal Methods

    /// 全量刷新 todos 属性（从数据库重新加载）
    /// 初始化时及 app 回前台时调用（同步 Widget 在 Extension 进程中的修改）
    func refreshTodos() {
        let descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            todos = items.map { $0.toData() }
        } catch {
            #if DEBUG
            print("Failed to refresh todos: \(error)")
            #endif
        }
    }

    // MARK: - Private Methods

    /// 计算新条目的 sortOrder（比当前最小值再小 1，确保排在最前面）
    private func nextSortOrderForNewItem() -> Int {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = 1

        do {
            let items = try modelContext.fetch(descriptor)
            let minOrder = items.first?.sortOrder ?? 0
            return minOrder - 1
        } catch {
            return -1
        }
    }

    /// 一次性迁移：为旧数据（sortOrder 全部为 0）按 createdAt 倒序分配 sortOrder
    private func migrateOldSortOrder() {
        let descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            guard items.count > 1 else { return }

            let allZero = items.allSatisfy { $0.sortOrder == 0 }
            guard allZero else { return }

            for (index, item) in items.enumerated() {
                item.sortOrder = index
            }
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Failed to migrate sortOrder: \(error)")
            #endif
        }
    }

    /// 根据 ID 查找 TodoItem
    /// - Parameter id: 待办 ID
    /// - Returns: TodoItem 实例（如果找到）
    private func findTodoItem(by id: UUID) throws -> TodoItem {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        do {
            let items = try modelContext.fetch(descriptor)
            guard let item = items.first else {
                throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
            }
            return item
        } catch {
            if let storageError = error as? VoiceTodoError {
                throw storageError
            }
            throw VoiceTodoError.storageReadFailed(error.localizedDescription)
        }
    }
}
