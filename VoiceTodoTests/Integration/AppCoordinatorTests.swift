import Combine
import XCTest
@testable import VoiceTodo

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testHandleAppForegroundKeepsPendingOrderWhenExtractionsFinishOutOfOrder() async {
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: UUID(), transcript: "first pending"),
            pendingTodo(id: UUID(), transcript: "second pending"),
            pendingTodo(id: UUID(), transcript: "third pending")
        ])
        let extractor = DelayedExtractor(delays: [
            "first pending": 150_000_000,
            "second pending": 50_000_000,
            "third pending": 10_000_000
        ])
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store
        )

        await coordinator.handleAppForeground()

        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertEqual(
            coordinator.extractedTodos.map(\.title),
            ["extracted first pending", "extracted second pending", "extracted third pending"]
        )
        XCTAssertEqual(
            coordinator.confirmSheetTranscript,
            "first pending\n---\nsecond pending\n---\nthird pending"
        )
    }

    func testHandleAppForegroundDoesNotConsumePendingWhenPresentationStateChangesBeforeDisplay() async {
        let pendingId = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: pendingId, transcript: "pending while sheet opens")
        ])
        let extractor = DelayedExtractor()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store
        )
        extractor.onExtract = {
            await MainActor.run {
                coordinator.showConfirmSheet = true
            }
        }

        await coordinator.handleAppForeground()

        XCTAssertEqual(store.pendingItems().map(\.id), [pendingId])
        XCTAssertTrue(store.deletedIds.isEmpty)
        XCTAssertTrue(coordinator.extractedTodos.isEmpty)
    }

    func testConfirmTodosWithAppOnlyModeDoesNotWriteSystemCalendar() {
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appOnly }
        )

        let success = coordinator.confirmTodos([
            ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "今天")
        ])

        XCTAssertTrue(success)
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵"])
        XCTAssertTrue(writer.receivedTodos.isEmpty)
    }

    func testConfirmTodosWithSystemCalendarModeWritesSavedTodos() async {
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter()
        let expectation = expectation(description: "system calendar write")
        writer.onWrite = { expectation.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let item = ExtractedTodo(title: "听写100个单词", detail: "未来 7 天每天听写 100 个单词", dueHint: "未来 7 天")
        let success = coordinator.confirmTodos([item])

        XCTAssertTrue(success)
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(writer.receivedTodos.map(\.id), [item.id])
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    func testConfirmTodosKeepsAppSaveWhenSystemCalendarWriteFails() async {
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter(error: VoiceTodoError.storageWriteFailed("calendar denied"))
        let expectation = expectation(description: "system calendar write failed")
        writer.onWrite = { expectation.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let success = coordinator.confirmTodos([
            ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "今天")
        ])

        XCTAssertTrue(success)
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵"])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.systemCalendarSyncFailed)
    }

    func testRapidConsecutiveConfirmsSerializeCalendarWrites() async {
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter()
        let allWritesDone = expectation(description: "both calendar writes complete")
        allWritesDone.expectedFulfillmentCount = 2
        writer.onWrite = { allWritesDone.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let item1 = ExtractedTodo(title: "任务一")
        let item2 = ExtractedTodo(title: "任务二")

        _ = coordinator.confirmTodos([item1])
        _ = coordinator.confirmTodos([item2])

        await fulfillment(of: [allWritesDone], timeout: 2)

        // 两次写入都被执行，且 eventIdentifier 都被持久化
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item1.id], "event-\(item1.id.uuidString)")
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item2.id], "event-\(item2.id.uuidString)")
    }

    func testDeleteTodoRemovesSystemCalendarEvent() async throws {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "今天")
        let savedTodo = TodoItemData(from: item)
        let store = CoordinatorTestStore(todos: [savedTodo])
        let writer = CoordinatorTestSystemCalendarWriter()
        // 模拟：先确认写入，得到 eventIdentifier
        store.systemCalendarEventIdentifiers[item.id] = "event-abc"
        store.todos[0].systemCalendarEventIdentifier = "event-abc"

        let removeDone = expectation(description: "calendar event removed")
        writer.onRemove = { removeDone.fulfill() }

        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        try coordinator.deleteTodo(item.id)

        XCTAssertTrue(store.todos.isEmpty)
        await fulfillment(of: [removeDone], timeout: 1)
        XCTAssertEqual(writer.removedIdentifiers, ["event-abc"])
    }

    func testDeleteTodoWithoutCalendarEventDoesNotCallRemove() async throws {
        let item = ExtractedTodo(title: "买牛奶")
        let store = CoordinatorTestStore(todos: [TodoItemData(from: item)])
        let writer = CoordinatorTestSystemCalendarWriter()

        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        try coordinator.deleteTodo(item.id)

        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertTrue(writer.removedIdentifiers.isEmpty)
    }

    func testUpdateTodoWithAppOnlyModeDoesNotTouchSystemCalendar() throws {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "明天")
        var savedTodo = TodoItemData(from: item)
        savedTodo.systemCalendarEventIdentifier = "event-old"
        let store = CoordinatorTestStore(todos: [savedTodo])
        let writer = CoordinatorTestSystemCalendarWriter()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appOnly }
        )

        try coordinator.updateTodo(
            item.id,
            title: "完成数学作业",
            dueHint: "后天",
            recurrenceRule: nil
        )

        XCTAssertEqual(store.todos[0].title, "完成数学作业")
        XCTAssertTrue(writer.receivedTodos.isEmpty)
        XCTAssertTrue(writer.removedIdentifiers.isEmpty)
        // identifier 未被清除（appOnly 模式不触发日历同步逻辑）
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-old")
    }

    func testUpdateTodoReplacesSystemCalendarEvent() async throws {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "明天")
        var savedTodo = TodoItemData(from: item)
        savedTodo.systemCalendarEventIdentifier = "event-old"
        let store = CoordinatorTestStore(todos: [savedTodo])
        let writer = CoordinatorTestSystemCalendarWriter()

        let removeDone = expectation(description: "old event removed")
        writer.onRemove = { removeDone.fulfill() }
        let writeDone = expectation(description: "new event written")
        writer.onWrite = { writeDone.fulfill() }

        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        try coordinator.updateTodo(
            item.id,
            title: "完成数学作业",
            dueHint: "后天",
            recurrenceRule: nil
        )

        XCTAssertEqual(store.todos[0].title, "完成数学作业")
        await fulfillment(of: [removeDone, writeDone], timeout: 1)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        XCTAssertEqual(writer.receivedTodos.count, 1)
        XCTAssertNil(writer.receivedTodos.first?.systemCalendarEventIdentifier)
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    private func pendingTodo(id: UUID, transcript: String) -> TodoItemData {
        TodoItemData(
            id: id,
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true
        )
    }
}

@MainActor
private final class CoordinatorTestVoiceInput: VoiceInputProtocol {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var error: VoiceTodoError?
    let currentLocale = Locale(identifier: "zh-Hans")

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }

    func startRecording() async throws {
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    func finishRecording() {
        isRecording = false
    }
}

private final class DelayedExtractor: TodoExtractorProtocol {
    var delays: [String: UInt64]
    var onExtract: (() async -> Void)?

    init(delays: [String: UInt64] = [:]) {
        self.delays = delays
    }

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        if let delay = delays[transcript] {
            try await Task.sleep(nanoseconds: delay)
        }
        await onExtract?()
        return ExtractionResult(
            todos: [ExtractedTodo(title: "extracted \(transcript)", detail: transcript)],
            ignored: ""
        )
    }
}

private final class CoordinatorTestStore: TodoStoreProtocol {
    @Published var todos: [TodoItemData]
    var deletedIds: [UUID] = []
    var systemCalendarEventIdentifiers: [UUID: String] = [:]

    init(todos: [TodoItemData] = []) {
        self.todos = todos
    }

    func add(_ item: ExtractedTodo) throws {
        todos.insert(TodoItemData(from: item), at: 0)
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        todos.insert(contentsOf: items.map { TodoItemData(from: $0) }, at: 0)
    }

    func addRawTranscript(_ transcript: String) throws {
        todos.insert(
            TodoItemData(
                title: transcript,
                detail: transcript,
                rawTranscript: transcript,
                needsAIProcessing: true
            ),
            at: 0
        )
    }

    func toggleComplete(_ id: UUID) throws {}

    func delete(_ id: UUID) throws {
        deletedIds.append(id)
        todos.removeAll { $0.id == id }
    }

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws {}

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {}

    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws {}

    func calendarOccurrences(from startDate: Date, to endDate: Date) -> [TodoOccurrenceData] { [] }

    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {}

    func pendingItems() -> [TodoItemData] {
        todos.filter(\.needsAIProcessing)
    }

    func recentUncompleted(limit: Int) -> [TodoItemData] {
        Array(todos.filter { !$0.isCompleted }.prefix(limit))
    }

    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws {
        try replacePendingBatchWithExtracted([pendingId], items, rawTranscript: rawTranscript)
    }

    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?) throws {
        let pendingSet = Set(pendingIds)
        todos.removeAll { pendingSet.contains($0.id) }
        todos.insert(contentsOf: items.map { TodoItemData(from: $0, rawTranscript: rawTranscript) }, at: 0)
    }

    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {
        systemCalendarEventIdentifiers[id] = eventIdentifier
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].systemCalendarEventIdentifier = eventIdentifier
        }
    }

    func reorder(ids: [UUID]) throws {}

    func refreshTodos() {}
}

private final class CoordinatorTestSystemCalendarWriter: SystemCalendarWritingProtocol {
    var receivedTodos: [TodoItemData] = []
    var removedIdentifiers: [String] = []
    var onWrite: (() -> Void)?
    var onRemove: (() -> Void)?
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult] {
        let writableTodos = todos.filter { $0.systemCalendarEventIdentifier == nil }
        receivedTodos = writableTodos
        onWrite?()
        if let error {
            throw error
        }
        return writableTodos.map {
            SystemCalendarWriteResult(todoId: $0.id, eventIdentifier: "event-\($0.id.uuidString)")
        }
    }

    func removeEvents(identifiers: [String]) async {
        removedIdentifiers.append(contentsOf: identifiers)
        onRemove?()
    }
}
