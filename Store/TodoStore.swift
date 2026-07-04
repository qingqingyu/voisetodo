import Foundation
import Combine
import SwiftData

/// 待办存储服务
@MainActor
final class TodoStore:
    @MainActor HomeTodoStore,
    @MainActor AppCoordinatorTodoStore,
    @MainActor PendingRecoveryTodoStore,
    @MainActor PendingTranscriptCreating,
    @MainActor CalendarSyncTodoStore,
    @MainActor TodoMutationWriting,
    @MainActor WidgetTodoReadable,
    @MainActor TodoRefreshing {
    // MARK: - Properties

    /// SwiftData 模型上下文
    private let modelContext: ModelContext
    private let saveAction: (ModelContext) throws -> Void

    /// 只读重查询的后台执行器（独立 ModelContext，跑在 actor executor 上）。
    /// 用主上下文的 container 构造，与主线程写操作共享同一持久化存储。
    private let queryActor: TodoQueryActor

    /// 所有待办（按 sortOrder 升序排列）
    @Published var todos: [TodoItemData] = []

    /// P6: 上次同步到的外部变更版本（Widget/AppIntent 跨进程写入标记），用于按需失效内存缓存。
    private var lastSyncedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()

    // MARK: - Initialization

    /// 初始化 TodoStore
    /// - Parameter modelContext: SwiftData 模型上下文
    init(
        modelContext: ModelContext,
        saveAction: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.saveAction = saveAction
        self.queryActor = TodoQueryActor(modelContainer: modelContext.container)
        VoiceTodoLog.store.info("store.init.start")
        migrateOldSortOrder()
        migrateDueDatesFromHints()
        refreshTodos()
        VoiceTodoLog.store.info("store.init.finished todoCount=\(self.todos.count)")
    }

    // MARK: - Store Facade Implementations

    /// 添加单条待办
    /// - Parameter item: AI 提取的待办
    func add(_ item: ExtractedTodo) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.add.start id=\(item.id.uuidString, privacy: .public) extractID=\(VoiceTodoLog.extractID ?? "none", privacy: .public) titleChars=\(item.title.count)")
        let todoItem = TodoItem.from(item)
        todoItem.sortOrder = try nextSortOrderForNewItem()
        todoItem.localeIdentifier = resolveLocaleIdentifier(item.localeIdentifier, fallback: Locale.current.identifier)
        modelContext.insert(todoItem)

        try saveOrRollback()
        todos.insert(todoItem.toData(), at: 0)
        VoiceTodoLog.store.info("store.add.success id=\(item.id.uuidString, privacy: .public) sortOrder=\(todoItem.sortOrder) locale=\(todoItem.localeIdentifier ?? "nil", privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 批量添加（确认界面用）
    /// - Parameter items: AI 提取的待办数组
    func addBatch(_ items: [ExtractedTodo]) throws {
        try addBatch(items, localeIdentifier: nil)
    }

    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws {
        let startedAt = Date()
        let fallbackLocaleIdentifier = resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        VoiceTodoLog.store.info("store.add_batch.start count=\(items.count) extractID=\(VoiceTodoLog.extractID ?? "none", privacy: .public) locale=\(fallbackLocaleIdentifier, privacy: .public) ids=\(VoiceTodoLog.idsSummary(items.map(\.id)), privacy: .public)")
        var baseSortOrder = try nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            let todoItem = TodoItem.from(item)
            todoItem.sortOrder = baseSortOrder
            todoItem.localeIdentifier = resolveLocaleIdentifier(localeIdentifier ?? item.localeIdentifier, fallback: fallbackLocaleIdentifier)
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        try saveOrRollback()
        todos.insert(contentsOf: newTodos.reversed(), at: 0)
        VoiceTodoLog.store.info("store.add_batch.success count=\(items.count) locale=\(fallbackLocaleIdentifier, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 添加原始转写文本（离线降级用）[v2]
    /// - Parameters:
    ///   - transcript: 原始语音转写文本
    ///   - localeIdentifier: 录音/输入时的语言标识，nil 时回退到当前系统 locale。
    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        let startedAt = Date()
        let effectiveLocaleIdentifier = resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        VoiceTodoLog.store.info("store.add_raw.start extractID=\(VoiceTodoLog.extractID ?? "none", privacy: .public) locale=\(effectiveLocaleIdentifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        let todoItem = TodoItem.rawTranscript(transcript)
        todoItem.localeIdentifier = effectiveLocaleIdentifier
        todoItem.sortOrder = try nextSortOrderForNewItem()
        modelContext.insert(todoItem)

        try saveOrRollback()
        let data = todoItem.toData()
        todos.insert(data, at: 0)
        VoiceTodoLog.store.info("store.add_raw.success id=\(todoItem.id.uuidString, privacy: .public) locale=\(effectiveLocaleIdentifier, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return data
    }

    /// 切换完成状态
    /// - Parameter id: 待办 ID
    func toggleComplete(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.toggle.start id=\(id.uuidString, privacy: .public)")
        let todoItem = try findTodoItem(by: id)

        todoItem.isCompleted.toggle()
        todoItem.completedAt = todoItem.isCompleted ? Date() : nil

        try saveOrRollback()
        // 增量更新：修改对应条目
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.toggle.success id=\(id.uuidString, privacy: .public) isCompleted=\(todoItem.isCompleted) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 删除待办
    /// - Parameter id: 待办 ID
    func delete(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.delete.start id=\(id.uuidString, privacy: .public)")
        let todoItem = try findTodoItem(by: id)

        try deleteCompletions(for: id)
        modelContext.delete(todoItem)

        try saveOrRollback()
        // 增量更新：移除对应条目
        todos.removeAll { $0.id == id }
        VoiceTodoLog.store.info("store.delete.success id=\(id.uuidString, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 更新待办
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - title: 新标题
    ///   - category: 新分类（nil 表示不修改）
    ///   - priority: 新优先级（nil 表示不修改）
    ///   - dueHint: 新时间提示（nil 表示不修改，空字符串清除）
    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil) throws {
        try update(id, title: title, category: category, priority: priority, dueHint: dueHint, recurrenceRule: nil, shouldUpdateRecurrence: false)
    }

    /// 原子更新待办详情（基础字段 + 重复规则）
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - title: 新标题
    ///   - category: 新分类（nil 表示不修改）
    ///   - priority: 新优先级（nil 表示不修改）
    ///   - dueHint: 新时间提示（nil 表示不修改，空字符串清除）
    ///   - recurrenceRule: 新重复规则（nil 表示关闭重复）
    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil, recurrenceRule: RecurrenceRule?) throws {
        try update(id, title: title, category: category, priority: priority, dueHint: dueHint, recurrenceRule: recurrenceRule, shouldUpdateRecurrence: true)
    }

    private func update(
        _ id: UUID,
        title: String,
        category: TodoCategory?,
        priority: Priority?,
        dueHint: String?,
        recurrenceRule: RecurrenceRule?,
        shouldUpdateRecurrence: Bool
    ) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.update.start id=\(id.uuidString, privacy: .public) titleChars=\(title.count) category=\(category?.rawValue ?? "nil", privacy: .public) priority=\(priority?.rawValue ?? "nil", privacy: .public) dueHintChars=\(dueHint?.count ?? -1) shouldUpdateRecurrence=\(shouldUpdateRecurrence)")
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
            // 手动编辑只有 freeform 文本、没有结构化钟点，回退全天事件。
            todoItem.hasDueTime = false
        }
        if shouldUpdateRecurrence {
            todoItem.recurrenceRule = recurrenceRule?.isValid == true ? recurrenceRule : nil

            if todoItem.recurrenceRule == nil {
                try deleteCompletions(for: id)
            } else {
                todoItem.isCompleted = false
                todoItem.completedAt = nil
            }
        }

        try saveOrRollback()
        // 增量更新：修改对应条目
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.update.success id=\(id.uuidString, privacy: .public) recurrenceSet=\(todoItem.recurrenceRule != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 更新重复规则（nil 表示关闭重复）
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - recurrenceRule: 新重复规则
    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.update_recurrence.start id=\(id.uuidString, privacy: .public) recurrenceSet=\(recurrenceRule != nil)")
        let todoItem = try findTodoItem(by: id)
        todoItem.recurrenceRule = recurrenceRule?.isValid == true ? recurrenceRule : nil

        if todoItem.recurrenceRule == nil {
            try deleteCompletions(for: id)
        } else {
            todoItem.isCompleted = false
            todoItem.completedAt = nil
        }

        try saveOrRollback()
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.update_recurrence.success id=\(id.uuidString, privacy: .public) recurrenceSet=\(todoItem.recurrenceRule != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 获取日期区间内实际出现的待办。
    /// - Parameters:
    ///   - startDate: 区间开始
    ///   - endDate: 区间结束
    /// - Returns: 展开的日历 occurrence
    /// - Note: 读查询下沉到 `queryActor` 后台执行；失败显式抛出。
    func calendarOccurrences(from startDate: Date, to endDate: Date) async throws -> [TodoOccurrenceData] {
        try await queryActor.calendarOccurrences(from: startDate, to: endDate)
    }

    /// 切换某一天的完成状态；重复任务只影响当天 occurrence。
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - date: occurrence 日期
    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.toggle_occurrence.start id=\(id.uuidString, privacy: .public) date=\(date.ISO8601Format(), privacy: .public)")
        let todoItem = try findTodoItem(by: id)
        guard let recurrenceRule = todoItem.recurrenceRule else {
            try toggleComplete(id)
            return
        }

        let day = Calendar.current.startOfDay(for: date)
        guard recurrenceRule.occurs(on: day, startDate: todoItem.dueDate ?? todoItem.createdAt) else {
            VoiceTodoLog.store.warning("store.toggle_occurrence.ignored id=\(id.uuidString, privacy: .public) reason=non_occurring_date date=\(day.ISO8601Format(), privacy: .public)")
            return
        }

        let key = TodoOccurrenceCompletion.key(todoId: id, occurrenceDate: day)

        do {
            if let existing = try findCompletion(by: key) {
                modelContext.delete(existing)
            } else {
                modelContext.insert(TodoOccurrenceCompletion(todoId: id, occurrenceDate: day))
            }
            try saveOrRollback()
            refreshTodos()
            VoiceTodoLog.store.info("store.toggle_occurrence.success id=\(id.uuidString, privacy: .public) key=\(key, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } catch {
            VoiceTodoLog.store.error("store.toggle_occurrence.failed id=\(id.uuidString, privacy: .public) key=\(key, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .write)
        }
    }

    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）
    /// - Returns: 待处理条目数组
    /// - Note: 读查询下沉到 `queryActor` 后台执行；失败显式抛出。
    func pendingItems() async throws -> [TodoItemData] {
        try await queryActor.pendingItems()
    }

    /// 获取最近 N 条未完成待办（Widget 用）
    /// - Parameter limit: 返回数量限制
    /// - Returns: 未完成待办数组
    /// - Note: 读查询下沉到 `queryActor` 后台执行；失败显式抛出。
    func recentUncompleted(limit: Int) async throws -> [TodoItemData] {
        try await queryActor.recentUncompleted(limit: limit)
    }

    /// 替换待处理条目为提取结果（网络恢复后用）[v2]
    /// SwiftData 在 save() 前只在内存中操作，crash 不会持久化部分数据
    /// - Parameters:
    ///   - pendingId: 待处理条目 ID
    ///   - items: AI 提取结果
    ///   - rawTranscript: 合并的原始转写文本（多个 pending 合并时覆盖 pending 自身的）
    func replacePendingWithExtracted(
        _ pendingId: UUID,
        _ items: [ExtractedTodo],
        rawTranscript: String? = nil
    ) throws {
        try replacePendingWithExtracted(
            pendingId,
            items,
            rawTranscript: rawTranscript,
            localeIdentifier: nil
        )
    }

    func replacePendingWithExtracted(
        _ pendingId: UUID,
        _ items: [ExtractedTodo],
        rawTranscript: String? = nil,
        localeIdentifier: String? = nil
    ) throws {
        try replacePendingBatchWithExtracted([pendingId], items, rawTranscript: rawTranscript, localeIdentifier: localeIdentifier)
    }

    func replacePendingBatchWithExtracted(
        _ pendingIds: [UUID],
        _ items: [ExtractedTodo],
        rawTranscript: String? = nil
    ) throws {
        try replacePendingBatchWithExtracted(
            pendingIds,
            items,
            rawTranscript: rawTranscript,
            localeIdentifier: nil
        )
    }

    func replacePendingBatchWithExtracted(
        _ pendingIds: [UUID],
        _ items: [ExtractedTodo],
        rawTranscript: String? = nil,
        localeIdentifier: String? = nil
    ) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.replace_pending_batch.start pending=\(VoiceTodoLog.idsSummary(pendingIds), privacy: .public) extractID=\(VoiceTodoLog.extractID ?? "none", privacy: .public) newCount=\(items.count) locale=\(localeIdentifier ?? "auto", privacy: .public) rawTranscriptChars=\(rawTranscript?.count ?? -1)")
        guard !pendingIds.isEmpty else {
            VoiceTodoLog.store.error("store.replace_pending_batch.failed reason=empty_pending_ids")
            throw VoiceTodoError.storageReadFailed("未提供待处理 ID")
        }

        let pendingItems = try pendingIds.map { try findTodoItem(by: $0) }
        let effectiveTranscript = rawTranscript ?? pendingItems.compactMap(\.rawTranscript).joined(separator: "\n---\n")
        let fallbackLocaleIdentifier = resolveLocaleIdentifier(
            localeIdentifier
                ?? pendingItems.first(where: { ($0.localeIdentifier ?? "").isEmpty == false })?.localeIdentifier,
            fallback: Locale.current.identifier
        )

        var baseSortOrder = try nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            let todoItem = TodoItem.from(item, rawTranscript: effectiveTranscript)
            todoItem.sortOrder = baseSortOrder
            todoItem.localeIdentifier = resolveLocaleIdentifier(localeIdentifier ?? item.localeIdentifier, fallback: fallbackLocaleIdentifier)
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        for pendingItem in pendingItems {
            modelContext.delete(pendingItem)
        }

        try saveOrRollback()
        let pendingSet = Set(pendingIds)
        todos.removeAll { pendingSet.contains($0.id) }
        todos.insert(contentsOf: newTodos.reversed(), at: 0)
        VoiceTodoLog.store.info("store.replace_pending_batch.success pendingCount=\(pendingIds.count) newCount=\(items.count) locale=\(fallbackLocaleIdentifier, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    func resetForUITests() throws {
        VoiceTodoLog.store.warning("store.reset_for_ui_tests.start")
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            for item in items {
                modelContext.delete(item)
            }
            let completions = try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>())
            for completion in completions {
                modelContext.delete(completion)
            }
            try saveOrRollback()
            todos = []
            VoiceTodoLog.store.warning("store.reset_for_ui_tests.success deletedItems=\(items.count) deletedCompletions=\(completions.count)")
        } catch {
            VoiceTodoLog.store.error("store.reset_for_ui_tests.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .write)
        }
    }

    func seedForUITests(_ items: [TodoItemData]) throws {
        VoiceTodoLog.store.warning("store.seed_for_ui_tests.start count=\(items.count)")
        for item in items {
            let todoItem = TodoItem(
                id: item.id,
                title: item.title,
                detail: item.detail,
                dueHint: item.dueHint,
                dueDate: item.dueDate,
                hasDueTime: item.hasDueTime,
                recurrenceRule: item.recurrenceRule,
                priority: item.priority,
                category: item.category,
                isCompleted: item.isCompleted,
                createdAt: item.createdAt,
                rawTranscript: item.rawTranscript,
                needsAIProcessing: item.needsAIProcessing,
                sortOrder: item.sortOrder,
                systemCalendarEventIdentifier: item.systemCalendarEventIdentifier,
                localeIdentifier: item.localeIdentifier
            )
            modelContext.insert(todoItem)
        }

        try saveOrRollback()
        refreshTodos()
        VoiceTodoLog.store.warning("store.seed_for_ui_tests.success count=\(items.count) total=\(self.todos.count)")
    }

    /// 记录系统日历事件 ID。
    /// - Parameters:
    ///   - eventIdentifier: 系统日历事件 ID
    ///   - id: 待办 ID
    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.calendar_identifier.update_start todoID=\(id.uuidString, privacy: .public) eventID=\(eventIdentifier ?? "nil", privacy: .public)")
        let todoItem = try findTodoItem(by: id)
        todoItem.systemCalendarEventIdentifier = eventIdentifier

        try saveOrRollback()
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.calendar_identifier.update_success todoID=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 重新排序未完成待办（拖拽排序后调用）
    /// - Parameter ids: 按新顺序排列的待办 ID 数组
    func reorder(ids: [UUID]) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.reorder.start ids=\(VoiceTodoLog.idsSummary(ids), privacy: .public)")
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted }
        )
        let allUncompleted: [TodoItem]
        do {
            allUncompleted = try modelContext.fetch(descriptor)
        } catch {
            VoiceTodoLog.store.error("store.reorder.fetch_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
        let itemMap = Dictionary(uniqueKeysWithValues: allUncompleted.map { ($0.id, $0) })

        var itemsToUpdate = [(TodoItem, Int)]()
        for (index, id) in ids.enumerated() {
            guard let item = itemMap[id] else {
                VoiceTodoLog.store.error("store.reorder.missing_id id=\(id.uuidString, privacy: .public)")
                throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
            }
            itemsToUpdate.append((item, index))
        }

        for (item, order) in itemsToUpdate {
            item.sortOrder = order
        }

        try saveOrRollback()
        refreshTodos()
        VoiceTodoLog.store.info("store.reorder.success count=\(ids.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    // MARK: - Internal Methods

    /// 全量刷新 todos 属性（从数据库重新加载）
    /// 初始化时及 app 回前台时调用（同步 Widget 在 Extension 进程中的修改）
    func refreshTodos() {
        let startedAt = Date()
        let descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        do {
            let items = try modelContext.fetch(descriptor)
            todos = items.map { $0.toData() }
            // 仅在 fetch 成功后同步版本号；失败时不推进，保证下次 refreshIfStale 仍会重试
            lastSyncedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()
            VoiceTodoLog.store.debug("store.refresh.success count=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } catch {
            VoiceTodoLog.store.error("store.refresh.failed durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    /// P6: 统一失效入口。仅当外部变更版本变化（或强制）时才全量重读，避免无谓 fetch。
    /// 前台、Widget 写回、Action Button 返回等触发点统一调用它。
    /// - Returns: 是否实际执行了刷新。
    @discardableResult
    func refreshIfStale(force: Bool = false) -> Bool {
        let version = AppGroupConfig.currentExternalChangeVersion()
        guard force || version != lastSyncedExternalChangeVersion else {
            VoiceTodoLog.store.debug("store.refresh_if_stale.skip version=\(version)")
            return false
        }
        VoiceTodoLog.store.info("store.refresh_if_stale.refresh force=\(force) old=\(self.lastSyncedExternalChangeVersion) new=\(version)")
        refreshTodos()
        return true
    }

    // MARK: - Private Methods

    /// 计算新条目的 sortOrder（比当前最小值再小 1，确保排在最前面）
    private func nextSortOrderForNewItem() throws -> Int {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = 1

        do {
            let items = try modelContext.fetch(descriptor)
            let minOrder = items.first?.sortOrder ?? 0
            return minOrder - 1
        } catch {
            VoiceTodoLog.store.error("store.next_sort_order.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    private func saveOrRollback() throws {
        do {
            try saveAction(modelContext)
            VoiceTodoLog.store.debug("store.save.success")
        } catch {
            VoiceTodoLog.store.error("store.save.failed_rollback error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            modelContext.rollback()
            refreshTodos()
            throw VoiceTodoError.wrapStorage(error, for: .write)
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

            VoiceTodoLog.store.info("store.migration.sort_order.start count=\(items.count)")
            for (index, item) in items.enumerated() {
                item.sortOrder = index
            }
            try saveOrRollback()
            VoiceTodoLog.store.info("store.migration.sort_order.success count=\(items.count)")
        } catch {
            VoiceTodoLog.store.error("store.migration.sort_order.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    /// 一次性迁移：旧数据只有 dueHint 时，补齐周/月历视图使用的 dueDate。
    private func migrateDueDatesFromHints() {
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { item in
                item.dueDate == nil && item.dueHint != nil
            }
        )

        do {
            let items = try modelContext.fetch(descriptor)
            var changed = false
            var changedCount = 0
            for item in items {
                guard let dueDate = TodoDueDateResolver.resolve(
                    dueHint: item.dueHint,
                    title: item.title,
                    detail: item.detail ?? "",
                    referenceDate: item.createdAt
                ) else {
                    continue
                }
                item.dueDate = dueDate
                changed = true
                changedCount += 1
            }
            if changed {
                VoiceTodoLog.store.info("store.migration.due_dates.start candidates=\(items.count) changed=\(changedCount)")
                try saveOrRollback()
                VoiceTodoLog.store.info("store.migration.due_dates.success changed=\(changedCount)")
            }
        } catch {
            VoiceTodoLog.store.error("store.migration.due_dates.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
                VoiceTodoLog.store.error("store.find.failed reason=not_found id=\(id.uuidString, privacy: .public)")
                throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
            }
            return item
        } catch {
            VoiceTodoLog.store.error("store.find.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    private func findCompletion(by key: String) throws -> TodoOccurrenceCompletion? {
        var descriptor = FetchDescriptor<TodoOccurrenceCompletion>(
            predicate: #Predicate { $0.occurrenceKey == key }
        )
        descriptor.fetchLimit = 1
        do {
            let completion = try modelContext.fetch(descriptor).first
            VoiceTodoLog.store.debug("store.find_completion.success key=\(key, privacy: .public) found=\(completion != nil)")
            return completion
        } catch {
            VoiceTodoLog.store.error("store.find_completion.failed key=\(key, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    private func deleteCompletions(for todoId: UUID) throws {
        let descriptor = FetchDescriptor<TodoOccurrenceCompletion>(
            predicate: #Predicate { $0.todoId == todoId }
        )
        do {
            let completions = try modelContext.fetch(descriptor)
            for completion in completions {
                modelContext.delete(completion)
            }
            VoiceTodoLog.store.debug("store.delete_completions.success todoID=\(todoId.uuidString, privacy: .public) count=\(completions.count)")
        } catch {
            VoiceTodoLog.store.error("store.delete_completions.failed todoID=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            // 注意：fetch + delete 是写操作（修改库），错误归类为 .write 而非 .read。
            // 之前错归为 .read，导致用户看到 "storage read failed" 文案但实际是 write 失败。
            throw VoiceTodoError.wrapStorage(error, for: .write)
        }
    }
}

private extension TodoStore {
    /// 解析有效的 locale identifier：空串视为无效，回退到 fallback。
    /// 防御旧数据写入 "" 而非 nil 导致 Locale(identifier: "") 退化成根 locale。
    func resolveLocaleIdentifier(_ identifier: String?, fallback: String) -> String {
        if let identifier, !identifier.isEmpty {
            return identifier
        }
        return fallback
    }
}
