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
        let identifierPersisted = expectation(description: "system calendar identifier persisted")
        store.onUpdateIdentifier = { identifierPersisted.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let item = ExtractedTodo(
            title: "听写100个单词",
            detail: "未来 7 天每天听写 100 个单词",
            dueHint: "未来 7 天",
            recurrenceRule: RecurrenceRule(frequency: .daily)
        )
        let success = coordinator.confirmTodos([item])

        XCTAssertTrue(success)
        await fulfillment(of: [identifierPersisted], timeout: 1)
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
        await Task.yield()
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵"])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.systemCalendarSyncFailed)
    }

    func testConfirmTodosPersistsPartialSystemCalendarResultsWhenWriteFails() async {
        let item1 = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "今天")
        let item2 = ExtractedTodo(title: "完成数学作业", detail: "明天完成数学作业", dueHint: "明天")
        let partialResult = SystemCalendarWriteResult(todoId: item1.id, eventIdentifier: "event-partial")
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter(
            error: SystemCalendarWriteError(
                results: [partialResult],
                underlyingError: VoiceTodoError.storageWriteFailed("calendar partial failure")
            )
        )
        let writeFailed = expectation(description: "system calendar partial write failed")
        writer.onWrite = { writeFailed.fulfill() }
        let identifierPersisted = expectation(description: "partial calendar identifier persisted")
        store.onUpdateIdentifier = { identifierPersisted.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let success = coordinator.confirmTodos([item1, item2])

        XCTAssertTrue(success)
        await fulfillment(of: [writeFailed, identifierPersisted], timeout: 1)
        await Task.yield()
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵", "完成数学作业"])
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item1.id], "event-partial")
        XCTAssertNil(store.systemCalendarEventIdentifiers[item2.id])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.systemCalendarSyncFailed)
    }

    func testConfirmTodosRemovesSystemCalendarEventWhenIdentifierPersistenceFails() async {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "今天")
        let store = CoordinatorTestStore()
        store.identifierUpdateError = VoiceTodoError.storageWriteFailed("identifier persistence failed")
        let writer = CoordinatorTestSystemCalendarWriter()
        let rollbackDone = expectation(description: "system calendar event rolled back")
        writer.onRemove = { rollbackDone.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let success = coordinator.confirmTodos([item])

        XCTAssertTrue(success)
        await fulfillment(of: [rollbackDone], timeout: 1)
        await Task.yield()
        XCTAssertEqual(writer.removedIdentifiers, ["event-\(item.id.uuidString)"])
        XCTAssertNil(store.systemCalendarEventIdentifiers[item.id])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.systemCalendarSyncFailed)
    }

    func testRapidConsecutiveConfirmsSerializeCalendarWrites() async {
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter()
        let allIdentifiersPersisted = expectation(description: "both calendar identifiers persist")
        allIdentifiersPersisted.expectedFulfillmentCount = 2
        store.onUpdateIdentifier = { allIdentifiersPersisted.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { .appAndSystemCalendar }
        )

        let item1 = ExtractedTodo(title: "任务一", detail: "今天", dueHint: "今天")
        let item2 = ExtractedTodo(title: "任务二", detail: "明天", dueHint: "明天")

        _ = coordinator.confirmTodos([item1])
        _ = coordinator.confirmTodos([item2])

        await fulfillment(of: [allIdentifiersPersisted], timeout: 2)

        // 两次写入都被执行，且 eventIdentifier 都被持久化
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item1.id], "event-\(item1.id.uuidString)")
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item2.id], "event-\(item2.id.uuidString)")
    }

    func testQueuedCalendarSyncUsesModeFromConfirmTime() async {
        var mode = CalendarWriteMode.appAndSystemCalendar
        let store = CoordinatorTestStore()
        let writer = CoordinatorTestSystemCalendarWriter()
        writer.writeDelayNanoseconds = 50_000_000
        let allIdentifiersPersisted = expectation(description: "both queued calendar identifiers persist")
        allIdentifiersPersisted.expectedFulfillmentCount = 2
        store.onUpdateIdentifier = { allIdentifiersPersisted.fulfill() }
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            systemCalendarWriter: writer,
            calendarWriteModeProvider: { mode }
        )

        let item1 = ExtractedTodo(title: "任务一", detail: "今天", dueHint: "今天")
        let item2 = ExtractedTodo(title: "任务二", detail: "明天", dueHint: "明天")

        _ = coordinator.confirmTodos([item1])
        _ = coordinator.confirmTodos([item2])
        mode = .appOnly

        await fulfillment(of: [allIdentifiersPersisted], timeout: 2)
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

    func testUpdateTodoWithAppOnlyModeRemovesStaleSystemCalendarEvent() async throws {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "明天")
        var savedTodo = TodoItemData(from: item)
        savedTodo.systemCalendarEventIdentifier = "event-old"
        let store = CoordinatorTestStore(todos: [savedTodo])
        let writer = CoordinatorTestSystemCalendarWriter()
        let removeDone = expectation(description: "stale event removed")
        writer.onRemove = { removeDone.fulfill() }
        let identifierCleared = expectation(description: "stale identifier cleared")
        store.onUpdateIdentifier = { identifierCleared.fulfill() }
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
        await fulfillment(of: [removeDone, identifierCleared], timeout: 1)
        XCTAssertTrue(writer.receivedTodos.isEmpty)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        // appOnly 模式不再创建新系统事件，但会清理旧镜像，避免系统日历留下过期内容
        XCTAssertNil(store.systemCalendarEventIdentifiers[item.id])
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
        let identifiersUpdated = expectation(description: "stale and new identifiers updated")
        identifiersUpdated.expectedFulfillmentCount = 2
        store.onUpdateIdentifier = { identifiersUpdated.fulfill() }

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
        await fulfillment(of: [removeDone, writeDone, identifiersUpdated], timeout: 1)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        XCTAssertEqual(writer.receivedTodos.count, 1)
        XCTAssertNil(writer.receivedTodos.first?.systemCalendarEventIdentifier)
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    func testUpdateTodoKeepsCalendarIdentifierWhenRemovingOldEventFails() async throws {
        let item = ExtractedTodo(title: "完成英语背诵", detail: "今天完成英语背诵", dueHint: "明天")
        var savedTodo = TodoItemData(from: item)
        savedTodo.systemCalendarEventIdentifier = "event-old"
        let store = CoordinatorTestStore(todos: [savedTodo])
        let writer = CoordinatorTestSystemCalendarWriter(removeError: VoiceTodoError.storageWriteFailed("remove failed"))
        let removeAttempted = expectation(description: "old event remove attempted")
        writer.onRemove = { removeAttempted.fulfill() }

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

        await fulfillment(of: [removeAttempted], timeout: 1)
        await Task.yield()
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-old")
        XCTAssertTrue(writer.receivedTodos.isEmpty)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.systemCalendarSyncFailed)
    }

    func testCancelRecordingDueToInterruptionStopsRecordingAndShowsToast() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.isRecording = true
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore()
        )

        coordinator.cancelRecordingDueToInterruption()
        await Task.yield()

        XCTAssertFalse(voiceInput.isRecording)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.audioSessionInterrupted)
    }

    func testStreamingFailureAfterPartialResultsClearsConfirmSheet() async {
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(
                todos: [ExtractedTodo(title: "部分结果", detail: "部分结果")],
                ignored: ""
            )
        ]
        extractor.streamingError = VoiceTodoError.apiResponseInvalid("broken stream")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: CoordinatorTestStore(),
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("记录一个会在流式结束时报错的待办")

        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.extractedTodos.isEmpty)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(
            coordinator.toastMessage,
            VoiceTodoError.apiResponseInvalid("broken stream").localizedDescription
        )
    }

    func testHandleAppForegroundKeepsInvalidPendingWhenDeleteFails() async {
        let pendingId = UUID()
        let invalidPending = TodoItemData(
            id: pendingId,
            title: "orphan pending",
            needsAIProcessing: true
        )
        let store = CoordinatorTestStore(todos: [invalidPending])
        store.deleteErrorIds.insert(pendingId)
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store
        )

        await coordinator.handleAppForeground()

        XCTAssertEqual(store.pendingItems().map(\.id), [pendingId])
        XCTAssertEqual(store.deletedIds, [pendingId])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)
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

    func cancelRecordingDueToInterruption() {
        isRecording = false
        error = .audioSessionInterrupted
    }

    func finishRecording() {
        isRecording = false
    }
}

private final class DelayedExtractor: TodoExtractorProtocol {
    var delays: [String: UInt64]
    var onExtract: (() async -> Void)?
    var streamingResults: [ExtractionResult]?
    var streamingError: Error?

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

    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error> {
        if streamingResults == nil && streamingError == nil {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let result = try await self.extract(from: transcript, locale: locale)
                        continuation.yield(result)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        let results = streamingResults ?? []
        let error = streamingError
        return AsyncThrowingStream { continuation in
            Task {
                for result in results {
                    continuation.yield(result)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

private final class CoordinatorTestStore: TodoStoreProtocol {
    @Published var todos: [TodoItemData]
    var deletedIds: [UUID] = []
    var deleteErrorIds: Set<UUID> = []
    var systemCalendarEventIdentifiers: [UUID: String] = [:]
    var onUpdateIdentifier: (() -> Void)?
    var identifierUpdateError: Error?

    init(todos: [TodoItemData] = []) {
        self.todos = todos
        self.systemCalendarEventIdentifiers = Dictionary(
            uniqueKeysWithValues: todos.compactMap { todo in
                todo.systemCalendarEventIdentifier.map { (todo.id, $0) }
            }
        )
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
        if deleteErrorIds.contains(id) {
            throw VoiceTodoError.storageWriteFailed("delete failed")
        }
        todos.removeAll { $0.id == id }
    }

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws {
        try updateFields(id, title: title, category: category, priority: priority, dueHint: dueHint)
    }

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {
        try updateFields(id, title: title, category: category, priority: priority, dueHint: dueHint)
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
        }
        todos[index].recurrenceRule = recurrenceRule?.isValid == true ? recurrenceRule : nil
    }

    private func updateFields(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
        }
        todos[index].title = title
        if let category {
            todos[index].category = category
        }
        if let priority {
            todos[index].priority = priority
        }
        if let dueHint {
            let normalizedDueHint = dueHint.trimmingCharacters(in: .whitespacesAndNewlines)
            todos[index].dueHint = normalizedDueHint.isEmpty ? nil : normalizedDueHint
            todos[index].dueDate = TodoDueDateResolver.resolve(
                dueHint: todos[index].dueHint,
                title: todos[index].title,
                detail: todos[index].detail ?? ""
            )
        }
    }

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
        if let identifierUpdateError {
            throw identifierUpdateError
        }
        systemCalendarEventIdentifiers[id] = eventIdentifier
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].systemCalendarEventIdentifier = eventIdentifier
        }
        onUpdateIdentifier?()
    }

    func reorder(ids: [UUID]) throws {}

    func refreshTodos() {}
}

private final class CoordinatorTestSystemCalendarWriter: SystemCalendarWritingProtocol {
    var receivedTodos: [TodoItemData] = []
    var removedIdentifiers: [String] = []
    var onWrite: (() -> Void)?
    var onRemove: (() -> Void)?
    var writeDelayNanoseconds: UInt64 = 0
    let error: Error?
    let removeError: Error?

    init(error: Error? = nil, removeError: Error? = nil) {
        self.error = error
        self.removeError = removeError
    }

    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult] {
        let writableTodos = todos.filter {
            $0.systemCalendarEventIdentifier == nil
                && SystemCalendarEventMapper.draft(from: $0) != nil
        }
        receivedTodos = writableTodos
        onWrite?()
        if writeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: writeDelayNanoseconds)
        }
        if let error {
            throw error
        }
        return writableTodos.map {
            SystemCalendarWriteResult(todoId: $0.id, eventIdentifier: "event-\($0.id.uuidString)")
        }
    }

    func removeEvents(identifiers: [String]) async throws {
        removedIdentifiers.append(contentsOf: identifiers)
        onRemove?()
        if let removeError {
            throw removeError
        }
    }
}
