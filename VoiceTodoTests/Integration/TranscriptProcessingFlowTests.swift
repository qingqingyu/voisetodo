import XCTest
@testable import VoiceTodo

@MainActor
final class TranscriptProcessingFlowTests: XCTestCase {
    func testProcessEmptyInputEmitsEmpty() async {
        let store = TranscriptFlowTestStore()
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: TranscriptFlowTestExtractor(),
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "   ", locale: Locale(identifier: "zh-Hans"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["empty"])
        XCTAssertTrue(store.rawTranscripts.isEmpty)
    }

    func testProcessNoTodosSavesManualCard() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [], ignored: "nothing")
        ]
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "just chatting", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["partial", "manualSaved"])
        XCTAssertNil(events.last?.manualReason, "noTodos 非 error 场景 reason 为 nil")
        XCTAssertEqual(store.manualTranscripts, ["just chatting"], "原文必须存为手动卡片,不丢话")
        XCTAssertEqual(store.manualTranscriptLocales, ["en-US"])
        XCTAssertTrue(store.rawTranscripts.isEmpty, "手动卡片不进 pending 自动恢复队列")
    }

    func testProcessPartialThenFailureFallsBackToPartialSuccess() async {
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [ExtractedTodo(title: "partial todo")], ignored: "")
        ]
        extractor.streamingError = VoiceTodoError.apiResponseInvalid("broken stream")
        let flow = TranscriptProcessingFlow(
            store: TranscriptFlowTestStore(),
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "partial then fail", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["partial", "success"])
        XCTAssertEqual(events.last?.todoTitles, ["partial todo"])
    }

    func testProcessTranscriptTooLongSavesManualCard() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.transcriptTooLong
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "way too many todos at once", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["manualSaved"])
        XCTAssertEqual(events.first?.manualReason, .transcriptTooLong)
        XCTAssertEqual(store.manualTranscripts, ["way too many todos at once"], "确定性错误原文必须保留")
        XCTAssertTrue(store.rawTranscripts.isEmpty, "transcriptTooLong 重试必败,不进 pending 烧额度")
    }

    func testProcessApiResponseInvalidWithoutPartialSavesManualCard() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.apiResponseInvalid("bad payload")
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "invalid response input", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["manualSaved"])
        XCTAssertEqual(events.first?.manualReason, .apiResponseInvalid("bad payload"))
        XCTAssertEqual(store.manualTranscripts, ["invalid response input"])
    }

    func testProcessJsonParsingFailedSavesManualCard() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.jsonParsingFailed("schema mismatch")
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "json parse fail input", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["manualSaved"])
        XCTAssertEqual(store.manualTranscripts, ["json parse fail input"])
    }

    func testProcessApiServerErrorSavesPendingFallback() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.apiServerError(statusCode: 500)
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "server hiccup input", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["fallbackSaved"])
        XCTAssertEqual(events.first?.fallbackReason, .apiServerError(statusCode: 500))
        XCTAssertEqual(store.rawTranscripts, ["server hiccup input"], "5xx 是瞬时故障,走 pending 自动恢复")
        XCTAssertTrue(store.manualTranscripts.isEmpty)
    }

    func testProcessUnknownErrorSavesManualCard() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = URLError(.badServerResponse)
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "unknown failure input", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["manualSaved"])
        XCTAssertNil(events.first?.manualReason, "非 VoiceTodoError 无归类原因")
        XCTAssertEqual(store.manualTranscripts, ["unknown failure input"], "未知错误同样不丢话")
    }

    func testProcessManualSaveFailureEmitsManualSaveFailed() async {
        let store = TranscriptFlowTestStore()
        store.manualAddError = VoiceTodoError.storageWriteFailed("disk full")
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.transcriptTooLong
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "manual save fails", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["manualSaveFailed"])
    }

    func testProcessKeepsReceivedAnyWhenLaterPartialIsEmpty() async {
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [ExtractedTodo(title: "first todo")], ignored: ""),
            ExtractionResult(todos: [], ignored: "empty final")
        ]
        let flow = TranscriptProcessingFlow(
            store: TranscriptFlowTestStore(),
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "todo then empty final", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["partial", "partial", "success"])
        XCTAssertEqual(events.first?.todoTitles, ["first todo"])
        XCTAssertEqual(events.last?.todoTitles, ["first todo"])
    }

    func testProcessNetworkFailureSavesTranscriptForFallback() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.networkUnavailable
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "save this later", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["fallbackSaved"])
        XCTAssertEqual(events.first?.fallbackReason, .networkUnavailable)
        XCTAssertEqual(store.rawTranscripts, ["save this later"])
        XCTAssertEqual(store.rawTranscriptLocales, ["en-US"])
    }

    func testProcessIPDailyLimitPreservesReasonAfterSavingFallback() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = VoiceTodoError.ipRateLimited(retryAfter: 3_600)
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "save after IP limit", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["fallbackSaved"])
        XCTAssertEqual(events.first?.fallbackReason, .ipRateLimited(retryAfter: 3_600))
        XCTAssertEqual(store.rawTranscripts, ["save after IP limit"])
    }

    func testProcessOfflineSaveFailureEmitsOfflineSaveFailed() async {
        let store = TranscriptFlowTestStore()
        store.addRawError = VoiceTodoError.storageWriteFailed("disk full")
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: TranscriptFlowTestExtractor(),
            networkIsConnectedProvider: { false }
        )

        let events = await collectEvents(
            from: flow.process(text: "offline note", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["offlineSaveFailed"])
        XCTAssertEqual(store.rawTranscripts, ["offline note"])
    }

    /// 取消不是失败：不发事件，也**绝不能**离线兜底。
    ///
    /// 旧链路里取消经 `mapURLError` 的 `default:` 变成 `.networkUnavailable`，落到
    /// `.networkUnavailable` 分支走 saveOffline —— 用户主动取消却在库里多出一条 pending 转写，
    /// 下次回到前台被 PendingRecoveryFlow 认领、再扣一次配额。
    /// 本测试的 extractor 是同步 yield 的，`Task.isCancelled` 为 false，
    /// 因此它精确地钉住按错误类型的判断分支，而不是 Task.isCancelled 兜底。
    func testProcessCancellationEmitsNothingAndSavesNothing() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingError = CancellationError()
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "user cancelled this", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), [], "取消不该产生任何事件")
        XCTAssertTrue(store.rawTranscripts.isEmpty, "取消不该留下 pending 转写")
    }

    /// 取消发生在已收到 partial 之后：不得被 partial fallback 重新提升成 success，
    /// 否则用户刚关掉的确认弹层会被重新填满。
    func testProcessCancellationAfterPartialDoesNotEmitSuccess() async {
        let store = TranscriptFlowTestStore()
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [ExtractedTodo(title: "买牛奶")], ignored: "")
        ]
        extractor.streamingError = CancellationError()
        let flow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "cancel after partial", locale: Locale(identifier: "zh-Hans"), flowID: "flow", extractID: "extract")
        )

        XCTAssertFalse(events.map(\.name).contains("success"), "取消后不该再补一个 success")
        XCTAssertTrue(store.rawTranscripts.isEmpty, "取消不该留下 pending 转写")
    }

    private func collectEvents(from stream: AsyncStream<TranscriptFlowEvent>) async -> [ObservedTranscriptEvent] {
        var events: [ObservedTranscriptEvent] = []
        for await event in stream {
            events.append(ObservedTranscriptEvent(event))
        }
        return events
    }
}

private struct ObservedTranscriptEvent {
    let name: String
    let todoTitles: [String]
    var fallbackReason: VoiceTodoError?
    var manualReason: VoiceTodoError?

    init(_ event: TranscriptFlowEvent) {
        fallbackReason = nil
        manualReason = nil
        switch event {
        case .empty:
            name = "empty"
            todoTitles = []
        case .partial(let result):
            name = "partial"
            todoTitles = result.todos.map(\.title)
        case .success(let finalTodos):
            name = "success"
            todoTitles = finalTodos.map(\.title)
        case .offlineSaved:
            name = "offlineSaved"
            todoTitles = []
        case .offlineSaveFailed:
            name = "offlineSaveFailed"
            todoTitles = []
        case .fallbackSaved(_, let reason):
            name = "fallbackSaved"
            todoTitles = []
            fallbackReason = reason
        case .quotaFallbackSaved:
            name = "quotaFallbackSaved"
            todoTitles = []
        case .networkFallbackSaveFailed:
            name = "networkFallbackSaveFailed"
            todoTitles = []
        case .manualSaved(_, let reason):
            name = "manualSaved"
            todoTitles = []
            manualReason = reason
        case .manualSaveFailed:
            name = "manualSaveFailed"
            todoTitles = []
        }
    }
}

private final class TranscriptFlowTestExtractor: TodoExtractorProtocol {
    var streamingResults: [ExtractionResult] = []
    var streamingError: Error?

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        if let streamingError {
            throw streamingError
        }
        return streamingResults.last ?? ExtractionResult(
            todos: [ExtractedTodo(title: "extracted \(transcript)", detail: transcript)],
            ignored: ""
        )
    }

    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error> {
        let results = streamingResults
        let error = streamingError
        return AsyncThrowingStream { continuation in
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

@MainActor
private final class TranscriptFlowTestStore: PendingTranscriptCreating {
    var rawTranscripts: [String] = []
    var rawTranscriptLocales: [String?] = []
    var addRawError: Error?
    var manualTranscripts: [String] = []
    var manualTranscriptLocales: [String?] = []
    var manualAddError: Error?

    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        rawTranscripts.append(transcript)
        rawTranscriptLocales.append(localeIdentifier)
        if let addRawError {
            throw addRawError
        }
        return TodoItemData(
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: localeIdentifier
        )
    }

    func addManualUnparsedTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        manualTranscripts.append(transcript)
        manualTranscriptLocales.append(localeIdentifier)
        if let manualAddError {
            throw manualAddError
        }
        var todo = TodoItemData(
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: false,
            localeIdentifier: localeIdentifier
        )
        todo.extractionOutcome = .unparsed
        return todo
    }
}
