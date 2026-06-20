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

    func testManualInputKeepsPartialTodosWhenLaterPartialIsEmpty() async {
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(
                todos: [ExtractedTodo(title: "先识别到的待办", detail: "先识别到的待办")],
                ignored: ""
            ),
            ExtractionResult(todos: [], ignored: "empty final")
        ]
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: CoordinatorTestStore(),
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("先识别到待办，最后一个 partial 为空")

        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertEqual(coordinator.extractedTodos.map(\.title), ["先识别到的待办"])
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

    func testHandleAppForegroundClearsHistoryLinkWhenInvalidPendingDeleted() async {
        let pendingId = UUID()
        let invalidPending = TodoItemData(
            id: pendingId,
            title: "orphan pending",
            needsAIProcessing: true
        )
        let store = CoordinatorTestStore(todos: [invalidPending])
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "orphan pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        _ = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingId),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore
        )

        await coordinator.handleAppForeground()

        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertEqual(historyStore.records.first?.status, .failed)
        XCTAssertNil(historyStore.records.first?.pendingTodoID)
        do {
            XCTAssertNil(try historyStore.recordLinkedToPendingTodo(id: pendingId))
        } catch {
            XCTFail("Expected no linked history record, got error: \(error)")
        }
    }

    func testHandleAppForegroundSurfacesPendingExtractionFailure() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: pendingID, transcript: "恢复时失败")
        ])
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "恢复时失败",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        _ = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let extractor = DelayedExtractor()
        extractor.extractionErrors["恢复时失败"] = VoiceTodoError.apiResponseInvalid("broken pending")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.handleAppForeground()

        XCTAssertEqual(store.pendingItems().map(\.id), [pendingID])
        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, VoiceTodoError.apiResponseInvalid("broken pending").localizedDescription)
        XCTAssertEqual(historyStore.records.first?.status, .failed)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)
        assertHistoryRecord(historyStore, pendingID: pendingID, isLinkedTo: record.id)
    }

    func testVoiceCaptureHistorySavedAfterConfirm() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "明天提醒我买牛奶"
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.stopRecordingAndProcess()
        XCTAssertEqual(historyStore.records.first?.status, .reviewing)

        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        XCTAssertEqual(historyStore.records.first?.status, .saved)
        XCTAssertEqual(historyStore.records.first?.generatedTodoCount, 1)
        XCTAssertEqual(historyStore.records.first?.generatedTodoIDs, coordinator.extractedTodos.map(\.id))
    }

    func testVoiceCaptureHistoryUpdateFailureShowsWarning() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "明天提醒我买牛奶"
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )
        historyStore.updateError = VoiceTodoError.storageWriteFailed("history unavailable")

        await coordinator.stopRecordingAndProcess()

        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.historyUpdateFailed)
    }

    func testVoiceCaptureHistoryNoTodosStatus() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "只是随便说一句"
        let extractor = DelayedExtractor()
        extractor.streamingResults = [ExtractionResult(todos: [], ignored: "nothing")]
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: extractor,
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.stopRecordingAndProcess()

        XCTAssertEqual(historyStore.records.first?.status, .noTodos)
    }

    func testVoiceCaptureHistorySkipsEmptyVoiceTranscript() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "   "
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.stopRecordingAndProcess()

        XCTAssertTrue(historyStore.records.isEmpty)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.noTodosFound)
    }

    func testCleanupExpiredVoiceHistoryFailureShowsWarningByDefault() {
        let historyStore = CoordinatorTestHistoryStore()
        historyStore.cleanupError = VoiceTodoError.storageWriteFailed("cleanup failed")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore(),
            historyStore: historyStore
        )

        coordinator.cleanupExpiredVoiceHistory()

        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.historyCleanupFailed)
    }

    func testVoiceCaptureHistoryCancelledWhenConfirmCancelled() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "明天提醒我买牛奶"
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.stopRecordingAndProcess()
        coordinator.cancelTodos()

        XCTAssertEqual(historyStore.records.first?.status, .cancelled)
    }

    func testVoiceCaptureHistoryPendingWhenOffline() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "离线时保存这句话"
        let store = CoordinatorTestStore()
        let historyStore = CoordinatorTestHistoryStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { false }
        )

        await coordinator.stopRecordingAndProcess()

        XCTAssertEqual(historyStore.records.first?.status, .pending)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, store.todos.first?.id)
    }

    func testReprocessHistoryFailureMarksFailedAndShowsToast() async {
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "重新提取会失败",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let extractor = DelayedExtractor()
        extractor.streamingError = VoiceTodoError.apiResponseInvalid("broken")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: CoordinatorTestStore(),
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(record)

        XCTAssertEqual(historyStore.records.first?.status, .failed)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, VoiceTodoError.apiResponseInvalid("broken").localizedDescription)
    }

    func testReprocessHistoryNoTodosKeepsPendingDeleteErrorToast() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [pendingTodo(id: pendingID, transcript: "旧 pending")])
        store.deleteErrorIds.insert(pendingID)
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "这次没有待办",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let linkedRecord = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let extractor = DelayedExtractor()
        extractor.streamingResults = [ExtractionResult(todos: [], ignored: "nothing")]
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(linkedRecord)

        XCTAssertEqual(store.pendingItems().map(\.id), [pendingID])
        XCTAssertEqual(historyStore.records.first?.status, .failed)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)
        assertHistoryRecord(historyStore, pendingID: pendingID, isLinkedTo: record.id)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)
    }

    func testReprocessHistoryConfirmFailsAtomicallyWhenPendingReplacementFails() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [pendingTodo(id: pendingID, transcript: "旧 pending")])
        store.replaceError = VoiceTodoError.storageWriteFailed("replace failed")
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "重新提取这条 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let linkedRecord = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(linkedRecord)
        let success = coordinator.confirmTodos(coordinator.extractedTodos)

        XCTAssertFalse(success)
        XCTAssertEqual(store.todos.map(\.id), [pendingID])
        XCTAssertEqual(historyStore.records.first?.status, .failed)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)
        assertHistoryRecord(historyStore, pendingID: pendingID, isLinkedTo: record.id)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)
    }

    func testReprocessHistoryRetryAfterReplacementFailureReplacesOriginalPending() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [pendingTodo(id: pendingID, transcript: "旧 pending")])
        store.replaceError = VoiceTodoError.storageWriteFailed("replace failed")
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "重新提取这条 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let linkedRecord = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(linkedRecord)
        XCTAssertFalse(coordinator.confirmTodos(coordinator.extractedTodos))
        coordinator.cancelTodos()

        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)

        store.replaceError = nil
        let retryRecord = historyStore.records[0]
        await coordinator.reprocessHistoryRecord(retryRecord)
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        XCTAssertFalse(store.todos.contains { $0.id == pendingID })
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(historyStore.records.first?.status, .saved)
        XCTAssertNil(historyStore.records.first?.pendingTodoID)
    }

    func testForegroundPendingCancelKeepsHistoryLinkedToPending() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [pendingTodo(id: pendingID, transcript: "前台恢复 pending")])
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "前台恢复 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        _ = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.handleAppForeground()
        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertEqual(historyStore.records.first?.status, .reviewing)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)

        coordinator.cancelTodos()

        XCTAssertEqual(historyStore.records.first?.status, .cancelled)
        XCTAssertEqual(historyStore.records.first?.pendingTodoID, pendingID)
        assertHistoryRecord(historyStore, pendingID: pendingID, isLinkedTo: record.id)
    }

    func testForegroundPendingConfirmWritesPerPendingGeneratedHistory() async {
        let firstPendingID = UUID()
        let secondPendingID = UUID()
        let firstTodoID = UUID()
        let secondTodoID = UUID()
        let thirdTodoID = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: firstPendingID, transcript: "第一段 pending"),
            pendingTodo(id: secondPendingID, transcript: "第二段 pending")
        ])
        let historyStore = CoordinatorTestHistoryStore()
        let firstRecord = try! historyStore.createRecord(
            transcript: "第一段 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let secondRecord = try! historyStore.createRecord(
            transcript: "第二段 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        _ = try! historyStore.updateRecord(
            id: firstRecord.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(firstPendingID),
            errorMessage: nil
        )
        _ = try! historyStore.updateRecord(
            id: secondRecord.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(secondPendingID),
            errorMessage: nil
        )
        let extractor = DelayedExtractor()
        extractor.extractionResults["第一段 pending"] = ExtractionResult(
            todos: [
                ExtractedTodo(id: firstTodoID, title: "第一段任务一"),
                ExtractedTodo(id: secondTodoID, title: "第一段任务二")
            ],
            ignored: ""
        )
        extractor.extractionResults["第二段 pending"] = ExtractionResult(
            todos: [
                ExtractedTodo(id: thirdTodoID, title: "第二段任务")
            ],
            ignored: ""
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.handleAppForeground()
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        let updatedFirst = historyStore.records.first { $0.id == firstRecord.id }
        let updatedSecond = historyStore.records.first { $0.id == secondRecord.id }
        XCTAssertEqual(updatedFirst?.status, .saved)
        XCTAssertEqual(updatedFirst?.generatedTodoIDs, [firstTodoID, secondTodoID])
        XCTAssertEqual(updatedFirst?.generatedTodoCount, 2)
        XCTAssertNil(updatedFirst?.pendingTodoID)
        XCTAssertEqual(updatedSecond?.status, .saved)
        XCTAssertEqual(updatedSecond?.generatedTodoIDs, [thirdTodoID])
        XCTAssertEqual(updatedSecond?.generatedTodoCount, 1)
        XCTAssertNil(updatedSecond?.pendingTodoID)
    }

    func testForegroundPendingConfirmPreservesEachPendingLocaleOnSavedTodos() async {
        let englishPendingID = UUID()
        let chinesePendingID = UUID()
        let englishTodoID = UUID()
        let chineseTodoID = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: englishPendingID, transcript: "english pending", localeIdentifier: "en-US"),
            pendingTodo(id: chinesePendingID, transcript: "中文 pending", localeIdentifier: "zh-Hans")
        ])
        let extractor = DelayedExtractor()
        extractor.extractionResults["english pending"] = ExtractionResult(
            todos: [ExtractedTodo(id: englishTodoID, title: "Review English notes")],
            ignored: ""
        )
        extractor.extractionResults["中文 pending"] = ExtractionResult(
            todos: [ExtractedTodo(id: chineseTodoID, title: "整理中文笔记")],
            ignored: ""
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        await coordinator.handleAppForeground()
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        let savedLocales = Dictionary(uniqueKeysWithValues: store.todos.map { ($0.id, $0.localeIdentifier) })
        XCTAssertEqual(savedLocales[englishTodoID] ?? nil, "en-US")
        XCTAssertEqual(savedLocales[chineseTodoID] ?? nil, "zh-Hans")
    }

    func testForegroundPendingConfirmLearnsVocabularyByEachPendingLocale() async {
        let englishPendingID = UUID()
        let chinesePendingID = UUID()
        let vocabularyStore = makeVocabularyStore()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: englishPendingID, transcript: "english pending", localeIdentifier: "en-US"),
            pendingTodo(id: chinesePendingID, transcript: "中文 pending", localeIdentifier: "zh-Hans")
        ])
        let extractor = DelayedExtractor()
        extractor.extractionResults["english pending"] = ExtractionResult(
            todos: [ExtractedTodo(title: "Review Anki notes", detail: "Review Anki notes")],
            ignored: ""
        )
        extractor.extractionResults["中文 pending"] = ExtractionResult(
            todos: [ExtractedTodo(title: "复习 雅思 口语", detail: "复习 雅思 口语")],
            ignored: ""
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true },
            vocabularyStore: vocabularyStore
        )

        await coordinator.handleAppForeground()
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))
        await waitForVocabulary(
            store: vocabularyStore,
            englishHint: "Anki",
            chineseHint: "雅思"
        )

        XCTAssertTrue(vocabularyStore.vocabularyHints(localeIdentifier: "en-US", limit: 10).contains("Anki"))
        XCTAssertTrue(vocabularyStore.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10).contains("雅思"))
    }

    func testReprocessHistorySuccessDeletesLinkedPendingTodo() async {
        let pendingID = UUID()
        let store = CoordinatorTestStore(todos: [pendingTodo(id: pendingID, transcript: "旧 pending")])
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "重新提取这条 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let linkedRecord = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(pendingID),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(linkedRecord)
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        XCTAssertFalse(store.todos.contains { $0.id == pendingID })
        XCTAssertEqual(historyStore.records.first?.status, .saved)
        XCTAssertNil(historyStore.records.first?.pendingTodoID)
        XCTAssertNil(try? historyStore.recordLinkedToPendingTodo(id: pendingID))
    }

    func testReprocessHistoryIgnoresLinkedTodoThatIsNoLongerPending() async {
        let stalePendingID = UUID()
        let existingSavedTodo = TodoItemData(
            id: stalePendingID,
            title: "已经保存的旧任务",
            needsAIProcessing: false
        )
        let store = CoordinatorTestStore(todos: [existingSavedTodo])
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "重新提取但旧链接已不是 pending",
            source: .recordButton,
            localeIdentifier: "zh-Hans",
            now: Date()
        )
        let linkedRecord = try! historyStore.updateRecord(
            id: record.id,
            status: .pending,
            generatedTodoIDs: [],
            generatedTodoCount: 0,
            pendingTodoLink: .set(stalePendingID),
            errorMessage: nil
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(linkedRecord)
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        XCTAssertTrue(store.todos.contains { $0.id == stalePendingID })
        XCTAssertEqual(store.todos.count, 2)
        XCTAssertEqual(historyStore.records.first?.status, .saved)
        XCTAssertNil(historyStore.records.first?.pendingTodoID)
    }

    func testReprocessHistoryConfirmPreservesHistoryLocaleOnSavedTodo() async {
        let store = CoordinatorTestStore()
        let historyStore = CoordinatorTestHistoryStore()
        let record = try! historyStore.createRecord(
            transcript: "review English notes tomorrow",
            source: .recordButton,
            localeIdentifier: "en-US",
            now: Date()
        )
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            historyStore: historyStore,
            networkIsConnectedProvider: { true }
        )

        await coordinator.reprocessHistoryRecord(record)
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        XCTAssertEqual(store.todos.first?.localeIdentifier, "en-US")
    }

    private func pendingTodo(id: UUID, transcript: String, localeIdentifier: String? = nil) -> TodoItemData {
        TodoItemData(
            id: id,
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: localeIdentifier
        )
    }

    private func makeVocabularyStore() -> UserVocabularyStore {
        let suiteName = "VoiceTodoTests.AppCoordinator.Vocabulary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return UserVocabularyStore(defaults: defaults)
    }

    private func waitForVocabulary(
        store: UserVocabularyStore,
        englishHint: String,
        chineseHint: String
    ) async {
        for _ in 0..<10 {
            let englishHints = store.vocabularyHints(localeIdentifier: "en-US", limit: 10)
            let chineseHints = store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10)
            if englishHints.contains(englishHint), chineseHints.contains(chineseHint) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertHistoryRecord(
        _ historyStore: CoordinatorTestHistoryStore,
        pendingID: UUID,
        isLinkedTo recordID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let record = try historyStore.recordLinkedToPendingTodo(id: pendingID)
            XCTAssertEqual(record?.id, recordID, file: file, line: line)
        } catch {
            XCTFail("Expected linked history record, got error: \(error)", file: file, line: line)
        }
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
    var extractionResults: [String: ExtractionResult] = [:]
    var extractionErrors: [String: Error] = [:]
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
        if let error = extractionErrors[transcript] {
            throw error
        }
        if let result = extractionResults[transcript] {
            return result
        }
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

private final class CoordinatorTestStore: AppCoordinatorTodoStore, PendingRecoveryTodoStore, PendingTranscriptCreating, CalendarSyncTodoStore {
    @Published var todos: [TodoItemData]
    var deletedIds: [UUID] = []
    var deleteErrorIds: Set<UUID> = []
    var systemCalendarEventIdentifiers: [UUID: String] = [:]
    var onUpdateIdentifier: (() -> Void)?
    var identifierUpdateError: Error?
    var replaceError: Error?

    init(todos: [TodoItemData] = []) {
        self.todos = todos
        self.systemCalendarEventIdentifiers = Dictionary(
            uniqueKeysWithValues: todos.compactMap { todo in
                todo.systemCalendarEventIdentifier.map { (todo.id, $0) }
            }
        )
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        try addBatch(items, localeIdentifier: nil)
    }

    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws {
        let fallbackLocaleIdentifier = localeIdentifier ?? Locale.current.identifier
        todos.insert(
            contentsOf: items.map { item in
                var todo = TodoItemData(from: item)
                todo.localeIdentifier = localeIdentifier ?? item.localeIdentifier ?? fallbackLocaleIdentifier
                return todo
            },
            at: 0
        )
    }

    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        let todo = TodoItemData(
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: localeIdentifier
        )
        todos.insert(todo, at: 0)
        return todo
    }

    func delete(_ id: UUID) throws {
        deletedIds.append(id)
        if deleteErrorIds.contains(id) {
            throw VoiceTodoError.storageWriteFailed("delete failed")
        }
        todos.removeAll { $0.id == id }
    }

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {
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
        todos[index].recurrenceRule = recurrenceRule?.isValid == true ? recurrenceRule : nil
    }

    func pendingItems() -> [TodoItemData] {
        todos.filter(\.needsAIProcessing)
    }

    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws {
        try replacePendingBatchWithExtracted([pendingId], items, rawTranscript: rawTranscript, localeIdentifier: nil)
    }

    func replacePendingWithExtracted(
        _ pendingId: UUID,
        _ items: [ExtractedTodo],
        rawTranscript: String?,
        localeIdentifier: String?
    ) throws {
        try replacePendingBatchWithExtracted([pendingId], items, rawTranscript: rawTranscript, localeIdentifier: localeIdentifier)
    }

    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?) throws {
        try replacePendingBatchWithExtracted(pendingIds, items, rawTranscript: rawTranscript, localeIdentifier: nil)
    }

    func replacePendingBatchWithExtracted(
        _ pendingIds: [UUID],
        _ items: [ExtractedTodo],
        rawTranscript: String?,
        localeIdentifier: String?
    ) throws {
        if let replaceError {
            throw replaceError
        }
        let pendingSet = Set(pendingIds)
        let fallbackLocaleIdentifier = localeIdentifier
            ?? todos.first(where: { pendingSet.contains($0.id) && $0.localeIdentifier != nil })?.localeIdentifier
            ?? Locale.current.identifier
        todos.removeAll { pendingSet.contains($0.id) }
        todos.insert(
            contentsOf: items.map { item in
                var todo = TodoItemData(from: item, rawTranscript: rawTranscript)
                todo.localeIdentifier = localeIdentifier ?? item.localeIdentifier ?? fallbackLocaleIdentifier
                return todo
            },
            at: 0
        )
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
}

@MainActor
private final class CoordinatorTestHistoryStore: VoiceCaptureHistoryStoreProtocol {
    @Published var records: [VoiceCaptureRecordData] = []
    @Published var loadState: VoiceCaptureHistoryLoadState = .empty
    var updateError: Error?
    var lookupError: Error?
    var cleanupError: Error?

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
        if let updateError {
            throw updateError
        }
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
        if let cleanupError {
            throw cleanupError
        }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        records.removeAll { $0.createdAt < cutoff }
        loadState = records.isEmpty ? .empty : .success
    }

    func recordLinkedToPendingTodo(id: UUID) throws -> VoiceCaptureRecordData? {
        if let lookupError {
            throw lookupError
        }
        records.first { $0.pendingTodoID == id }
    }
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
