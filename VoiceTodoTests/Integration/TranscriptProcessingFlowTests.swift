import Combine
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

    func testProcessNoTodosEmitsNoTodos() async {
        let extractor = TranscriptFlowTestExtractor()
        extractor.streamingResults = [
            ExtractionResult(todos: [], ignored: "nothing")
        ]
        let flow = TranscriptProcessingFlow(
            store: TranscriptFlowTestStore(),
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let events = await collectEvents(
            from: flow.process(text: "just chatting", locale: Locale(identifier: "en-US"), flowID: "flow", extractID: "extract")
        )

        XCTAssertEqual(events.map(\.name), ["partial", "noTodos"])
    }

    func testProcessPartialThenFailureEmitsFailedAfterPartial() async {
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

        XCTAssertEqual(events.map(\.name), ["partial", "failed"])
        XCTAssertEqual(events.first?.todoTitles, ["partial todo"])
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

        XCTAssertEqual(events.map(\.name), ["networkFallbackSaved"])
        XCTAssertEqual(store.rawTranscripts, ["save this later"])
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

    init(_ event: TranscriptFlowEvent) {
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
        case .noTodos:
            name = "noTodos"
            todoTitles = []
        case .offlineSaved:
            name = "offlineSaved"
            todoTitles = []
        case .offlineSaveFailed:
            name = "offlineSaveFailed"
            todoTitles = []
        case .networkFallbackSaved:
            name = "networkFallbackSaved"
            todoTitles = []
        case .networkFallbackSaveFailed:
            name = "networkFallbackSaveFailed"
            todoTitles = []
        case .failed:
            name = "failed"
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
private final class TranscriptFlowTestStore: TodoStoreProtocol {
    @Published var todos: [TodoItemData] = []
    var rawTranscripts: [String] = []
    var addRawError: Error?

    func add(_ item: ExtractedTodo) throws {}
    func addBatch(_ items: [ExtractedTodo]) throws {}

    func addRawTranscript(_ transcript: String) throws {
        rawTranscripts.append(transcript)
        if let addRawError {
            throw addRawError
        }
    }

    func toggleComplete(_ id: UUID) throws {}
    func delete(_ id: UUID) throws {}
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws {}
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {}
    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws {}
    func calendarOccurrences(from startDate: Date, to endDate: Date) -> [TodoOccurrenceData] { [] }
    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {}
    func pendingItems() -> [TodoItemData] { [] }
    func recentUncompleted(limit: Int) -> [TodoItemData] { [] }
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws {}
    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?) throws {}
    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {}
    func reorder(ids: [UUID]) throws {}
    func refreshTodos() {}
}
