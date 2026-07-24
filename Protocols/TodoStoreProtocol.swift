import Foundation
import Combine

/// 待办列表读取能力。
/// 注意：返回类型使用 TodoItemData 而非 SwiftData 的 TodoItem。
protocol TodoListReadable: ObservableObject {
    /// 所有待办（按 sortOrder 升序排列）
    var todos: [TodoItemData] { get }
}

/// 单条待办创建能力。
protocol TodoAdding {
    /// 添加单条待办
    func add(_ item: ExtractedTodo) throws
}

/// 批量待办创建能力。
protocol TodoBatchAdding {
    /// 批量添加（确认界面用）
    func addBatch(_ items: [ExtractedTodo]) throws

    /// 批量添加（确认界面用），保留输入时的语言标识。
    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws
}

/// 待办创建能力。
protocol TodoCreating: TodoAdding, TodoBatchAdding {}

/// 完成状态写入能力。
protocol TodoCompletionWriting {
    /// 切换完成状态
    func toggleComplete(_ id: UUID) throws
}

/// 待办删除能力。
protocol TodoDeletionWriting {
    /// 删除待办
    func delete(_ id: UUID) throws
}

/// 待办详情与重复规则原子写入能力。
protocol TodoDetailUpdating {
    /// 完整更新（含 dueDate、时段和重复规则，详情页用）
    func updateFull(_ id: UUID, update: TodoDetailUpdate) throws

    /// 用一组新提取的结果替换现有 TodoItem。
    /// 用于「没能识别」分组的「重新解析」入口:把 outcome != .parsed 的原文条目,
    /// 用 AI 重新提取的结果替换为 .parsed 条目,保留原 id / sortOrder / createdAt / locale
    /// (避免破坏 occurrence 完成记录、widget 缓存等关联)。
    /// 当 `extracted.count > 1` 时,第一条 mutate 原 todo,剩余的逐条插入,
    /// sortOrder 锚定在原 todo 的 sortOrder 之下(详见 `TodoStore.replaceTodo` 实现)。
    func replaceTodo(id: UUID, with extracted: [ExtractedTodo], rawTranscript: String?) throws
}

extension TodoDetailUpdating where Self: TodoListReadable {
    /// 仅更新时间相关字段(hasDueTime / dueDate / timeBucket),其他字段不动。
    /// 用于 Home 页时间 chip 点击后的改时间 popover。
    ///
    /// 默认实现:读现有 todo → 拼 TodoDetailUpdate → 走 updateFull。
    /// 实现层可在 `TodoStore` 重写此方法做单字段 UPDATE,避免全字段往返。
    func updateTime(
        for id: UUID,
        hasDueTime: Bool,
        dueDate: Date?,
        timeBucket: TimeBucket?
    ) throws {
        guard let existing = todos.first(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        let update = TodoDetailUpdate(
            title: existing.title,
            detail: existing.detail,
            category: existing.category,
            priority: existing.priority,
            dueDate: dueDate,
            hasDueTime: hasDueTime,
            timeBucket: timeBucket,
            dueHint: existing.dueHint,
            recurrenceRule: existing.recurrenceRule
        )
        try updateFull(id, update: update)
    }
}

/// 重复规则写入能力。
protocol TodoRecurrenceWriting {
    /// 更新重复规则（nil 表示关闭重复）
    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws
}

/// 待办排序写入能力。
protocol TodoOrderingWriting {
    /// 重新排序未完成待办（拖拽排序后调用）
    /// - Parameter ids: 按新顺序排列的待办 ID 数组
    func reorder(ids: [UUID]) throws
}

/// 完整待办写入能力集合。
protocol TodoMutationWriting: TodoCreating, TodoCompletionWriting, TodoDeletionWriting, TodoDetailUpdating, TodoRecurrenceWriting, TodoOrderingWriting {}

/// 日历 occurrence 读取与写入能力。
protocol CalendarOccurrenceStore {
    /// 获取日期区间内实际出现的待办
    /// - Important: 读查询在后台 `@ModelActor` 执行；fetch 失败显式抛出，不静默回退。
    func calendarOccurrences(from startDate: Date, to endDate: Date) async throws -> [TodoOccurrenceData]

    /// 切换某一天的完成状态；重复任务只影响当天 occurrence
    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws
}

extension CalendarOccurrenceStore {
    /// 获取日期区间内的 occurrence，并按日历日分组供 Home 月历渲染。
    func groupedCalendarOccurrences(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar = .current
    ) async throws -> [String: [TodoOccurrenceData]] {
        let occurrences = try await calendarOccurrences(from: startDate, to: endDate)
        return Dictionary(grouping: occurrences) { occurrence in
            TodoOccurrenceData.dayKey(for: occurrence.occurrenceDate, calendar: calendar)
        }
    }
}

/// Pending 转写读取能力。
protocol PendingTranscriptReadable {
    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）
    /// - Important: 读查询在后台 `@ModelActor` 执行；fetch 失败显式抛出，不静默回退。
    func pendingItems() async throws -> [TodoItemData]
}

/// Pending 转写创建能力。
protocol PendingTranscriptCreating {
    /// 添加原始转写文本（离线降级用）[v2]
    /// - Returns: 创建出的待处理待办，用于外部记录 pending 关联。
    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData
}

/// Widget 待办读取能力。
protocol WidgetTodoReadable {
    /// 获取最近 N 条未完成待办（Widget 用）
    /// - Important: 读查询在后台 `@ModelActor` 执行；fetch 失败显式抛出，不静默回退。
    func recentUncompleted(limit: Int) async throws -> [TodoItemData]
}

/// Pending 转写替换能力。
protocol PendingTranscriptReplacing {
    /// 替换待处理条目为提取结果（网络恢复后用）[v2]
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws

    /// 替换待处理条目为提取结果（网络恢复后用），保留输入时的语言标识。
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?, localeIdentifier: String?) throws

    /// 批量替换多个待处理条目为提取结果（确保同一批次原子提交）
    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?) throws

    /// 批量替换多个待处理条目为提取结果，保留输入时的语言标识。
    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?, localeIdentifier: String?) throws
}

/// Pending 转写完整能力集合。
protocol PendingTranscriptStore: PendingTranscriptReadable, PendingTranscriptCreating, PendingTranscriptReplacing {}

/// 系统日历事件标识写入能力。
protocol SystemCalendarEventIdentifierWriting {
    /// 记录系统日历事件 ID（用于避免后续重复写入和未来同步）
    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws
}

/// 待办刷新能力。
protocol TodoRefreshing {
    /// 从数据库重新加载 todos（用于 UI 状态与数据层不一致时回滚）
    func refreshTodos()
}

/// Home 页需要列表、完成切换、日历 occurrence、无日期任务拖拽排序,以及排序失败时的刷新回滚。
/// 含详情更新(`TodoDetailUpdating`)——chip 改时间 popover 需要直接走 store.updateTime,
/// 而不是绕一层 coordinator(避免 HomeView 与 AppCoordinator 的耦合进一步加深)。
protocol HomeTodoStore: TodoListReadable, TodoCompletionWriting, CalendarOccurrenceStore, TodoOrderingWriting, TodoRefreshing, TodoDetailUpdating {}

/// AppCoordinator 直接编排待办批量保存、删除、详情更新和 pending 替换。
protocol AppCoordinatorTodoStore: TodoListReadable, TodoBatchAdding, TodoDeletionWriting, TodoDetailUpdating, PendingTranscriptReplacing, TodoCompletionWriting {}

/// Pending 恢复流程只需要读取 pending 与删除无效 pending。
protocol PendingRecoveryTodoStore: PendingTranscriptReadable, TodoDeletionWriting {}

/// 系统日历同步只需要读取当前待办并持久化系统日历事件 ID。
protocol CalendarSyncTodoStore: TodoListReadable, SystemCalendarEventIdentifierWriting {}

extension PendingTranscriptCreating {
    /// 添加原始转写文本（离线降级用），使用当前系统 locale。
    func addRawTranscript(_ transcript: String) throws -> TodoItemData {
        try addRawTranscript(transcript, localeIdentifier: nil)
    }
}
