import Combine
import Foundation
import XCTest
@testable import VoiceTodo

@MainActor
final class AppCoordinatorTests: XCTestCase {
    override func setUp() async throws {
        // 2026-10-09 AI 同意 gate:本类大量用例直接调 processManualInput /
        // handleAppForeground / startRecording——未同意会被 gate 挂起(等披露卡
        // 决议)或防御性跳过。统一预置「已同意」解锁既有路径;gate 行为本身由
        // AIConsentGateTests 专测(含挂起/恢复/跳过)。
        AppGroupConfig.setAIConsentGranted(true)
    }

    override func tearDown() async throws {
        AppGroupConfig.setAIConsentGranted(false)
    }

    func testHandleAppForegroundKeepsPendingOrderWhenExtractionsFinishOutOfOrder() async throws {
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

    /// 草稿出生点回填:键盘输入路径(.partial 事件)应在草稿构造时回填全局默认提前量;
    /// AI 显式解析的提前量优先;无钟点草稿不回填。
    func testManualInputBackfillsGlobalDefaultReminderOffset() async throws {
        UserDefaults.standard.set(30, forKey: ReminderOffsetConfig.defaultOffsetDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReminderOffsetConfig.defaultOffsetDefaultsKey) }

        let extractor = DelayedExtractor()
        extractor.extractionResults["开会提醒"] = ExtractionResult(todos: [
            ExtractedTodo(title: "带钟点", dueDate: Date(), dueTime: "15:00"),
            ExtractedTodo(title: "显式提前", dueDate: Date(), dueTime: "16:00", reminderOffsetMinutes: 60),
            ExtractedTodo(title: "无钟点", timeBucket: .evening)
        ], ignored: "")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: CoordinatorTestStore(todos: []),
            // 不注入的话默认读 NetworkMonitor.shared——懒启动首读 connected=false,
            // 流程走离线分支存 pending,不会经过 .partial 草稿路径。
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("开会提醒")

        XCTAssertEqual(
            coordinator.extractedTodos.map(\.title), ["带钟点", "显式提前", "无钟点"],
            "草稿应进入确认列表,实际:\(coordinator.extractedTodos.map { "\($0.title)|\($0.dueTime ?? "-")|\(String(describing: $0.reminderOffsetMinutes))" })"
        )
        // 注意不能建成 [String: Int?] 字典再取值——外层 Optional 包装会让 XCTAssertNil 误报
        func offsetMinutes(titled title: String) -> Int? {
            coordinator.extractedTodos.first { $0.title == title }?.reminderOffsetMinutes
        }
        XCTAssertEqual(offsetMinutes(titled: "带钟点"), 30, "带钟点且 AI 未解析出提前量的草稿应回填全局默认")
        XCTAssertEqual(offsetMinutes(titled: "显式提前"), 60, "AI 显式解析的提前量不应被全局默认覆盖")
        XCTAssertNil(offsetMinutes(titled: "无钟点"), "无钟点草稿不应回填")
    }

    func testHandleAppForegroundDoesNotConsumePendingWhenPresentationStateChangesBeforeDisplay() async throws {
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

        let pendingIds = try await store.pendingItems().map(\.id)
        XCTAssertEqual(pendingIds, [pendingId])
        XCTAssertTrue(store.deletedIds.isEmpty)
        XCTAssertTrue(coordinator.extractedTodos.isEmpty)
    }

    func testHandleAppForegroundSurfacesPendingReadFailure() async {
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: UUID(), transcript: "pending read fails")
        ])
        store.pendingItemsError = VoiceTodoError.storageReadFailed("fetch failed")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store
        )

        await coordinator.handleAppForeground()

        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)
        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.extractedTodos.isEmpty)
        XCTAssertTrue(store.deletedIds.isEmpty)
    }

    func testHandleAppForegroundSkipsDeferredPendingForCurrentSession() async throws {
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
        coordinator.showConfirmSheet = false
        await coordinator.handleAppForeground()

        XCTAssertEqual(extractor.extractedTranscripts, ["pending while sheet opens"])
        let pendingIds = try await store.pendingItems().map(\.id)
        XCTAssertEqual(pendingIds, [pendingId])
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

    /// 在线确认路径必须把确认页原文透传给 addBatch(basisFilter 的 transcript 兜底输入)。
    /// 回归:此前 addBatch 不收 rawTranscript,非 user_explicit 的 dueDate 无兜底被清空,
    /// 出现「卡片显示后天/这周日/三天后,Add 后变选日期」的展示/落库分裂。
    func testConfirmTodosOnlinePathPassesSheetTranscriptToAddBatch() {
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store
        )
        // activeInputTranscript 为空时 confirmSheetTranscript 兜底到 transcript——
        // 断言的就是 confirmTodos 读取确认页原文这一行为,与生产同路径。
        coordinator.transcript = "后天早上取快递"

        let success = coordinator.confirmTodos([
            ExtractedTodo(title: "取快递", detail: "后天早上取快递", dueHint: "后天早上")
        ])

        XCTAssertTrue(success)
        XCTAssertEqual(store.lastAddBatchRawTranscript, "后天早上取快递")
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
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵"])
        await assertSystemCalendarSyncFailureToastShown(coordinator)
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
        XCTAssertEqual(store.todos.map(\.title), ["完成英语背诵", "完成数学作业"])
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item1.id], "event-partial")
        XCTAssertNil(store.systemCalendarEventIdentifiers[item2.id])
        await assertSystemCalendarSyncFailureToastShown(coordinator)
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
        XCTAssertEqual(writer.removedIdentifiers, ["event-\(item.id.uuidString)"])
        XCTAssertNil(store.systemCalendarEventIdentifiers[item.id])
        await assertSystemCalendarSyncFailureToastShown(coordinator)
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

    func testUpdateTodoDetailPersistsTimeBucketThroughStoreContract() throws {
        let item = TodoItemData(title: "晚上健身")
        let store = CoordinatorTestStore(todos: [item])
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store,
            calendarWriteModeProvider: { .appOnly }
        )

        try coordinator.updateTodoDetail(
            item.id,
            update: TodoDetailUpdate(
                title: item.title,
                detail: nil,
                category: nil,
                priority: nil,
                dueDate: Calendar.current.startOfDay(for: Date()),
                hasDueTime: false,
                timeBucket: .evening,
                dueHint: nil,
                recurrenceRule: nil
            )
        )

        XCTAssertEqual(store.todos.first?.timeBucket, .evening)
        XCTAssertFalse(store.todos.first?.hasDueTime ?? true)
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

    func testCancelRecordingStopsRecordingWithoutToast() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.isRecording = true
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: CoordinatorTestStore()
        )

        coordinator.cancelRecording()
        await Task.yield()

        XCTAssertFalse(voiceInput.isRecording)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertFalse(coordinator.showToast)
        // 区分路径：用户取消应调 cancelRecordingByUser，不是 stopRecording 或中断。
        XCTAssertEqual(voiceInput.cancelByUserCallCount, 1, "应调 cancelRecordingByUser")
        XCTAssertEqual(voiceInput.stopRecordingCallCount, 0, "不应回退到 stopRecording")
        XCTAssertEqual(voiceInput.cancelByInterruptionCallCount, 0, "不应误用中断路径")
    }

    func testStreamingFailureAfterPartialResultsKeepsPartialTodos() async {
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(
                todos: [ExtractedTodo(title: "部分结果", detail: "部分结果")],
                ignored: ""
            )
        ]
        extractor.streamingError = VoiceTodoError.apiResponseInvalid("broken stream")
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("记录一个会在流式结束时报错的待办")

        // partial fallback(77adaf1):流断前已收到的 partial 当成功保留,不清弹层、
        // 不弹错误 toast——给用户 11/13 条比清空让用户重来更友好。
        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertEqual(coordinator.extractedTodos.map(\.title), ["部分结果"])
        XCTAssertFalse(coordinator.showToast)
        XCTAssertTrue(store.todos.isEmpty, "拿到 partial 结果时不再额外落兜底条目")
    }

    func testTranscriptTooLongSavesUnparsedCardAndClearsSheet() async {
        let extractor = DelayedExtractor()
        extractor.streamingError = VoiceTodoError.transcriptTooLong
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("一口气说了太多条待办")

        // 确定性失败:原文存手动卡片(不进自动恢复队列),弹层关闭,toast 告知原文去向。
        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos.first?.rawTranscript, "一口气说了太多条待办")
        XCTAssertFalse(store.todos.first?.needsAIProcessing ?? true, "手动卡片不进 pending 自动恢复")
        XCTAssertEqual(store.todos.first?.extractionOutcome, .unparsed)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(
            coordinator.toastMessage,
            "\(ErrorMessages.transcriptTooLong) \(ErrorMessages.manualCardSaved)"
        )
    }

    func testNoTodosSavesUnparsedCard() async {
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [], ignored: "just chatting")
        ]
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("就是闲聊没有待办")

        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertEqual(store.todos.count, 1, "没识别出待办也绝不丢原文")
        XCTAssertEqual(store.todos.first?.rawTranscript, "就是闲聊没有待办")
        XCTAssertFalse(store.todos.first?.needsAIProcessing ?? true)
        XCTAssertEqual(store.todos.first?.extractionOutcome, .unparsed)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.noTodosCardSaved)
    }

    func testVoiceErrorWithPartialTranscriptSavesPending() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "说了一半被中断"
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: store
        )

        // 录音中途来电/识别失败:errorPublisher 触发,部分转写必须落库
        voiceInput.error = .audioSessionInterrupted
        await Task.yield()

        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos.first?.rawTranscript, "说了一半被中断")
        XCTAssertTrue(store.todos.first?.needsAIProcessing ?? false, "部分转写走 pending,下次前台自动补解析")
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(
            coordinator.toastMessage,
            "\(ErrorMessages.audioSessionInterrupted) \(ErrorMessages.partialTranscriptSaved)"
        )
    }

    func testVoiceErrorWithEmptyTranscriptSavesNothing() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = ""
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: DelayedExtractor(),
            store: store
        )

        voiceInput.error = .speechRecognitionUnavailable
        await Task.yield()

        XCTAssertTrue(store.todos.isEmpty, "没有转写内容时不应保存空 pending")
        XCTAssertTrue(coordinator.showToast)
    }

    func testStopAndProcessSkipsParsingWhenRecordingEndedWithError() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.isRecording = true
        voiceInput.transcript = "识别中途出错的部分转写"
        let extractor = DelayedExtractor()
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: extractor,
            store: store
        )

        // 手动停止流程中错误先到:sink 已保存部分转写
        voiceInput.error = .recordingFailed("识别超时")
        await Task.yield()
        await coordinator.stopRecordingAndProcess()

        // 错误后不得再送解析:同一段转写只落一份 pending,不重复弹确认页
        XCTAssertTrue(extractor.extractedTranscripts.isEmpty, "错误路径不应再触发解析")
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertFalse(coordinator.showConfirmSheet)
    }

    func testActionButtonVoiceErrorDoesNotLeakAutoProcessingState() async {
        let voiceInput = CoordinatorTestVoiceInput()
        voiceInput.transcript = "action button 录音中途被来电中断"
        let extractor = DelayedExtractor()
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: voiceInput,
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        // action-button 流程在后台跑;等 startRecording 置位 isRecording 后再模拟中断,
        // 让 waitForAutoStop 的 isRecording 监听立即返回而不是吃满 60s 超时。
        // 自旋设上限:未来若 handleActionButtonLaunch 因守卫提前 return,这里应失败而非挂死。
        let launchTask = Task { await coordinator.handleActionButtonLaunch() }
        var spinCount = 0
        while !voiceInput.isRecording {
            spinCount += 1
            if spinCount > 10_000 {
                XCTFail("startRecording 未在合理时间内置位 isRecording,handleActionButtonLaunch 可能被守卫提前短路")
                return
            }
            await Task.yield()
        }
        voiceInput.error = .audioSessionInterrupted
        voiceInput.isRecording = false
        await launchTask.value
        await Task.yield()

        // 中断的部分转写由 errorPublisher sink 兜底为 pending
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertTrue(store.todos.first?.needsAIProcessing ?? false)

        // isAutoProcessing 不得泄漏:错误流程返回后手动输入仍可用
        // (泄漏会永久阻塞 processManualInput / handleAppForeground 的 !isAutoProcessing 守卫)
        await coordinator.processManualInput("中断后改用键盘继续输入")
        XCTAssertTrue(coordinator.showConfirmSheet, "isAutoProcessing 泄漏会永久阻塞手动输入")
        XCTAssertEqual(coordinator.extractedTodos.map(\.title), ["extracted 中断后改用键盘继续输入"])
    }

    func testForegroundHoldsNoTodoPendingAsUnparsedInsteadOfDeleting() async {
        let pendingId = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: pendingId, transcript: "闲聊无待办")
        ])
        let extractor = DelayedExtractor()
        extractor.extractionResults["闲聊无待办"] = ExtractionResult(todos: [], ignored: "chat")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store
        )

        await coordinator.handleAppForeground()

        // 原文不丢:解析出 0 条待办的 pending 转持为手动卡片,而不是删除
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos.first?.id, pendingId)
        XCTAssertFalse(store.todos.first?.needsAIProcessing ?? true)
        XCTAssertEqual(store.todos.first?.extractionOutcome, .unparsed)
        XCTAssertFalse(coordinator.showConfirmSheet)
    }

    func testForegroundHoldsDeterministicallyFailedPending() async {
        let pendingId = UUID()
        let store = CoordinatorTestStore(todos: [
            pendingTodo(id: pendingId, transcript: "超长转写")
        ])
        let extractor = DelayedExtractor()
        extractor.extractionErrors["超长转写"] = VoiceTodoError.transcriptTooLong
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store
        )

        await coordinator.handleAppForeground()

        // 确定性失败转持:停止每次前台自动重试烧额度,原文保留为手动卡片
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos.first?.id, pendingId)
        XCTAssertFalse(store.todos.first?.needsAIProcessing ?? true)
        XCTAssertEqual(store.todos.first?.extractionOutcome, .unparsed)
        XCTAssertTrue(coordinator.showToast, "失败原因照常透出")
    }

    func testIPDailyLimitShowsPreciseToastAfterSavingFallback() async {
        let extractor = DelayedExtractor()
        extractor.streamingError = VoiceTodoError.ipRateLimited(retryAfter: 3_600)
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        await coordinator.processManualInput("IP 限额后保存原始输入")

        XCTAssertFalse(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.ipRateLimited)
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos.first?.rawTranscript, "IP 限额后保存原始输入")
        XCTAssertTrue(store.todos.first?.needsAIProcessing ?? false)
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

    func testConfirmDuringStreamingSavesVisibleTodosAndStopsLateResults() async {
        let first = ExtractedTodo(title: "第一条待办", detail: "第一条待办")
        let second = ExtractedTodo(title: "第二条待办", detail: "第二条待办")
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [first], ignored: ""),
            ExtractionResult(todos: [first, second], ignored: "")
        ]
        extractor.streamingResultDelayNanoseconds = 2_000_000_000
        let store = CoordinatorTestStore()
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        let processingTask = Task { await coordinator.processManualInput("流式生成两条待办") }
        await waitForPartialResult(coordinator)

        XCTAssertTrue(coordinator.isExtracting)
        XCTAssertEqual(coordinator.extractedTodos.map(\.title), ["第一条待办"])
        XCTAssertTrue(coordinator.confirmTodos(coordinator.extractedTodos))

        await processingTask.value
        XCTAssertFalse(coordinator.isExtracting)
        XCTAssertEqual(store.todos.map(\.title), ["第一条待办"])
        XCTAssertEqual(coordinator.extractedTodos.map(\.title), ["第一条待办"])
    }

    func testConfirmFailureDuringStreamingKeepsSheetAndExtractionActive() async {
        let first = ExtractedTodo(title: "第一条待办", detail: "第一条待办")
        let second = ExtractedTodo(title: "第二条待办", detail: "第二条待办")
        let extractor = DelayedExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [first], ignored: ""),
            ExtractionResult(todos: [first, second], ignored: "")
        ]
        extractor.streamingResultDelayNanoseconds = 2_000_000_000
        let store = CoordinatorTestStore()
        store.addBatchError = VoiceTodoError.storageWriteFailed("confirm failed")
        let coordinator = AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            networkIsConnectedProvider: { true }
        )

        let processingTask = Task { await coordinator.processManualInput("保存失败时继续解析") }
        await waitForPartialResult(coordinator)

        XCTAssertFalse(coordinator.confirmTodos(coordinator.extractedTodos))
        XCTAssertTrue(coordinator.showConfirmSheet)
        XCTAssertTrue(coordinator.isExtracting)
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)

        coordinator.cancelTodos()
        await processingTask.value
    }

    func testHandleAppForegroundKeepsInvalidPendingWhenDeleteFails() async throws {
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

        let pendingIds = try await store.pendingItems().map(\.id)
        XCTAssertEqual(pendingIds, [pendingId])
        XCTAssertEqual(store.deletedIds, [pendingId])
        XCTAssertTrue(coordinator.showToast)
        XCTAssertEqual(coordinator.toastMessage, ErrorMessages.storageError)
    }

    // MARK: - 配额耗尽 × 订阅状态

    /// 回归背景(2026-08-20):代理验签失败把订阅用户降级到免费档,免费额度耗尽的
    /// 429 一路 presentPaywall(source: .quotaExhausted),已订阅用户看到「升级」墙。
    /// 这组测试锁定:免费用户照旧弹 paywall;已订阅用户改弹额度耗尽 toast,不弹墙。

    private func makeQuotaExhaustedCoordinator(
        store: CoordinatorTestStore = CoordinatorTestStore(),
        entitlement: EntitlementManager? = nil,
        quotaUsage: QuotaUsage? = nil
    ) -> AppCoordinator {
        let extractor = DelayedExtractor()
        extractor.extractionErrors["额度耗尽测试"] = VoiceTodoError.quotaExhausted(tier: "free", resetAt: "2026-08-21")
        return AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store,
            entitlement: entitlement,
            networkIsConnectedProvider: { true },
            quotaUsage: quotaUsage
        )
    }

    func testQuotaExhaustedDuringManualInputPresentsPaywallForFreeUser() async {
        let coordinator = makeQuotaExhaustedCoordinator()

        await coordinator.processManualInput("额度耗尽测试")

        await waitForPaywallShown(coordinator)
    }

    func testQuotaExhaustedDuringManualInputSuppressesPaywallForProUser() async {
        let entitlement = EntitlementManager(enableTransactionListener: false)
        entitlement.setEntitlementForTesting(isPro: true)
        let coordinator = makeQuotaExhaustedCoordinator(entitlement: entitlement)

        await coordinator.processManualInput("额度耗尽测试")

        await waitForToast(coordinator, message: ErrorMessages.quotaExhaustedPro)
        XCTAssertFalse(coordinator.showPaywall, "已订阅用户不应看到升级 paywall")
    }

    /// 代理拒订阅（请求带了凭证仍按 free 档计）：额度耗尽 toast 不再说
    /// 「Pro 额度已用完」——那会把「付了钱没生效」盖住；改提示订阅验证未通过
    /// + 恢复购买出口。同样不弹升级墙（已订阅）。
    func testQuotaExhaustedWithRejectedSubscriptionHintsVerificationFailure() async {
        let entitlement = EntitlementManager(enableTransactionListener: false)
        entitlement.setEntitlementForTesting(isPro: true)
        let quotaUsage = QuotaUsage()
        quotaUsage.applyQuotaHeaders(
            from: HTTPURLResponse(
                url: URL(string: "https://proxy.test/v1/todo-extractions")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-Quota-Plan": "free",
                    "X-Quota-Limit": "3",
                    "X-Quota-Used": "3",
                    "X-Quota-Remaining": "0"
                ]
            )!,
            carriedSubscriptionJWS: true
        )
        let coordinator = makeQuotaExhaustedCoordinator(
            entitlement: entitlement,
            quotaUsage: quotaUsage
        )

        await coordinator.processManualInput("额度耗尽测试")

        await waitForToast(coordinator, message: ErrorMessages.subscriptionRejected)
        XCTAssertFalse(coordinator.showPaywall, "已订阅用户不应看到升级 paywall")
    }

    func testQuotaExhaustedDuringReextractPresentsPaywallForFreeUser() async {
        let todoId = UUID()
        let coordinator = makeQuotaExhaustedCoordinator(
            store: CoordinatorTestStore(todos: [pendingTodo(id: todoId, transcript: "额度耗尽测试")])
        )

        coordinator.reextract(todoID: todoId)

        await waitForPaywallShown(coordinator)
    }

    func testQuotaExhaustedDuringReextractSuppressesPaywallForProUser() async {
        let entitlement = EntitlementManager(enableTransactionListener: false)
        entitlement.setEntitlementForTesting(isPro: true)
        let todoId = UUID()
        let coordinator = makeQuotaExhaustedCoordinator(
            store: CoordinatorTestStore(todos: [pendingTodo(id: todoId, transcript: "额度耗尽测试")]),
            entitlement: entitlement
        )

        coordinator.reextract(todoID: todoId)

        await waitForToast(coordinator, message: ErrorMessages.quotaExhaustedPro)
        XCTAssertFalse(coordinator.showPaywall, "已订阅用户不应看到升级 paywall")
    }

    // MARK: - 编辑原文 → 重新解析(「没能识别」卡片,2026-10 用户决策)

    /// 编辑保存契约:新文本**先落库**再触发解析——extract 被调用的那一刻,
    /// 库里必须已是新文本(永不丢话:解析失败也不丢用户编辑)。
    ///
    /// 条目用显式 `.unparsed`(不能用 pendingTodo:TodoItemData 的 outcome 默认
    /// .parsed,会把"轮询等 .parsed"变成立即通过、把"断言非 .parsed"变成必然失败)。
    private func unparsedTodo(id: UUID, transcript: String) -> TodoItemData {
        var todo = pendingTodo(id: id, transcript: transcript)
        todo.extractionOutcome = .unparsed
        todo.needsAIProcessing = false
        return todo
    }

    @discardableResult
    private func makeEditTranscriptCoordinator(
        store: CoordinatorTestStore,
        extractor: DelayedExtractor = DelayedExtractor()
    ) -> AppCoordinator {
        AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: extractor,
            store: store
        )
    }

    func testEditTranscriptPersistsNewTextBeforeExtraction() async {
        let todoId = UUID()
        let store = CoordinatorTestStore(todos: [unparsedTodo(id: todoId, transcript: "旧原文")])
        let extractor = DelayedExtractor()
        // extract 进行中捕获库内 rawTranscript:证明编辑文本在解析前已落库。
        var transcriptAtExtractTime: String?
        extractor.onExtract = { @MainActor in
            transcriptAtExtractTime = store.findTodo(by: todoId)?.rawTranscript
        }
        let coordinator = makeEditTranscriptCoordinator(store: store, extractor: extractor)

        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")

        for _ in 0..<100 {
            if transcriptAtExtractTime != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transcriptAtExtractTime, "编辑后的新原文", "extract 被调用时新文本必须已落库")
    }

    func testEditTranscriptExtractionFailureKeepsEditedTranscript() async {
        let todoId = UUID()
        let store = CoordinatorTestStore(todos: [unparsedTodo(id: todoId, transcript: "旧原文")])
        let extractor = DelayedExtractor()
        extractor.extractionErrors["编辑后的新原文"] = VoiceTodoError.apiResponseInvalid("forced parse failure")
        let coordinator = makeEditTranscriptCoordinator(store: store, extractor: extractor)

        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")

        // 等 extractor 真正被调用过(解析已失败)再断言库内状态
        for _ in 0..<100 {
            if extractor.extractedTranscripts.contains("编辑后的新原文") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(extractor.extractedTranscripts, ["编辑后的新原文"])
        XCTAssertEqual(store.findTodo(by: todoId)?.rawTranscript, "编辑后的新原文", "解析失败不得丢用户编辑")
        XCTAssertEqual(store.findTodo(by: todoId)?.extractionOutcome, .unparsed, "失败后条目不得翻成 .parsed")
    }

    func testEditTranscriptEmptyResultKeepsUnparsedCard() async {
        let todoId = UUID()
        let store = CoordinatorTestStore(todos: [unparsedTodo(id: todoId, transcript: "旧原文")])
        let extractor = DelayedExtractor()
        extractor.extractionResults["编辑后的新原文"] = ExtractionResult(todos: [], ignored: "")
        let coordinator = makeEditTranscriptCoordinator(store: store, extractor: extractor)

        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")

        await waitForToast(coordinator, message: ErrorMessages.reextractStillEmpty)
        XCTAssertEqual(store.findTodo(by: todoId)?.rawTranscript, "编辑后的新原文")
        XCTAssertEqual(store.findTodo(by: todoId)?.extractionOutcome, .unparsed)
    }

    func testEditTranscriptSuccessReplacesTodo() async {
        let todoId = UUID()
        let store = CoordinatorTestStore(todos: [unparsedTodo(id: todoId, transcript: "旧原文")])
        let extractor = DelayedExtractor()
        extractor.extractionResults["编辑后的新原文"] = ExtractionResult(
            todos: [ExtractedTodo(title: "买菜", detail: "编辑后的新原文")],
            ignored: ""
        )
        let coordinator = makeEditTranscriptCoordinator(store: store, extractor: extractor)

        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")

        for _ in 0..<100 {
            if store.findTodo(by: todoId)?.extractionOutcome == .parsed { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let replaced = store.findTodo(by: todoId)
        XCTAssertEqual(replaced?.extractionOutcome, .parsed, "解析成功应替换为 .parsed 条目")
        XCTAssertEqual(replaced?.title, "买菜")
    }

    func testEditTranscriptDuplicateGuardWhileReextracting() async {
        let todoId = UUID()
        let store = CoordinatorTestStore(todos: [unparsedTodo(id: todoId, transcript: "旧原文")])
        let extractor = DelayedExtractor()
        // 慢 extract:让第一次编辑的重解析保持进行中
        extractor.delays["编辑后的新原文"] = 300_000_000
        let coordinator = makeEditTranscriptCoordinator(store: store, extractor: extractor)

        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")
        // 等第一次解析真正开始
        for _ in 0..<100 {
            if !extractor.extractedTranscripts.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // 进行中再次编辑:被 reextractingTodoIDs 守卫拒,不触发第二次 extract
        coordinator.editTranscriptAndReextract(todoID: todoId, newTranscript: "编辑后的新原文")

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(extractor.extractedTranscripts.count, 1, "重解析进行中重复调用必须被守卫拦截")
    }

    // MARK: - Helpers

    private func waitForPaywallShown(_ coordinator: AppCoordinator) async {
        for _ in 0..<100 {
            if coordinator.showPaywall { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected quota exhaustion to present the paywall")
    }

    private func waitForToast(_ coordinator: AppCoordinator, message: String) async {
        for _ in 0..<100 {
            if coordinator.showToast && coordinator.toastMessage == message { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected toast \"\(message)\", got \"\(coordinator.toastMessage)\"")
    }

    private func waitForPartialResult(_ coordinator: AppCoordinator) async {
        for _ in 0..<100 {
            if !coordinator.extractedTodos.isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected a streaming partial result")
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

    private func assertSystemCalendarSyncFailureToastShown(
        _ coordinator: AppCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if coordinator.showToast && coordinator.toastMessage == ErrorMessages.systemCalendarSyncFailed {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail(
            "Expected system calendar sync failure toast, got showToast=\(coordinator.showToast), toastMessage=\(coordinator.toastMessage)",
            file: file,
            line: line
        )
    }
}

@MainActor
private final class CoordinatorTestVoiceInput: VoiceInputProtocol {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var error: VoiceTodoError?
    @Published var didAutoFinishDueToSilence = false
    @Published var audioLevel: Float = 0
    let currentLocale = Locale(identifier: "zh-Hans")

    /// 记录各方法被调用次数，便于区分 cancel 走的是哪条路径。
    private(set) var stopRecordingCallCount = 0
    private(set) var cancelByUserCallCount = 0
    private(set) var cancelByInterruptionCallCount = 0

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }
    var didAutoFinishDueToSilencePublisher: AnyPublisher<Bool, Never> { $didAutoFinishDueToSilence.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { $audioLevel.eraseToAnyPublisher() }
    var recordingSuccessPublisher: AnyPublisher<Void, Never> { Empty<Void, Never>().eraseToAnyPublisher() }

    func startRecording() async throws {
        isRecording = true
    }

    func stopRecording() {
        stopRecordingCallCount += 1
        isRecording = false
    }

    func cancelRecordingDueToInterruption() {
        cancelByInterruptionCallCount += 1
        isRecording = false
        error = .audioSessionInterrupted
    }

    func cancelRecordingByUser() {
        cancelByUserCallCount += 1
        isRecording = false
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
    var streamingResultDelayNanoseconds: UInt64 = 0
    private let extractedTranscriptsLock = NSLock()
    private var storedExtractedTranscripts: [String] = []
    var extractedTranscripts: [String] {
        extractedTranscriptsLock.lock()
        defer { extractedTranscriptsLock.unlock() }
        return storedExtractedTranscripts
    }

    init(delays: [String: UInt64] = [:]) {
        self.delays = delays
    }

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        recordExtractedTranscript(transcript)
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

    private func recordExtractedTranscript(_ transcript: String) {
        extractedTranscriptsLock.lock()
        defer { extractedTranscriptsLock.unlock() }
        storedExtractedTranscripts.append(transcript)
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
        let resultDelay = streamingResultDelayNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (index, result) in results.enumerated() {
                        if index > 0, resultDelay > 0 {
                            try await Task.sleep(nanoseconds: resultDelay)
                        }
                        try Task.checkCancellation()
                        continuation.yield(result)
                    }
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class CoordinatorTestStore: AppCoordinatorTodoStore, PendingRecoveryTodoStore, PendingTranscriptCreating, CalendarSyncTodoStore {
    @Published var todos: [TodoItemData] {
        didSet { todosRevision &+= 1 }
    }
    @Published private(set) var todosRevision: Int = 0
    var deletedIds: [UUID] = []
    var deleteErrorIds: Set<UUID> = []
    var systemCalendarEventIdentifiers: [UUID: String] = [:]
    var onUpdateIdentifier: (() -> Void)?
    var identifierUpdateError: Error?
    var addBatchError: Error?
    var lastAddBatchRawTranscript: String?
    var replaceError: Error?
    var pendingItemsError: Error?

    init(todos: [TodoItemData] = []) {
        self.todos = todos
        self.systemCalendarEventIdentifiers = Dictionary(
            uniqueKeysWithValues: todos.compactMap { todo in
                todo.systemCalendarEventIdentifier.map { (todo.id, $0) }
            }
        )
    }

    func findTodo(by id: UUID) -> TodoItemData? {
        todos.first { $0.id == id }
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        try addBatch(items, localeIdentifier: nil)
    }

    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws {
        if let addBatchError {
            throw addBatchError
        }
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

    /// 在线确认路径新签名:记录收到的 rawTranscript 供断言(confirmTodos 必须
    /// 把确认页原文透传给 basisFilter 的 transcript 兜底)。
    func addBatch(_ items: [ExtractedTodo], rawTranscript: String?, localeIdentifier: String?) throws {
        lastAddBatchRawTranscript = rawTranscript
        try addBatch(items, localeIdentifier: localeIdentifier)
    }

    func addImportedBatch(_ items: [TodoItemData]) throws {
        // 与 MockStore.addImportedBatch 一致:反转后 insert 到头部,
        // 保证传入数组的顺序与最终 todos 中的展示顺序一致(逐条 insert 到头部会让顺序倒过来)。
        todos.insert(contentsOf: items.reversed(), at: 0)
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

    func addManualUnparsedTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        var todo = TodoItemData(
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: false,
            localeIdentifier: localeIdentifier
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

    func delete(_ id: UUID) throws {
        deletedIds.append(id)
        if deleteErrorIds.contains(id) {
            throw VoiceTodoError.storageWriteFailed("delete failed")
        }
        todos.removeAll { $0.id == id }
    }

    func toggleComplete(_ id: UUID) throws {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
        }
        todos[index].isCompleted.toggle()
    }

    /// 拖拽排序调用记录（AppCoordinator.reorderTodos 集成测试用）。
    var reorderCalls: [[UUID]] = []
    func reorder(ids: [UUID]) throws {
        reorderCalls.append(ids)
    }

    func updateFull(_ id: UUID, update: TodoDetailUpdate, origin: TaskEventOrigin) throws {
        // 测试 mock:origin 仅满足协议签名,不落事件。
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.storageReadFailed("todo not found: \(id)")
        }

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
        if todos[index].recurrenceRule != nil {
            todos[index].isCompleted = false
            todos[index].completedAt = nil
        }
    }

    /// 测试 mock 版编辑原文:内存三字段同步,语义与 `TodoStore.updateRawTranscript` 对齐。
    func updateRawTranscript(_ id: UUID, transcript: String) throws {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceTodoError.apiResponseInvalid("updateRawTranscript with empty transcript")
        }
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw VoiceTodoError.todoNotFound(id)
        }
        todos[index].title = TextUtils.truncateTitle(from: trimmed)
        todos[index].detail = trimmed
        todos[index].rawTranscript = trimmed
    }

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
            id: id,
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

    func pendingItems() async throws -> [TodoItemData] {
        if let pendingItemsError {
            throw pendingItemsError
        }
        return todos.filter(\.needsAIProcessing)
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

// MARK: - AI 同意 gate(2026-10-09 合规:转写文本发第三方 AI 前须显式同意)

/// 专项覆盖:`ensureAIConsent` 的挂起/恢复语义、已同意直通、
/// `handleAppForeground` 的防御性跳过、`AppGroupConfig` 同意标志读写缺省语义。
/// 真实 App Group suite 在测试宿主内可写;每用例自管状态,tearDown 统一清。
@MainActor
final class AIConsentGateTests: XCTestCase {
    override func tearDown() async throws {
        AppGroupConfig.setAIConsentGranted(false)
    }

    private func makeCoordinator(store: CoordinatorTestStore = CoordinatorTestStore(todos: [])) -> AppCoordinator {
        AppCoordinator(
            voiceInput: CoordinatorTestVoiceInput(),
            extractor: DelayedExtractor(),
            store: store
        )
    }

    private func pendingTodoItem(transcript: String) -> TodoItemData {
        TodoItemData(
            id: UUID(),
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true
        )
    }

    /// 已同意:立即放行,不弹披露卡(零打扰)。
    func testEnsureAIConsentGrantedPassesImmediatelyWithoutSheet() async {
        AppGroupConfig.setAIConsentGranted(true)
        let coordinator = makeCoordinator()

        let granted = await coordinator.ensureAIConsent()

        XCTAssertTrue(granted, "已同意应直接放行")
        XCTAssertFalse(coordinator.showAIConsent, "已同意时不得弹披露卡")
    }

    /// 未同意:挂起调用方并上屏披露卡;用户同意 → resume(true) 且写入 App Group。
    func testEnsureAIConsentSuspendsUntilUserGrants() async throws {
        AppGroupConfig.setAIConsentGranted(false)
        let coordinator = makeCoordinator()

        let pending = Task { await coordinator.ensureAIConsent() }
        let deadline = Date().addingTimeInterval(2.0)
        while !coordinator.showAIConsent && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(coordinator.showAIConsent, "未同意时应弹披露卡(调用方挂起)")

        coordinator.handleAIConsentDismissed(granted: true)
        let granted = await pending.value

        XCTAssertTrue(granted, "同意后挂起方应以 true 恢复")
        XCTAssertTrue(AppGroupConfig.aiConsentGranted(), "同意必须写入 App Group(供 Siri 扩展读取)")
        XCTAssertFalse(coordinator.showAIConsent, "决议后披露卡应收起")
    }

    /// 未同意且用户拒绝:resume(false),同意标志保持 false(下次入口再弹)。
    func testEnsureAIConsentDeclineResumesFalse() async throws {
        AppGroupConfig.setAIConsentGranted(false)
        let coordinator = makeCoordinator()

        let pending = Task { await coordinator.ensureAIConsent() }
        let deadline = Date().addingTimeInterval(2.0)
        while !coordinator.showAIConsent && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        coordinator.handleAIConsentDismissed(granted: false)
        let granted = await pending.value

        XCTAssertFalse(granted, "拒绝后挂起方应以 false 恢复(本次操作取消)")
        XCTAssertFalse(AppGroupConfig.aiConsentGranted(), "拒绝不得写入同意")
    }

    /// sheet 兜底路径(按钮已决议后 onDismiss 再入):幂等,不覆盖已写入的同意。
    func testDismissedTwiceIsIdempotent() async throws {
        AppGroupConfig.setAIConsentGranted(false)
        let coordinator = makeCoordinator()

        let pending = Task { await coordinator.ensureAIConsent() }
        let deadline = Date().addingTimeInterval(2.0)
        while !coordinator.showAIConsent && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        coordinator.handleAIConsentDismissed(granted: true)
        _ = await pending.value
        // 模拟 SwiftUI sheet onDismiss 在按钮路径之后的兜底再入(误报 granted: false)
        coordinator.handleAIConsentDismissed(granted: false)

        XCTAssertTrue(AppGroupConfig.aiConsentGranted(), "兜底再入不得把已写入的同意翻回 false")
    }

    /// 前台 pending 恢复的防御 gate:Siri 未同意存的原文回前台时不发往 AI。
    func testHandleAppForegroundSkipsPendingWithoutConsent() async {
        AppGroupConfig.setAIConsentGranted(false)
        let store = CoordinatorTestStore(todos: [pendingTodoItem(transcript: "siri 未同意时说的原文")])
        let coordinator = makeCoordinator(store: store)

        await coordinator.handleAppForeground()

        XCTAssertFalse(coordinator.showConfirmSheet, "未同意时 pending 不得发往 AI(静默跳过,不弹卡)")
        XCTAssertFalse(coordinator.showAIConsent, "防御 gate 是静默跳过,不应弹披露卡")
    }

    /// 同意标志读写与缺省语义(注入临时 suite,不依赖真实 App Group 残留):
    /// 缺省 false = 显式同意原则,不做隐式默认同意。
    func testConsentFlagDefaultAndReadWrite() {
        let suiteName = "AIConsentGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppGroupConfig.aiConsentGranted(defaults: defaults), "从未写入必须缺省 false")
        AppGroupConfig.setAIConsentGranted(true, defaults: defaults)
        XCTAssertTrue(AppGroupConfig.aiConsentGranted(defaults: defaults))
        AppGroupConfig.setAIConsentGranted(false, defaults: defaults)
        XCTAssertFalse(AppGroupConfig.aiConsentGranted(defaults: defaults))
    }
}
