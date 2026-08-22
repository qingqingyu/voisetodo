import Foundation
import Combine

/// Mock Store（Agent D 使用）
/// 用于 UI 开发和预览，不依赖 SwiftData
class MockStore: HomeTodoStore, AppCoordinatorTodoStore, PendingRecoveryTodoStore, PendingTranscriptCreating, CalendarSyncTodoStore, TodoMutationWriting, WidgetTodoReadable, TodoRefreshing {
    @Published var todos: [TodoItemData] {
        didSet { todosRevision &+= 1 }
    }
    @Published private(set) var todosRevision: Int = 0
    private var completedOccurrences = Set<String>()

    func findTodo(by id: UUID) -> TodoItemData? {
        todos.first { $0.id == id }
    }

    init(todos: [TodoItemData] = []) {
        self.todos = todos
    }

    // MARK: - Store Facade Implementations

    func add(_ item: ExtractedTodo) throws {
        var todo = TodoItemData(from: item)
        todo.localeIdentifier = Self.resolveLocaleIdentifier(item.localeIdentifier, fallback: Locale.current.identifier)
        todos.insert(todo, at: 0)
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        try addBatch(items, localeIdentifier: nil)
    }

    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws {
        let fallbackLocaleIdentifier = Self.resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        let newTodos = items.map { item in
            var todo = TodoItemData(from: item)
            todo.localeIdentifier = Self.resolveLocaleIdentifier(localeIdentifier ?? item.localeIdentifier, fallback: fallbackLocaleIdentifier)
            return todo
        }
        todos.insert(
            contentsOf: newTodos.reversed(),
            at: 0
        )
    }

    func addImportedBatch(_ items: [TodoItemData]) throws {
        todos.insert(contentsOf: items.reversed(), at: 0)
    }

    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        let title = TextUtils.truncateTitle(from: transcript)
        let effectiveLocaleIdentifier = Self.resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        let todo = TodoItemData(
            title: title,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: effectiveLocaleIdentifier
        )
        todos.insert(todo, at: 0)
        return todo
    }

    func addManualUnparsedTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        let title = TextUtils.truncateTitle(from: transcript)
        let effectiveLocaleIdentifier = Self.resolveLocaleIdentifier(localeIdentifier, fallback: Locale.current.identifier)
        var todo = TodoItemData(
            title: title,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: false,
            localeIdentifier: effectiveLocaleIdentifier
        )
        todo.extractionOutcome = .unparsed
        todos.insert(todo, at: 0)
        return todo
    }

    func holdPendingAsUnparsed(id: UUID) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        todos[index].needsAIProcessing = false
        todos[index].extractionOutcome = .unparsed
    }

    func toggleComplete(_ id: UUID) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].isCompleted.toggle()
        }
    }

    /// Mock 版划掉:只写内存字段(无事件表)。与 `TodoStore.abandon` 行为对齐用于 preview。
    func abandon(_ id: UUID) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        todos[index].abandonedAt = Date()
    }

    /// Mock 版撤销划掉:只清内存字段,不记事件(与 `TodoStore.unabandon` 口径一致)。
    func unabandon(_ id: UUID) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        todos[index].abandonedAt = nil
    }

    func delete(_ id: UUID) throws {
        todos.removeAll { $0.id == id }
    }

    func updateFull(_ id: UUID, update: TodoDetailUpdate, origin: TaskEventOrigin) throws {
        // Mock 无持久层,不落 TaskEvent;origin 仅用于满足协议签名。
        _ = origin
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }

        let hadRecurrence = todos[index].recurrenceRule != nil
        todos[index].title = update.title
        todos[index].detail = update.detail
        if let category = update.category { todos[index].category = category }
        if let priority = update.priority { todos[index].priority = priority }
        todos[index].dueDate = update.dueDate
        todos[index].hasDueTime = update.hasDueTime
        todos[index].timeBucket = update.timeBucket
        if let dueHint = update.dueHint {
            let normalizedDueHint = dueHint.trimmingCharacters(in: .whitespacesAndNewlines)
            todos[index].dueHint = normalizedDueHint.isEmpty ? nil : normalizedDueHint
        }
        todos[index].recurrenceRule = update.recurrenceRule
        if hadRecurrence, todos[index].recurrenceRule == nil {
            completedOccurrences = completedOccurrences.filter { !$0.hasPrefix(id.uuidString) }
        } else if todos[index].recurrenceRule != nil {
            todos[index].isCompleted = false
            todos[index].completedAt = nil
        }
    }

    /// Mock 版 replaceTodo:简单 in-place mutate + append,匹配 TodoStore 行为用于测试与 preview。
    func replaceTodo(id: UUID, with extracted: [ExtractedTodo], rawTranscript: String?) throws {
        guard !extracted.isEmpty else {
            throw VoiceTodoError.apiResponseInvalid("replaceTodo with empty extracted")
        }
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        let preservedSort = todos[index].sortOrder
        let preservedCreatedAt = todos[index].createdAt
        let preservedLocale = todos[index].localeIdentifier
        let first = TodoItemData(from: extracted[0], rawTranscript: rawTranscript)
        let replaced = TodoItemData(
            id: id,  // 保留原 id,避免 widget / occurrence 关联断
            title: first.title,
            detail: first.detail,
            dueHint: first.dueHint,
            dueDate: first.dueDate,
            hasDueTime: first.hasDueTime,
            timeBucket: first.timeBucket,
            recurrenceRule: first.recurrenceRule,
            priority: first.priority,
            category: first.category,
            reminderTimes: first.reminderTimes,
            isCompleted: false,
            completedAt: nil,
            createdAt: preservedCreatedAt,
            rawTranscript: rawTranscript,
            needsAIProcessing: false,
            sortOrder: preservedSort,
            systemCalendarEventIdentifier: nil,
            localeIdentifier: preservedLocale ?? first.localeIdentifier,
            extractionOutcome: .parsed
        )
        todos[index] = replaced
        if extracted.count > 1 {
            // 锚定 sortOrder 在 preservedSort 之下,匹配 TodoStore 行为。
            var nextSort = preservedSort - 1
            for extra in extracted.dropFirst() {
                var item = TodoItemData(from: extra, rawTranscript: nil)
                item.sortOrder = nextSort
                item.localeIdentifier = preservedLocale ?? item.localeIdentifier
                nextSort -= 1
                todos.append(item)
            }
        }
    }

    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].recurrenceRule = recurrenceRule
            if recurrenceRule == nil {
                completedOccurrences = completedOccurrences.filter { !$0.hasPrefix(id.uuidString) }
            } else {
                todos[index].isCompleted = false
            }
        }
    }

    func completedUnscheduled(from startDate: Date, to endDate: Date) async throws -> [TodoItemData] {
        todos
            .filter { $0.isCompleted && $0.dueDate == nil && $0.recurrenceRule == nil }
            .filter {
                guard let completedAt = $0.completedAt else { return false }
                return completedAt >= startDate && completedAt < endDate
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func calendarOccurrences(from startDate: Date, to endDate: Date) async throws -> [TodoOccurrenceData] {
        let calendar = Calendar.current
        var days: [Date] = []
        var current = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        while current <= end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? end.addingTimeInterval(1)
        }

        return todos.flatMap { todo -> [TodoOccurrenceData] in
            if let rule = todo.recurrenceRule {
                return days.compactMap { day in
                    guard rule.occurs(on: day, startDate: todo.dueDate ?? todo.createdAt, calendar: calendar) else {
                        return nil
                    }
                    let key = TodoOccurrenceCompletion.key(todoId: todo.id, occurrenceDate: day, calendar: calendar)
                    var occurrenceTodo = todo
                    occurrenceTodo.isCompleted = completedOccurrences.contains(key)
                    return TodoOccurrenceData(todo: occurrenceTodo, occurrenceDate: day, isCompleted: completedOccurrences.contains(key))
                }
            }
            guard let dueDate = todo.dueDate,
                  days.contains(where: { calendar.isDate($0, inSameDayAs: dueDate) }) else {
                return []
            }
            return [TodoOccurrenceData(todo: todo, occurrenceDate: calendar.startOfDay(for: dueDate), isCompleted: todo.isCompleted)]
        }
        .sorted { lhs, rhs in
            if lhs.occurrenceDate != rhs.occurrenceDate {
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
            return lhs.todo.sortOrder < rhs.todo.sortOrder
        }
    }

    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {
        guard let todo = todos.first(where: { $0.id == id }), let recurrenceRule = todo.recurrenceRule else {
            try toggleComplete(id)
            return
        }
        let day = Calendar.current.startOfDay(for: date)
        guard recurrenceRule.occurs(on: day, startDate: todo.dueDate ?? todo.createdAt) else {
            return
        }

        let key = TodoOccurrenceCompletion.key(todoId: id, occurrenceDate: day)
        if completedOccurrences.contains(key) {
            completedOccurrences.remove(key)
        } else {
            completedOccurrences.insert(key)
        }
    }

    func pendingItems() async throws -> [TodoItemData] {
        return todos.filter { $0.needsAIProcessing }
    }

    func recentUncompleted(limit: Int) async throws -> [TodoItemData] {
        let today = DayClock.startOfUserDay(for: Date())
        return WidgetTodoFilter.visibleTodos(
            from: todos,
            completionKeys: completedOccurrences,
            today: today,
            limit: limit
        )
    }

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
        let pendingSet = Set(pendingIds)
        let fallbackLocaleIdentifier = Self.resolveLocaleIdentifier(
            localeIdentifier
                ?? todos.first(where: { pendingSet.contains($0.id) && ($0.localeIdentifier ?? "").isEmpty == false })?.localeIdentifier,
            fallback: Locale.current.identifier
        )
        todos.removeAll { pendingSet.contains($0.id) }

        let newTodos = items.map { item in
            var todo = TodoItemData(from: item, rawTranscript: rawTranscript)
            todo.localeIdentifier = Self.resolveLocaleIdentifier(localeIdentifier ?? item.localeIdentifier, fallback: fallbackLocaleIdentifier)
            return todo
        }
        todos.insert(contentsOf: newTodos.reversed(), at: 0)
    }

    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].systemCalendarEventIdentifier = eventIdentifier
    }

    func reorder(ids: [UUID]) throws {
        // 与 TodoStore.reorder 行为对齐：局部重排 sortOrder，不动其他 todo。
        let idSet = Set(ids)
        let subset = todos.filter { idSet.contains($0.id) }
        guard subset.count == ids.count else {
            // 与 TodoStore.reorder 同口径:条目缺失抛 .todoNotFound。
            let missingId = ids.first { id in !subset.contains(where: { $0.id == id }) } ?? ids[0]
            throw VoiceTodoError.todoNotFound(missingId)
        }
        let base = subset.map(\.sortOrder).min() ?? 0
        for (index, id) in ids.enumerated() {
            if let i = todos.firstIndex(where: { $0.id == id }) {
                todos[i].sortOrder = base + index
            }
        }
        todos.sort { $0.sortOrder < $1.sortOrder }
    }

    func refreshTodos() {}

    /// 数据体检(阶段 0):Mock 无持久层,直接回内存数据。失败路径不会出现。
    func diagnosticsAllItems() throws -> [TodoItemData] {
        todos
    }
}

private extension MockStore {
    /// 解析有效的 locale identifier：空串视为无效，回退到 fallback。
    /// 与 TodoStore.resolveLocaleIdentifier 行为一致，防御旧数据写入 "" 而非 nil。
    static func resolveLocaleIdentifier(_ identifier: String?, fallback: String) -> String {
        if let identifier, !identifier.isEmpty {
            return identifier
        }
        return fallback
    }
}

// MARK: - Preview Helpers

extension MockStore {
    /// 包含示例数据的 Mock Store
    static var preview: MockStore {
        MockStore(todos: [
            TodoItemData(title: "完成周报", detail: "需要整理本周的工作内容", dueHint: "今天", priority: .normal, category: .work),
            TodoItemData(title: "准备面试", detail: "复习算法和系统设计", dueHint: "周三前", priority: .high, category: .work),
            TodoItemData(title: "去健身房", detail: nil, dueHint: nil, priority: .normal, category: .health, isCompleted: false),
            TodoItemData(title: "买菜", detail: "西红柿、鸡蛋、牛奶", dueHint: "今晚", priority: .normal, category: .life, isCompleted: true),
            TodoItemData(title: "给老妈打电话", detail: nil, dueHint: "周末", priority: .normal, category: .social, isCompleted: false),
            TodoItemData(title: "学习 SwiftUI", detail: "Widget 和 Live Activity", dueHint: nil, priority: .normal, category: .study, isCompleted: false),
            TodoItemData(title: "还信用卡", detail: "本月账单", dueHint: "月底前", priority: .high, category: .finance, isCompleted: false)
        ])
    }

    /// 空数据的 Mock Store
    static var empty: MockStore {
        MockStore(todos: [])
    }

    /// 包含待处理项的 Mock Store
    static var withPendingItems: MockStore {
        MockStore(todos: [
            TodoItemData(
                title: "原始转写文本...",
                detail: "这是一段完整的语音转写文本，等待 AI 提取",
                rawTranscript: "这是一段完整的语音转写文本，等待 AI 提取",
                needsAIProcessing: true
            ),
            TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
        ])
    }

    /// 包含长 hint fixture 的 Mock Store —— 用于跑马灯 / 卡片溢出场景的 Preview 与 UI 测试。
    /// AI 原文逐字保留是 prompt 契约(AIProxy/src/adapters/base.js:125 / :245),
    /// 长度无界,few-shot 里就有 30-43 字符的例子。原来 MockStore 全用短中文 hint
    /// ("今天"、"周三前")掩盖了长文本溢出 bug,这里补中英文长 hint 各一。
    static var withLongHints: MockStore {
        MockStore(todos: [
            TodoItemData(
                title: "Finish filing taxes",
                detail: nil,
                dueHint: "by the end of this month",
                priority: .high,
                category: .finance
            ),
            TodoItemData(
                title: "缴物业管理费",
                detail: nil,
                dueHint: "每个月15号下午3点",
                priority: .normal,
                category: .finance
            ),
            TodoItemData(
                title: "Schedule dentist",
                detail: nil,
                dueHint: "around the middle of the month",
                priority: .normal,
                category: .health
            )
        ])
    }
}

// MARK: - Mock Services (for Preview)

/// Mock 语音输入（Preview 用）
@MainActor
final class MockVoiceInput: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?
    @Published var didAutoFinishDueToSilence: Bool = false
    @Published var audioLevel: Float = 0
    let currentLocale: Locale = .current

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }
    var didAutoFinishDueToSilencePublisher: AnyPublisher<Bool, Never> { $didAutoFinishDueToSilence.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { $audioLevel.eraseToAnyPublisher() }
    var recordingSuccessPublisher: AnyPublisher<Void, Never> { Empty<Void, Never>().eraseToAnyPublisher() }

    func startRecording() async throws {}
    func stopRecording() {}
    func cancelRecordingDueToInterruption() {
        error = .audioSessionInterrupted
    }
    func cancelRecordingByUser() {
        // Mock 路径：与生产路径行为对齐（清掉录音态），便于 Preview 演示关闭面板。
        isRecording = false
    }
    func finishRecording() { stopRecording() }
}

/// Mock 待办提取器（Preview 用）
struct MockExtractor: TodoExtractorProtocol {
    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        ExtractionResult(todos: [], ignored: "")
    }
}

/// 便捷方法：创建用于 Preview 的 Mock AppCoordinator
extension AppCoordinator {
    static var preview: AppCoordinator {
        AppCoordinator(
            voiceInput: MockVoiceInput(),
            extractor: MockExtractor(),
            store: MockStore.preview
        )
    }
}
