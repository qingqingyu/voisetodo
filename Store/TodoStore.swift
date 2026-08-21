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
    @MainActor ReviewFlowStore,
    @MainActor TodoRefreshing {
    // MARK: - Properties

    /// SwiftData 模型上下文
    private let modelContext: ModelContext
    private let saveAction: (ModelContext) throws -> Void

    /// 只读重查询的后台执行器（独立 ModelContext，跑在 actor executor 上）。
    /// 用主上下文的 container 构造，与主线程写操作共享同一持久化存储。
    private let queryActor: TodoQueryActor

    /// 复盘埋点写入器(deferred / abandoned / split)。只 insert 进主 context,
    /// 事件随本类的 `saveOrRollback()` 与主操作同事务存取(失败一起回滚)。
    private let taskEventRecorder: TaskEventRecorder

    /// 所有待办（按 sortOrder 升序排列）
    @Published var todos: [TodoItemData] = [] {
        didSet { todosRevision &+= 1 }
    }

    /// todos 的变更代数。`@Published` 让 SwiftUI 观察,`private(set)` 限制只读。
    /// 一处 `didSet` 覆盖全部 11 条变更路径(refreshTodos / add / addBatch /
    /// addImportedBatch / addRawTranscript / toggleComplete / delete / updateFull /
    /// updateRecurrence / updateSystemCalendarEventIdentifier / replacePendingBatchWithExtracted)。
    /// 用 `&+=` 溢出加法避免理论上的 Int 溢出崩溃。
    @Published private(set) var todosRevision: Int = 0

    /// 内存工作集里保留的已完成项时间窗(天)。
    /// v1 取保守值可调,窗口外的已完成项仍在库里,由 `TodoQueryActor` 按需查询
    /// (见 docs/completed-todos-performance.md Step 3)。改这个数字不需要数据迁移。
    static let completedWindowDays = 90

    /// 当前 migration 版本。每次给 init 的 migration 序列追加新 migration 时,把此常量 +1。
    /// 已存在库的旧 App 升级到带新 migration 的版本时,init 会跑追加的 migration 然后推进版本号。
    /// - 重要:三个 migration(`purgeLegacyVoiceCaptureRecords` / `migrateOldSortOrder` /
    ///   `migrateDueDatesFromHints`)都是一次性的:详见 docs/completed-todos-performance.md Step 6
    ///   的"为什么是一次性的"表。复核新条目创建入口仍走 `TodoItem.from` 后,门闩是安全的。
    private static let currentMigrationVersion = 1

    /// P6: 上次同步到的外部变更版本（Widget/AppIntent 跨进程写入标记），用于按需失效内存缓存。
    private var lastSyncedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()

    // MARK: - Initialization

    /// 初始化 TodoStore
    /// - Parameters:
    ///   - modelContext: SwiftData 模型上下文
    ///   - saveAction: 自定义保存动作(默认 `context.save()`)
    ///   - forceMigration: 测试用 —— 强制跑全部 migration,无视 AppGroupConfig 门闩。
    ///     生产代码不传(默认 false),让门闩正常生效。测试要传 true,因为 in-memory DB
    ///     是新的但 AppGroupConfig 的 UserDefaults 跨测试持久,门闩会跳过 migration。
    init(
        modelContext: ModelContext,
        saveAction: @escaping (ModelContext) throws -> Void = { try $0.save() },
        forceMigration: Bool = false
    ) {
        self.modelContext = modelContext
        self.saveAction = saveAction
        self.queryActor = TodoQueryActor(modelContainer: modelContext.container)
        self.taskEventRecorder = TaskEventRecorder(modelContext: modelContext)
        let previousMigrationVersion = AppGroupConfig.currentStoreMigrationVersion()
        VoiceTodoLog.store.info("store.init.start previousMigration=\(previousMigrationVersion) target=\(Self.currentMigrationVersion) forceMigration=\(forceMigration)")
        if forceMigration || previousMigrationVersion < Self.currentMigrationVersion {
            purgeLegacyVoiceCaptureRecords()
            migrateOldSortOrder()
            migrateDueDatesFromHints()
            AppGroupConfig.markStoreMigrationCompleted(version: Self.currentMigrationVersion)
            VoiceTodoLog.store.info("store.init.migration.completed version=\(Self.currentMigrationVersion)")
        }
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
        #if DEBUG
        logAddBatchDiag(items: items)
        #endif
        var baseSortOrder = try nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            // 兜底查重:SwiftData @Attribute(.unique) 在 modelContext.insert 时不查重,
            // save 也不报错。如果调用方(例如 ConfirmSheet 重入、Siri intent)传入了
            // 已存在的 id,会产生 id 冲突的重复记录,导致 ForEach 警告、
            // toggleComplete(id) fetchLimit=1 只命中第一条。
            // 这里显式跳过已存在的 id 并记 warning。
            // 用 existingTodoItem 而非 findTodoItem:前者把 not_found 当正常 nil 返回,
            // 只抛真实 SwiftData 读异常——避免 try? 吞掉底层错误。
            if let existing = try existingTodoItem(by: item.id) {
                VoiceTodoLog.store.warning("store.add_batch.skip_duplicate id=\(item.id.uuidString, privacy: .public) existingTitle=\(existing.title, privacy: .public)")
                continue
            }
            let todoItem = TodoItem.from(item)
            todoItem.sortOrder = baseSortOrder
            todoItem.localeIdentifier = resolveLocaleIdentifier(localeIdentifier ?? item.localeIdentifier, fallback: fallbackLocaleIdentifier)
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        // 全部被跳过(整批重复)时 early return:避免空 insert + success count=0 误导日志。
        guard !newTodos.isEmpty else {
            VoiceTodoLog.store.warning("store.add_batch.all_duplicates_skipped requestedCount=\(items.count) locale=\(fallbackLocaleIdentifier, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }

        try saveOrRollback()
        todos.insert(contentsOf: newTodos.reversed(), at: 0)
        VoiceTodoLog.store.info("store.add_batch.success count=\(newTodos.count) locale=\(fallbackLocaleIdentifier, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 批量导入已构造好的待办(系统日历事件导入用)。
    /// 与 `addBatch(_ items: [ExtractedTodo], localeIdentifier:)` 区别:
    /// 直接接受已构造好的 TodoItemData(来源已 stamp),走 `TodoItem.from(_ data:)` 工厂,
    /// 跳过 ExtractedTodo → TodoItem 的 AI 路径(basisFilter 等)。
    func addImportedBatch(_ items: [TodoItemData]) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.add_imported_batch.start count=\(items.count)")
        var baseSortOrder = try nextSortOrderForNewItem()
        var newTodos: [TodoItemData] = []
        for item in items {
            // 兜底查重(与 addBatch 同模式):SwiftData @Attribute(.unique) insert 时不查重。
            if let existing = try existingTodoItem(by: item.id) {
                VoiceTodoLog.store.warning("store.add_imported_batch.skip_duplicate id=\(item.id.uuidString, privacy: .public) existingTitle=\(existing.title, privacy: .public)")
                continue
            }
            let todoItem = TodoItem.from(item)
            todoItem.sortOrder = baseSortOrder
            baseSortOrder -= 1
            modelContext.insert(todoItem)
            newTodos.append(todoItem.toData())
        }

        guard !newTodos.isEmpty else {
            VoiceTodoLog.store.info("store.add_imported_batch.all_duplicates_skipped requestedCount=\(items.count)")
            return
        }

        try saveOrRollback()
        todos.insert(contentsOf: newTodos.reversed(), at: 0)
        VoiceTodoLog.store.info("store.add_imported_batch.success count=\(newTodos.count) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
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

    /// 添加「手动卡片」转写（确定性解析失败兜底用）。
    ///
    /// 产物不参与 PendingRecoveryFlow 自动重试（needsAIProcessing=false）,
    /// 在「没能识别」分组可见（extractionOutcome=.unparsed），用户可手动重新解析。
    /// - Parameters:
    ///   - transcript: 原始语音转写文本
    ///   - localeIdentifier: 录音/输入时的语言标识，nil 时回退到当前系统 locale。
    func addManualUnparsedTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        let startedAt = Date()
        let effectiveLocaleIdentifier = resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        VoiceTodoLog.store.info("store.add_manual_unparsed.start extractID=\(VoiceTodoLog.extractID ?? "none", privacy: .public) locale=\(effectiveLocaleIdentifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        let todoItem = TodoItem.manualUnparsedTranscript(transcript)
        todoItem.localeIdentifier = effectiveLocaleIdentifier
        todoItem.sortOrder = try nextSortOrderForNewItem()
        modelContext.insert(todoItem)

        try saveOrRollback()
        let data = todoItem.toData()
        todos.insert(data, at: 0)
        VoiceTodoLog.store.info("store.add_manual_unparsed.success id=\(todoItem.id.uuidString, privacy: .public) locale=\(effectiveLocaleIdentifier, privacy: .public) total=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return data
    }

    /// 把 pending 条目转持为手动卡片：停止自动重试、原文保留为「没能识别」条目。
    /// - Parameter id: pending 待办 ID
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`。
    func holdPendingAsUnparsed(id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.hold_pending.start id=\(id.uuidString, privacy: .public)")
        let todoItem = try findTodoItem(by: id)

        todoItem.needsAIProcessing = false
        todoItem.extractionOutcome = .unparsed

        try saveOrRollback()
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.hold_pending.success id=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 切换完成状态
    /// - Parameter id: 待办 ID
    func toggleComplete(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.toggle.start id=\(id.uuidString, privacy: .public)")
        // 诊断:走 OSLog 而非 print,与同文件其它诊断一致 + 应用 privacy 规则。
        // title 来自用户语音,用 .public 标注 id 和 isCompleted,title 走默认 private。
        #if DEBUG
        let titleForDiag = todos.first(where: { $0.id == id })?.title ?? "nil"
        VoiceTodoLog.store.info("store.toggle.diag_enter id=\(id.uuidString, privacy: .public) titleChars=\(titleForDiag.count) titlePreview=\(String(titleForDiag.prefix(40)), privacy: .public)")
        #endif
        let todoItem = try findTodoItem(by: id)

        todoItem.isCompleted.toggle()
        todoItem.completedAt = todoItem.isCompleted ? Date() : nil

        try saveOrRollback()
        // 增量更新：修改对应条目
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        #if DEBUG
        VoiceTodoLog.store.info("store.toggle.diag_success id=\(id.uuidString, privacy: .public) newIsCompleted=\(todoItem.isCompleted)")
        #endif
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

    /// 详情页完整更新——支持直接设 dueDate、模糊时段和 detail。
    /// - Parameter origin: dueDate 推迟时的埋点来源(默认 `.app`,见协议扩展;
    ///   详情页经 `AppCoordinator.updateTodoDetail` 传 `.detail`,复盘流程传 `.review`)。
    func updateFull(_ id: UUID, update: TodoDetailUpdate, origin: TaskEventOrigin = .app) throws {
        let startedAt = Date()
        let effectiveBucket = TimeBucketResolver.effective(
            explicitBucket: update.timeBucket,
            dueDate: update.dueDate,
            hasDueTime: update.hasDueTime
        )
        VoiceTodoLog.store.info("store.updateFull.start id=\(id.uuidString, privacy: .public) dueDate=\(update.dueDate != nil) hasDueTime=\(update.hasDueTime) explicitTimeBucket=\(update.timeBucket?.rawValue ?? "nil", privacy: .public) effectiveTimeBucket=\(effectiveBucket.rawValue, privacy: .public)")
        let todoItem = try findTodoItem(by: id)
        let hadRecurrence = todoItem.recurrenceRule != nil
        let oldDueDate = todoItem.dueDate
        let oldIsCompleted = todoItem.isCompleted
        let oldAbandonedAt = todoItem.abandonedAt

        // 先完成可能失败的写操作（删除旧完成记录），再修改 TodoItem。
        // 显式 try 而非 try?：如果 completion 删除失败，说明底层 SwiftData 出了问题，
        // 此时继续修改 TodoItem 可能导致不一致状态（recurrenceRule 清了但 completion 还在）。
        // 放在 mutate 之前：失败时 todoItem 完全未被动过，上下文保持干净。
        if hadRecurrence, update.recurrenceRule == nil {
            try deleteCompletions(for: id)
        }

        todoItem.title = update.title
        todoItem.detail = update.detail
        if let category = update.category { todoItem.category = category }
        if let priority = update.priority { todoItem.priority = priority }
        // dueDate 始终覆盖——nil = 清除日期（详情页 "Remove date" 用）
        todoItem.dueDate = update.dueDate
        todoItem.hasDueTime = update.hasDueTime
        todoItem.timeBucket = update.timeBucket
        // 提醒提前量三态应用(TodoDetailUpdate doc 注释契约):
        // nil = 保留原值(HomeView 快捷改时间等 partial-update 路径不误清),
        // 0 = 清除(准时),正数 = 设置(钳到 1440 = 提前 1 天上限)。
        // 应用后 hasDueTime == false 时无条件清 nil(含 partial-update 传 nil 的路径:
        // 拖拽清钟点/回 unscheduled)——不带钟点的待办提醒无意义,不留脏值给 toData()。
        if update.hasDueTime {
            if let offset = update.reminderOffsetMinutes {
                todoItem.reminderOffsetMinutes = offset > 0 ? min(offset, ReminderOffsetConfig.maxMinutes) : nil
            }
        } else {
            todoItem.reminderOffsetMinutes = nil
        }
        if let dueHint = update.dueHint {
            let normalized = dueHint.trimmingCharacters(in: .whitespacesAndNewlines)
            todoItem.dueHint = normalized.isEmpty ? nil : normalized
        }
        todoItem.recurrenceRule = update.recurrenceRule
        if update.recurrenceRule != nil {
            todoItem.isCompleted = false
            todoItem.completedAt = nil
        }
        // 跨天事件终点:TodoDetailUpdate.init 已跑 TodoSpan.normalized 归一化。
        // M6(详情页编辑入口)未落地前,所有调用方传 nil,此处写入等价于写 nil,零回归;
        // 补这一行是为了闭合字段写入路径,避免「init 归一化了但 updateFull 没落地」的死路径。
        todoItem.eventEndDate = update.eventEndDate

        // 推迟埋点(拍板 3:只记 deferred/abandoned/split)。判定在 mutate 之后、
        // save 之前做:用 mutate 前快照(oldDueDate/oldIsCompleted/oldAbandonedAt)
        // 与 update.dueDate 比较,纯函数 `TaskEventRules.isDeferral` 可独立单测。
        // 事件 insert 与主操作同 context,随下面的 saveOrRollback 一起提交/回滚。
        // 已完成/已划掉不记(推迟语义只对未完成工作成立);同用户日改钟点、
        // 往前改、旧值 nil(首次排期)由 isDeferral 内部排除。
        if TaskEventRules.isDeferral(
            oldDueDate: oldDueDate,
            newDueDate: update.dueDate,
            isCompleted: oldIsCompleted,
            abandonedAt: oldAbandonedAt
        ) {
            taskEventRecorder.recordDeferred(
                todoId: id,
                from: oldDueDate,
                to: update.dueDate,
                origin: origin
            )
        }

        try saveOrRollback()
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index] = todoItem.toData()
        }
        VoiceTodoLog.store.info("store.updateFull.success id=\(id.uuidString, privacy: .public) dueDate=\(update.dueDate != nil) explicitTimeBucket=\(todoItem.timeBucket?.rawValue ?? "nil", privacy: .public) effectiveTimeBucket=\(effectiveBucket.rawValue, privacy: .public) detail=\(update.detail != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 划掉待办(复盘「处理没做完的」用):写 `abandonedAt = Date()` + 记 abandoned 事件。
    /// 与 delete 分开——数据保留,仍在完成率分母里(拍板 1),unabandon 可撤销。
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`;持久化失败向上抛。
    func abandon(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.abandon.start id=\(id.uuidString, privacy: .public)")
        let todoItem = try findTodoItem(by: id)

        let abandonedAt = Date()
        todoItem.abandonedAt = abandonedAt
        taskEventRecorder.recordAbandoned(todoId: id, at: abandonedAt, origin: .review)

        try saveOrRollback()
        // 工作集谓词含 abandonedAt == nil,划掉后条目要出工作集 → 全量刷新
        // (与 toggleOccurrenceComplete 的失败回滚路径同模式),而非增量改内存行。
        refreshTodos()
        VoiceTodoLog.store.info("store.abandon.success id=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 撤销划掉:只清 `abandonedAt`。**不记事件**——拍板 3 的事件集里没有
    /// un-abandoned 类型(撤销状态从 `abandonedAt == nil` 即可推导,阶段 3 的
    /// 「撤销上一张」只恢复最近一次划掉)。
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`;持久化失败向上抛。
    func unabandon(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.unabandon.start id=\(id.uuidString, privacy: .public)")
        let todoItem = try findTodoItem(by: id)

        todoItem.abandonedAt = nil

        try saveOrRollback()
        // 与 abandon 对称:条目要回工作集,全量刷新而非增量改内存行。
        refreshTodos()
        VoiceTodoLog.store.info("store.unabandon.success id=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 用 AI 重新提取的结果替换原 todo(用于「没能识别」分组的「重新解析」入口)。
    /// - 第一条:mutate 原 TodoItem 保留 id / sortOrder / createdAt / locale,outcome 清成 `.parsed`,
    ///   清 `needsAIProcessing`。
    /// - 剩余的:逐条 `TodoItem.from` 创建新条目,sortOrder 锚定在 `preservedSortOrder - 1, -2, ...`,
    ///   让一次 reextract 拆出的多条结果在列表里紧挨原条目,而非被推到末尾。
    /// - 注:锚定区间可能与已存在 todo 的 sortOrder 撞号(tie 时稳定排序兜底,不破坏数据)。
    func replaceTodo(id: UUID, with extracted: [ExtractedTodo], rawTranscript: String?) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.replaceTodo.start id=\(id.uuidString, privacy: .public) newCount=\(extracted.count)")
        guard !extracted.isEmpty else {
            // 调用方(AppCoordinator.reextract)已 guard 过,这里二次防御——
            // 空数组调用 = 调用方契约违反,显式抛而非静默 return。
            throw VoiceTodoError.apiResponseInvalid("replaceTodo with empty extracted")
        }

        let existingItem = try findTodoItem(by: id)
        let preservedSortOrder = existingItem.sortOrder
        let preservedCreatedAt = existingItem.createdAt
        let preservedLocale = existingItem.localeIdentifier

        // 第一条:mutate in place。
        // 通过 updateFull 走完整字段写库,避免漏字段(同详情页 path)。
        let first = extracted[0]
        let firstTodoItem = TodoItem.from(first, rawTranscript: rawTranscript)
        try updateFull(id, update: TodoDetailUpdate(
            title: firstTodoItem.title,
            detail: firstTodoItem.detail,
            category: firstTodoItem.category,
            priority: firstTodoItem.priority,
            dueDate: firstTodoItem.dueDate,
            hasDueTime: firstTodoItem.hasDueTime,
            timeBucket: firstTodoItem.timeBucket,
            dueHint: firstTodoItem.dueHint,
            recurrenceRule: firstTodoItem.recurrenceRule,
            // 重新解析是整体替换语义:AI 新抽的偏移落库,AI 没抽到(准时)则显式清 0。
            reminderOffsetMinutes: firstTodoItem.reminderOffsetMinutes ?? 0
        ))
        // 保留 sortOrder / createdAt / locale:updateFull 没动这些字段,但显式重设防止边缘 case。
        // 显式 try —— updateFull 成功后查不到条目 = 数据一致性异常,不能静默吞(错误显式传播)。
        let updated = try findTodoItem(by: id)
        updated.sortOrder = preservedSortOrder
        updated.createdAt = preservedCreatedAt
        // locale 口径与剩余条目对齐:原条目 locale 优先,原为 nil 才回退到新提取条目的 locale。
        // 旧版只在 nil 时回填 preservedLocale,但 updateFull 已把 locale 留成旧值——
        // 显式 set 让"整条替换"的语义更清晰(用户切语言后重解析仍归档到原 locale)。
        updated.localeIdentifier = preservedLocale ?? updated.localeIdentifier
        updated.extractionOutcome = .parsed
        updated.needsAIProcessing = false
        try saveOrRollback()

        // 剩余的:逐条插入,sortOrder 锚定在 preservedSortOrder 之下(preservedSortOrder-1, -2, ...),
        // 让一次 reextract 拆出的多条结果在列表里紧挨着原条目,而不是被 addBatch 推到列表末尾。
        if extracted.count > 1 {
            let rest = Array(extracted.dropFirst())
            let fallbackLocale = resolveLocaleIdentifier(preservedLocale, fallback: Locale.current.identifier)
            var nextSort = preservedSortOrder - 1
            for item in rest {
                if let existing = try existingTodoItem(by: item.id) {
                    VoiceTodoLog.store.warning("store.replaceTodo.skip_duplicate id=\(item.id.uuidString, privacy: .public) existingTitle=\(existing.title, privacy: .public)")
                    continue
                }
                let todoItem = TodoItem.from(item, rawTranscript: nil)
                todoItem.sortOrder = nextSort
                todoItem.localeIdentifier = resolveLocaleIdentifier(preservedLocale ?? item.localeIdentifier, fallback: fallbackLocale)
                nextSort -= 1
                modelContext.insert(todoItem)
            }
            try saveOrRollback()
        }

        VoiceTodoLog.store.info("store.replaceTodo.success id=\(id.uuidString, privacy: .public) newCount=\(extracted.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
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

    /// 洞察引擎的原料查询(阶段 3 洞察步用;读查询下沉到 `queryActor`)。
    /// 口径见 `TodoQueryActor.insightContext(from:to:)`;失败显式抛出。
    func insightContext(from startDate: Date, to endDate: Date) async throws -> InsightContext {
        try await queryActor.insightContext(from: startDate, to: endDate)
    }

    /// 拆小(复盘第 2 步「拆小」按钮,docs/todo-review-flow-design.md §阶段 3):
    /// 建 N 条子任务(`parentTodoId` 指向原任务)+ 原任务标 `abandonedAt` + 记 split 事件。
    /// 三步同 context 同事务,失败一起回滚(错误显式传播)。
    /// 与 `abandon` 区别:拆小的原任务**只记 split 事件**,不重复记 abandoned 事件
    /// (split 本身已说明任务去向,两条都记会让账本重复计数)。
    /// - Throws: 条目不存在抛 `VoiceTodoError.todoNotFound`;children 为空抛
    ///   `apiResponseInvalid`(调用方契约违反);持久化失败向上抛。
    func splitTodo(_ id: UUID, children: [TodoItemData]) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.split.start id=\(id.uuidString, privacy: .public) childCount=\(children.count)")
        guard !children.isEmpty else {
            throw VoiceTodoError.apiResponseInvalid("splitTodo with empty children")
        }
        let parent = try findTodoItem(by: id)

        var baseSortOrder = try nextSortOrderForNewItem()
        for childData in children {
            let child = TodoItem.from(childData)
            child.parentTodoId = id
            child.sortOrder = baseSortOrder
            baseSortOrder -= 1
            modelContext.insert(child)
        }
        parent.abandonedAt = Date()
        taskEventRecorder.recordSplit(todoId: id, origin: .review)

        try saveOrRollback()
        // 子任务 insert + 原任务出工作集 → 全量刷新(与 abandon 同模式)。
        refreshTodos()
        VoiceTodoLog.store.info("store.split.success id=\(id.uuidString, privacy: .public) childCount=\(children.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 区间内完成的「无安排」任务(供首页「已完成」分区按需加载工作集外的历史数据)。
    /// - Note: 读查询下沉到 `queryActor`;失败显式抛出。口径见 `TodoQueryActor.completedUnscheduled`。
    func completedUnscheduled(from startDate: Date, to endDate: Date) async throws -> [TodoItemData] {
        try await queryActor.completedUnscheduled(from: startDate, to: endDate)
    }

    /// 切换某一天的完成状态；重复任务只影响当天 occurrence。
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - date: occurrence 日期
    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.toggle_occurrence.start id=\(id.uuidString, privacy: .public) date=\(date.ISO8601Format(), privacy: .public)")
        // 诊断:走 OSLog 与同文件其它诊断一致。title 是用户语音,走默认 private + 截断。
        // 不在此处打印 recurrenceRule==nil 的分支(后续会调 toggleComplete,那里会再打印),
        // 避免同一次用户操作产生两行同 id 的日志被误判为重复调用。
        #if DEBUG
        let titleForDiag = todos.first(where: { $0.id == id })?.title ?? "nil"
        VoiceTodoLog.store.info("store.toggle_occurrence.diag_enter id=\(id.uuidString, privacy: .public) date=\(date.ISO8601Format(), privacy: .public) titleChars=\(titleForDiag.count) titlePreview=\(String(titleForDiag.prefix(40)), privacy: .public)")
        #endif
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
        #if DEBUG
        VoiceTodoLog.store.info("store.toggle_occurrence.diag_key key=\(key, privacy: .public)")
        #endif

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
            let historyRecords = try modelContext.fetch(FetchDescriptor<VoiceCaptureRecord>())
            for record in historyRecords {
                modelContext.delete(record)
            }
            let taskEvents = try modelContext.fetch(FetchDescriptor<TaskEvent>())
            for event in taskEvents {
                modelContext.delete(event)
            }
            try saveOrRollback()
            todos = []
            VoiceTodoLog.store.warning("store.reset_for_ui_tests.success deletedItems=\(items.count) deletedCompletions=\(completions.count) deletedLegacyHistory=\(historyRecords.count) deletedTaskEvents=\(taskEvents.count)")
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
                timeBucket: item.timeBucket,
                recurrenceRule: item.recurrenceRule,
                priority: item.priority,
                category: item.category,
                isCompleted: item.isCompleted,
                completedAt: item.completedAt,
                createdAt: item.createdAt,
                rawTranscript: item.rawTranscript,
                needsAIProcessing: item.needsAIProcessing,
                sortOrder: item.sortOrder,
                systemCalendarEventIdentifier: item.systemCalendarEventIdentifier,
                localeIdentifier: item.localeIdentifier,
                eventEndDate: item.eventEndDate
            )
            modelContext.insert(todoItem)
        }

        try saveOrRollback()
        refreshTodos()
        VoiceTodoLog.store.warning("store.seed_for_ui_tests.success count=\(items.count) total=\(self.todos.count)")
    }

    /// 数据体检:全量取库,不受 `todos` 窗口化过滤影响。
    /// 阶段 0 诊断用,见 docs/todo-review-flow-design.md「阶段 0 · 数据体检」。
    /// UI 入口只在 DEBUG 构建下出现;失败显式 throws,调用方负责打 error 日志并如实呈现失败。
    func diagnosticsAllItems() throws -> [TodoItemData] {
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            let data = items.map { $0.toData() }
            VoiceTodoLog.store.info("store.diagnostics.fetch_success count=\(data.count, privacy: .public)")
            return data
        } catch {
            VoiceTodoLog.store.error("store.diagnostics.fetch_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
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

    /// 重新排序（拖拽排序后调用）。
    ///
    /// `ids` 可以是任意未完成待办子集（例如「稍后」section 单独排序）。
    /// 按子集当前最小 sortOrder 作为 base 局部重排，赋值 `base+0, base+1, ...`；
    /// 未在 `ids` 中的 todo 不动 —— 避免子集重排挤压其他 section 顺序。
    /// 全量传入时（`ids` 覆盖所有未完成 todo）等价于重写为 `0..<N`，零回归。
    ///
    /// - Parameter ids: 按新顺序排列的待办 ID 数组（子集或全集）
    func reorder(ids: [UUID]) throws {
        let startedAt = Date()
        VoiceTodoLog.store.info("store.reorder.start ids=\(VoiceTodoLog.idsSummary(ids), privacy: .public)")
        // 空数组 early return:避免无谓的 fetch / saveOrRollback / widget reload。
        guard !ids.isEmpty else {
            VoiceTodoLog.store.info("store.reorder.noop empty ids durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }
        let descriptor = FetchDescriptor<TodoItem>(
            // 已划掉(abandonedAt != nil)的任务不再是可排序的「未完成工作」,排除。
            predicate: #Predicate { !$0.isCompleted && $0.abandonedAt == nil }
        )
        let allUncompleted: [TodoItem]
        do {
            allUncompleted = try modelContext.fetch(descriptor)
        } catch {
            VoiceTodoLog.store.error("store.reorder.fetch_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
        let itemMap = Dictionary(uniqueKeysWithValues: allUncompleted.map { ($0.id, $0) })

        var itemsToUpdate = [(item: TodoItem, index: Int)]()
        for (index, id) in ids.enumerated() {
            guard let item = itemMap[id] else {
                VoiceTodoLog.store.error("store.reorder.missing_id id=\(id.uuidString, privacy: .public)")
                // 与 findTodoItem 同口径:条目缺失抛 .todoNotFound(可被精准捕获断言),
                // UI 文案与 storageReadFailed 同走 ErrorMessages.storageError,用户无感。
                throw VoiceTodoError.todoNotFound(id)
            }
            itemsToUpdate.append((item: item, index: index))
        }
        // 局部重排 base：取这组 ids 当前最小 sortOrder，避免子集重排污染其他 section。
        // 不动其他 todo 的 sortOrder，确保 Today section / 待定日期 section 的相对顺序保持。
        let baseSortOrder = itemsToUpdate.map(\.item.sortOrder).min() ?? 0
        for (item, index) in itemsToUpdate {
            item.sortOrder = baseSortOrder + index
        }

        try saveOrRollback()
        refreshTodos()
        VoiceTodoLog.store.info("store.reorder.success count=\(ids.count) base=\(baseSortOrder) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    // MARK: - Internal Methods

    /// 刷新 todos 工作集(从数据库重新加载)。
    /// 工作集 = 全部未完成 + 近 `completedWindowDays` 天的已完成。
    /// 初始化时及 app 回前台时调用(同步 Widget 在 Extension 进程中的修改)。
    /// 窗口外的已完成项仍在库里,由 `TodoQueryActor` 按需查询(见
    /// docs/completed-todos-performance.md Step 3)。
    func refreshTodos() {
        let startedAt = Date()
        let cutoff = DayClock.startOfUserDay(for: Date())
            .addingTimeInterval(-Double(Self.completedWindowDays) * 86_400)
        // SwiftData #Predicate 不支持 ForcedUnwrap(`!`) 和 inline 静态成员(如 `.distantPast`);
        // 必须把常量提到闭包外作为局部 let,才能在谓词里用 `??` 兜底 Optional。
        // 详见 docs/completed-todos-performance.md Step 2「兜底 2」。
        let distantPast = Date.distantPast

        let pending = FetchDescriptor<TodoItem>(
            // 工作集 = 未完成 && 未划掉:划掉的任务对首页/widget 是不可见工作
            // (仍在库里、仍在完成率分母——分母走 ReviewView 的 @Query,不经此谓词)。
            predicate: #Predicate { !$0.isCompleted && $0.abandonedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        let recentDone = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.isCompleted && ($0.completedAt ?? distantPast) >= cutoff },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )

        do {
            // 拆两次 fetch 而非 ||  复合谓词:让 SQLite 各自命中 isCompleted / completedAt 索引,
            // 复合 OR 谓词通常退化成全表扫描。
            let items = try modelContext.fetch(pending) + modelContext.fetch(recentDone)
            // 两批各自有序,合并后按 sortOrder 重排,保持与原实现一致的全局顺序
            todos = items.sorted { $0.sortOrder < $1.sortOrder }.map { $0.toData() }
            // 仅在 fetch 成功后同步版本号;失败时不推进,保证下次 refreshIfStale 仍会重试
            lastSyncedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()
            VoiceTodoLog.store.debug("store.refresh.success count=\(self.todos.count) windowDays=\(Self.completedWindowDays) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
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

    // MARK: - Lookup

    /// 按 ID 单条查库,返回 DTO 形式。
    /// 用于 `refreshTodos` 窗口化后,调用方需要访问工作集外(完成于 `completedWindowDays` 之外)
    /// todo 的场景,避免 `store.todos.first(where:)` 漏掉窗口外的项。
    /// - Parameter id: 待办 ID
    /// - Returns: 找到则返回 TodoItemData;库里无此 id 或读取失败均返回 nil。
    ///   读取失败会打 error 日志(显式记录,不静默吞);返回 nil 是因为调用方通常用
    ///   `guard let` / `if let` 处理,无法合理恢复数据库读取错误,降级为"找不到"
    ///   比强制 throw 让用户操作整体失败更合理。
    func findTodo(by id: UUID) -> TodoItemData? {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first?.toData()
        } catch {
            VoiceTodoLog.store.error("store.find_todo.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return nil
        }
    }

    /// 库里是否存在任意已完成项(用于空态判定,避免窗口外全完成时误判为空)。
    /// 走 SQL COUNT(`isCompleted` 索引兜底),不 materialize 任何行。
    /// 读取错误时返回 false,代价是空态误判,优于崩溃;错误已打日志。
    func hasAnyCompletedInDb() -> Bool {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.isCompleted }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetchCount(descriptor) > 0
        } catch {
            VoiceTodoLog.store.error("store.has_any_completed.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return false
        }
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

    /// 一次性迁移：清理已移除的语音历史功能遗留记录。
    private func purgeLegacyVoiceCaptureRecords() {
        do {
            let records = try modelContext.fetch(FetchDescriptor<VoiceCaptureRecord>())
            guard !records.isEmpty else { return }

            VoiceTodoLog.store.info("store.migration.legacy_voice_capture.start count=\(records.count)")
            for record in records {
                modelContext.delete(record)
            }
            try saveOrRollback()
            VoiceTodoLog.store.info("store.migration.legacy_voice_capture.success count=\(records.count)")
        } catch {
            VoiceTodoLog.store.error("store.migration.legacy_voice_capture.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
                // .todoNotFound 的设计目的(VoiceTodoError 文档):让"条目不存在"可被精准
                // 断言与捕获(reextract 的 catch、replaceTodo 的 Throws 声明),不再藏在
                // storageReadFailed("todo not found: ...") 字符串里。UI 文案两者同走
                // ErrorMessages.storageError,用户可见行为不变。
                throw VoiceTodoError.todoNotFound(id)
            }
            return item
        } catch {
            VoiceTodoLog.store.error("store.find.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    /// 查重专用询问:返回已存在的 TodoItem 或 nil。
    /// 与 `findTodoItem` 区别:后者把 not_found 当错误抛,本方法把 not_found 当正常结果返回 nil。
    /// 真实的 SwiftData 读异常仍然向上抛——不被吞掉。
    ///
    /// 查重范围**仅限当前 ModelContext**:App Group 共享场景下,Widget extension 或
    /// 其它进程可能用自己的 ModelContext 写入相同 id 的记录,本方法看不到。
    /// 因此调用方不能假设"查重通过 = 全局无重复",只能假设"当前进程无重复"。
    ///
    /// - Parameter id: 待办 ID
    /// - Returns: 已存在的 TodoItem,nil 表示没找到(用于查重场景)
    private func existingTodoItem(by id: UUID) throws -> TodoItem? {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            VoiceTodoLog.store.error("store.existing_query.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.wrapStorage(error, for: .read)
        }
    }

    #if DEBUG
    /// 打印每条 todo 的 id 前缀 + title 截断(60 字符),排查"标题相同的两条 todo 是否 id 也相同"。
    /// 走 OSLog 而非 print:与同文件其它诊断一致 + 自动应用 privacy 规则。
    /// title 是用户语音内容,属敏感数据——截断避免长 transcript 刷屏。
    /// - Parameter items: 即将写入的待办数组
    private func logAddBatchDiag(items: [ExtractedTodo]) {
        let titleSummary = items.enumerated().map { idx, item -> String in
            let titleTrimmed = item.title.count > 60
                ? String(item.title.prefix(60)) + "…"
                : item.title
            return "[\(idx)] id=\(item.id.uuidString.prefix(8)) title=\"\(titleTrimmed)\""
        }.joined(separator: " | ")
        VoiceTodoLog.store.info("store.add_batch.diag_titles \(titleSummary, privacy: .public)")
    }
    #endif

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
