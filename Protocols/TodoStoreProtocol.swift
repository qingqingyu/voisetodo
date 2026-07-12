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

/// 基础待办详情写入能力。
protocol TodoBasicUpdating {
    /// 更新待办（支持标题、分类、优先级、时间提示）
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws
}

/// 待办详情与重复规则原子写入能力。
protocol TodoDetailUpdating {
    /// 原子更新待办详情（基础字段 + 重复规则）
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws

    /// 完整更新（含 dueDate + detail + hasDueTime，详情页用）
    func updateFull(_ id: UUID, title: String, detail: String?, category: TodoCategory?, priority: Priority?, dueDate: Date?, hasDueTime: Bool?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws
}

extension TodoDetailUpdating {
    /// 默认实现：忽略 dueDate/detail/hasDueTime，回退到基础 update
    func updateFull(_ id: UUID, title: String, detail: String?, category: TodoCategory?, priority: Priority?, dueDate: Date?, hasDueTime: Bool?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {
        try update(id, title: title, category: category, priority: priority, dueHint: dueHint, recurrenceRule: recurrenceRule)
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
protocol TodoMutationWriting: TodoCreating, TodoCompletionWriting, TodoDeletionWriting, TodoBasicUpdating, TodoDetailUpdating, TodoRecurrenceWriting, TodoOrderingWriting {}

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

/// Home 页需要列表、完成切换、日历 occurrence、无日期任务拖拽排序，以及排序失败时的刷新回滚。
protocol HomeTodoStore: TodoListReadable, TodoCompletionWriting, CalendarOccurrenceStore, TodoOrderingWriting, TodoRefreshing {}

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
