import Foundation
import Combine

/// 待办列表读取能力。
/// 注意：返回类型使用 TodoItemData 而非 SwiftData 的 TodoItem。
protocol TodoListReadable: ObservableObject {
    /// 所有待办（按 sortOrder 升序排列）
    var todos: [TodoItemData] { get }

    /// todos 的变更代数。给 SwiftUI `.task(id:)` / `.onChange(id:)` 当 id 用,
    /// 避免拿整个 `[TodoItemData]` 做 Hashable(合成 hash 会遍历 rawTranscript 等全部字符串字段,
    /// 每帧 body 求值都跑一次,详见 docs/completed-todos-performance.md Step 4a)。
    var todosRevision: Int { get }

    /// 按 ID 单条查库,返回 DTO 形式。
    /// 用于 `refreshTodos` 窗口化后,调用方需要访问工作集外(完成于 `completedWindowDays` 之外)
    /// todo 的场景,避免 `store.todos.first(where:)` 漏掉窗口外的项。
    /// - Returns: 找到则返回 TodoItemData;库里无此 id 或读取失败均返回 nil(失败有 error 日志)。
    func findTodo(by id: UUID) -> TodoItemData?
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

/// 已转换好的待办批量导入能力(从系统日历事件、协作同步等来源)。
/// 与 `TodoBatchAdding` 区别:后者接受 AI 提取的 ExtractedTodo 中间结构(走 from 工厂),
/// 这里直接接受已构造好的 TodoItemData(来源已 stamp,跳过 AI 路径)。
/// 主要用于 `SystemCalendarEventImporter` 转换出的日历事件导入(场景 3)。
protocol TodoImporting {
    /// 批量导入已构造好的待办(日历事件导入用)
    func addImportedBatch(_ items: [TodoItemData]) throws
}

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
    /// 完整更新（含 dueDate、时段和重复规则，详情页用）。
    /// dueDate 推迟到更晚用户日时,经 `TaskEventRecorder` 记一条 deferred 事件
    /// (与主操作同事务;判定见 `TaskEventRules.isDeferral`)。
    /// - Parameter origin: 事件来源(详情页传 `.detail`,首页快捷操作走默认 `.app`,
    ///   复盘流程传 `.review`)。
    func updateFull(_ id: UUID, update: TodoDetailUpdate, origin: TaskEventOrigin) throws

    /// 用一组新提取的结果替换现有 TodoItem。
    /// 用于「没能识别」分组的「重新解析」入口:把 outcome != .parsed 的原文条目,
    /// 用 AI 重新提取的结果替换为 .parsed 条目,保留原 id / sortOrder / createdAt / locale
    /// (避免破坏 occurrence 完成记录、widget 缓存等关联)。
    /// 当 `extracted.count > 1` 时,第一条 mutate 原 todo,剩余的逐条插入,
    /// sortOrder 锚定在原 todo 的 sortOrder 之下(详见 `TodoStore.replaceTodo` 实现)。
    func replaceTodo(id: UUID, with extracted: [ExtractedTodo], rawTranscript: String?) throws
}

extension TodoDetailUpdating {
    /// origin 默认 `.app` 的便捷入口:协议要求不能带默认参数,用扩展重载补默认值,
    /// 让既有调用点(HomeView 快捷改时间等)不改签名、零回归。
    func updateFull(_ id: UUID, update: TodoDetailUpdate) throws {
        try updateFull(id, update: update, origin: .app)
    }
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

/// 划掉(放弃)写入能力——复盘「处理没做完的」用。
/// 与 `TodoDeletionWriting` 语义对立:删除是数据消失,划掉是一个有意义的决定,
/// 保留在完成率分母里(拍板 1),且可撤销。
protocol TodoAbandonWriting {
    /// 划掉待办:写 `abandonedAt = Date()` + 记一条 abandoned 事件(同事务)。
    /// - Parameter id: 待办 ID
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`;持久化失败向上抛。
    func abandon(_ id: UUID) throws

    /// 撤销划掉:只清 `abandonedAt` 字段。**不记事件**——拍板 3 的事件集里没有
    /// un-abandoned 类型(撤销状态从 `abandonedAt == nil` 即可推导)。
    /// - Parameter id: 待办 ID
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`;持久化失败向上抛。
    func unabandon(_ id: UUID) throws
}

/// 完整待办写入能力集合。
protocol TodoMutationWriting: TodoCreating, TodoCompletionWriting, TodoDeletionWriting, TodoDetailUpdating, TodoRecurrenceWriting, TodoOrderingWriting, TodoAbandonWriting {}

/// 洞察原料读取能力——复盘流程第 3 步(观察)用。
/// 独立协议不并入 `TodoMutationWriting`:后者已有多个聚合消费方(MockStore 等),
/// 追加要求会迫使无关实现补空壳。
protocol InsightContextReading {
    /// 洞察引擎的原料查询(一次性取齐,口径见 `TodoQueryActor.insightContext`)。
    /// - Important: 读查询在后台 `@ModelActor` 执行;失败显式抛出,不静默回退。
    func insightContext(from startDate: Date, to endDate: Date) async throws -> InsightContext
}

/// 全量任务 id 读取能力(阶段 4)——复盘收尾 `ReviewPinningStore.prune` 用。
/// 不能用 `TodoListReadable.todos`(窗口化工作集)prune:窗口外的置顶 id 会被误删。
/// 只取 id 列表,不映射 DTO,500+ 条时也只是一次轻量列存取。
protocol TodoIDListing {
    /// 库里全部 todo id(与完成/删除状态无关)。
    /// - Important: 读查询在后台 `@ModelActor` 执行;失败显式抛出,不静默回退。
    func allTodoIDs() async throws -> [UUID]
}

/// 拆小写入能力——复盘第 2 步「拆小」按钮用(阶段 3)。
/// 与 `TodoAbandonWriting` 互补:拆小 = 建 N 条子任务(parentTodoId 指向原任务)
/// + 原任务标 abandonedAt + 记 split 事件,三步同事务。
protocol TodoSplitting {
    /// - Throws: 条目不存在抛 `todoNotFound`;children 为空是调用方契约违反,显式抛。
    func splitTodo(_ id: UUID, children: [TodoItemData]) throws
}

/// 复盘五步流程需要的 store 能力集合(阶段 3,`ReviewFlowView` 的依赖类型)。
protocol ReviewFlowStore: TodoListReadable, TodoMutationWriting, InsightContextReading, TodoSplitting, TodoIDListing {}

/// 日历 occurrence 读取与写入能力。
protocol CalendarOccurrenceStore {
    /// 获取日期区间内实际出现的待办
    /// - Important: 读查询在后台 `@ModelActor` 执行；fetch 失败显式抛出，不静默回退。
    func calendarOccurrences(from startDate: Date, to endDate: Date) async throws -> [TodoOccurrenceData]

    /// 区间内完成的「无安排」任务(供首页「已完成」分区按需加载工作集外的历史)。
    /// 口径与 `HomeCalendarState.completedUnscheduledTodos` 严格一致,详见
    /// `TodoQueryActor.completedUnscheduled(from:to:)` 的文档注释。
    /// - Important: 读查询在后台 `@ModelActor` 执行;fetch 失败显式抛出。
    func completedUnscheduled(from startDate: Date, to endDate: Date) async throws -> [TodoItemData]

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

    /// 添加「手动卡片」转写（确定性解析失败兜底用）。
    ///
    /// 与 `addRawTranscript` 的区别:产物 `needsAIProcessing = false` + `extractionOutcome = .unparsed`,
    /// 不被 PendingRecoveryFlow 自动认领重试(确定性错误自动重试必败且烧额度),
    /// 但在「没能识别」分组可见,用户可手动「重新解析」或编辑。
    /// - Returns: 创建出的手动卡片待办。
    func addManualUnparsedTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData
}

/// Pending 转写转持能力:把已存在的 pending 条目翻转为手动卡片。
///
/// 用于 PendingRecoveryFlow 恢复失败 / 恢复产出 0 条待办的场景——原文保留为
/// 手动卡片,停止自动重试,避免「每次前台必败 + 烧一次额度」的死循环。
protocol PendingTranscriptHolding {
    /// 把 pending 条目转持为手动卡片(needsAIProcessing=false + .unparsed)。
    /// - Throws: 条目不存在时抛 `VoiceTodoError.todoNotFound`;持久化失败向上抛。
    func holdPendingAsUnparsed(id: UUID) throws
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

/// 数据体检读取能力——阶段 0 诊断用,
/// 见 docs/todo-review-flow-design.md「阶段 0 · 数据体检」。
/// UI 入口在 HomeSettingsSheet 的 DEBUG section(编译期裁剪);
/// 协议本身不包 #if,因为协议继承列表(HomeTodoStore)无法条件编译,
/// Release 下保留一个无人调用的读取方法,无行为影响。
protocol TodoDiagnosticsReading {
    /// 全量取库(不受 `todos` 窗口化过滤影响),供数据体检统计。
    /// 失败时显式 throws,调用方负责打 error 日志,不许用默认值掩盖。
    func diagnosticsAllItems() throws -> [TodoItemData]
}

/// 待办刷新能力。
protocol TodoRefreshing {
    /// 从数据库重新加载 todos（用于 UI 状态与数据层不一致时回滚）
    func refreshTodos()
}

/// Home 页需要列表、完成切换、日历 occurrence、无日期任务拖拽排序,以及排序失败时的刷新回滚。
/// 含详情更新(`TodoDetailUpdating`)——chip 改时间 popover 需要直接走 store.updateTime,
/// 而不是绕一层 coordinator(避免 HomeView 与 AppCoordinator 的耦合进一步加深)。
protocol HomeTodoStore: TodoListReadable, TodoCompletionWriting, CalendarOccurrenceStore, TodoOrderingWriting, TodoRefreshing, TodoDetailUpdating, TodoDiagnosticsReading {}

/// AppCoordinator 直接编排待办批量保存、删除、详情更新、pending 替换和日历导入。
protocol AppCoordinatorTodoStore: TodoListReadable, TodoBatchAdding, TodoDeletionWriting, TodoDetailUpdating, PendingTranscriptReplacing, TodoCompletionWriting, TodoImporting, TodoOrderingWriting {}

/// Pending 恢复流程只需要读取 pending、删除无效 pending、把无产出/确定性失败的 pending 转持为手动卡片。
protocol PendingRecoveryTodoStore: PendingTranscriptReadable, TodoDeletionWriting, PendingTranscriptHolding {}

/// 系统日历同步只需要读取当前待办并持久化系统日历事件 ID。
protocol CalendarSyncTodoStore: TodoListReadable, SystemCalendarEventIdentifierWriting {}

extension PendingTranscriptCreating {
    /// 添加原始转写文本（离线降级用），使用当前系统 locale。
    func addRawTranscript(_ transcript: String) throws -> TodoItemData {
        try addRawTranscript(transcript, localeIdentifier: nil)
    }
}
