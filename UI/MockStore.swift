import Foundation
import Combine

/// Mock Store（Agent D 使用）
/// 用于 UI 开发和预览，不依赖 SwiftData
class MockStore: HomeTodoStore, AppCoordinatorTodoStore, PendingRecoveryTodoStore, PendingTranscriptCreating, CalendarSyncTodoStore, TodoMutationWriting, WidgetTodoReadable, TodoRefreshing {
    @Published var todos: [TodoItemData]
    private var completedOccurrences = Set<String>()

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

    func toggleComplete(_ id: UUID) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].isCompleted.toggle()
        }
    }

    func delete(_ id: UUID) throws {
        todos.removeAll { $0.id == id }
    }

    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].title = title
            if let category = category {
                todos[index].category = category
            }
            if let priority = priority {
                todos[index].priority = priority
            }
            if let dueHint = dueHint {
                let normalizedDueHint = dueHint.trimmingCharacters(in: .whitespacesAndNewlines)
                todos[index].dueHint = normalizedDueHint.isEmpty ? nil : normalizedDueHint
                todos[index].dueDate = TodoDueDateResolver.resolve(
                    dueHint: todos[index].dueHint,
                    title: todos[index].title,
                    detail: todos[index].detail ?? ""
                )
            }
        }
    }

    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil, recurrenceRule: RecurrenceRule?) throws {
        try update(id, title: title, category: category, priority: priority, dueHint: dueHint)
        try updateRecurrence(id, recurrenceRule: recurrenceRule)
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
        let today = Calendar.current.startOfDay(for: Date())
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
        let idSet = Set(ids)
        var reordered = [TodoItemData]()
        let lookup = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        for id in ids {
            if let item = lookup[id] {
                reordered.append(item)
            }
        }
        let rest = todos.filter { !idSet.contains($0.id) }
        todos = reordered + rest
    }

    func refreshTodos() {}
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
}

// MARK: - Mock Services (for Preview)

/// Mock 语音输入（Preview 用）
@MainActor
final class MockVoiceInput: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?
    let currentLocale: Locale = .current

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }

    func startRecording() async throws {}
    func stopRecording() {}
    func cancelRecordingDueToInterruption() {
        error = .audioSessionInterrupted
    }
    func finishRecording() { stopRecording() }
}

/// Mock 待办提取器（Preview 用）
struct MockExtractor: TodoExtractorProtocol {
    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        ExtractionResult(todos: [], ignored: "")
    }
}

/// Mock 语音历史 store（Preview / 测试用，不依赖 SwiftData）。
/// 与 `MockStore` 同样遵守协议但完全 in-memory，便于 RootTabView 在 SwiftUI Preview 中实例化。
@MainActor
final class MockVoiceCaptureHistoryStore: VoiceCaptureHistoryStoreProtocol {
    @Published var records: [VoiceCaptureRecordData] = []
    @Published var loadState: VoiceCaptureHistoryLoadState = .empty

    init(records: [VoiceCaptureRecordData] = []) {
        self.records = records.sorted { $0.createdAt > $1.createdAt }
        self.loadState = records.isEmpty ? .empty : .success
    }

    func refreshRecords() {
        loadState = records.isEmpty ? .empty : .success
    }

    @discardableResult
    func createRecord(
        transcript: String,
        source: VoiceCaptureSource,
        localeIdentifier: String,
        now: Date
    ) throws -> VoiceCaptureRecordData {
        let record = VoiceCaptureRecordData(
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            status: .processing,
            source: source,
            localeIdentifier: localeIdentifier
        )
        records.insert(record, at: 0)
        records.sort { $0.createdAt > $1.createdAt }
        loadState = .success
        return record
    }

    @discardableResult
    func updateRecord(
        id: UUID,
        status: VoiceCaptureStatus,
        generatedTodoIDs: [UUID]?,
        generatedTodoCount: Int?,
        pendingTodoLink: VoiceCapturePendingTodoLinkUpdate,
        errorMessage: String?
    ) throws -> VoiceCaptureRecordData {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.storageReadFailed("record not found")
        }
        records[index].status = status
        if let generatedTodoIDs {
            records[index].generatedTodoIDs = generatedTodoIDs
            records[index].generatedTodoCount = generatedTodoIDs.count
        } else {
            if status.resetsGeneratedArtifacts {
                records[index].generatedTodoIDs = []
            }
            if let generatedTodoCount {
                records[index].generatedTodoCount = generatedTodoCount
            } else if status.resetsGeneratedArtifacts {
                records[index].generatedTodoCount = 0
            }
        }
        switch pendingTodoLink {
        case .keepCurrent:
            break
        case .set(let pendingTodoID):
            records[index].pendingTodoID = pendingTodoID
        case .clear:
            records[index].pendingTodoID = nil
        }
        records[index].errorMessage = errorMessage
        return records[index]
    }

    func deleteRecord(id: UUID) throws {
        records.removeAll { $0.id == id }
        loadState = records.isEmpty ? .empty : .success
    }

    func cleanupExpiredRecords(now: Date) throws {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        records.removeAll { $0.createdAt < cutoff }
        loadState = records.isEmpty ? .empty : .success
    }

    func recordLinkedToPendingTodo(id: UUID) throws -> VoiceCaptureRecordData? {
        records.first { $0.pendingTodoID == id }
    }
}

// MARK: - MockVoiceCaptureHistoryStore Preview Helpers

extension MockVoiceCaptureHistoryStore {
    /// 包含示例历史记录，用于 RootTabView / VoiceHistoryView 的 Preview。
    static var preview: MockVoiceCaptureHistoryStore {
        let now = Date()
        return MockVoiceCaptureHistoryStore(records: [
            VoiceCaptureRecordData(
                transcript: "明天上午十点开会，记得带笔记本",
                createdAt: now.addingTimeInterval(-3600),
                status: .saved,
                source: .record_button,
                localeIdentifier: "zh-Hans-CN",
                generatedTodoCount: 1,
                generatedTodoIDs: [UUID()]
            ),
            VoiceCaptureRecordData(
                transcript: "买牛奶和鸡蛋",
                createdAt: now.addingTimeInterval(-86400),
                status: .reviewing,
                source: .actionButton,
                localeIdentifier: "zh-Hans-CN",
                generatedTodoCount: 2,
                generatedTodoIDs: [UUID(), UUID()]
            ),
            VoiceCaptureRecordData(
                transcript: "呃...",
                createdAt: now.addingTimeInterval(-172800),
                status: .noTodos,
                source: .record_button,
                localeIdentifier: "zh-Hans-CN"
            )
        ])
    }

    static var empty: MockVoiceCaptureHistoryStore {
        MockVoiceCaptureHistoryStore(records: [])
    }
}

/// 便捷方法：创建用于 Preview 的 Mock AppCoordinator
extension AppCoordinator {
    static var preview: AppCoordinator {
        AppCoordinator(
            voiceInput: MockVoiceInput(),
            extractor: MockExtractor(),
            store: MockStore.preview,
            historyStore: MockVoiceCaptureHistoryStore.preview
        )
    }
}
