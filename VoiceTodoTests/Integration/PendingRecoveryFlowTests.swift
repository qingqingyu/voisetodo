import Combine
import XCTest
@testable import VoiceTodo

@MainActor
final class PendingRecoveryFlowTests: XCTestCase {
    func testRecoverDeletesPendingWithoutRawTranscript() async {
        let pendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            TodoItemData(id: pendingID, title: "orphan", needsAIProcessing: true)
        ])
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: PendingRecoveryTestExtractor(),
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.pendingCount, 1)
        XCTAssertEqual(store.deletedIds, [pendingID])
        XCTAssertEqual(result.deletedInvalidPendingIds, [pendingID])
        XCTAssertTrue(result.extractedTodos.isEmpty)
        XCTAssertTrue(result.deletionErrors.isEmpty)
    }

    func testRecoverKeepsPendingWhenExtractionFails() async {
        let pendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: pendingID, transcript: "failed pending")
        ])
        let extractor = PendingRecoveryTestExtractor()
        extractor.results["failed pending"] = .failure(VoiceTodoError.apiResponseInvalid("broken"))
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.failedPendingRecoveries.map(\.pendingId), [pendingID])
        XCTAssertEqual(result.failedPendingRecoveries.first?.error, .apiResponseInvalid("broken"))
        XCTAssertTrue(result.processedWithTodosIds.isEmpty)
        XCTAssertTrue(result.processedWithoutTodosIds.isEmpty)
        XCTAssertEqual(store.pendingItems().map(\.id), [pendingID])
        XCTAssertTrue(store.deletedIds.isEmpty)
    }

    func testRecoverPreservesPendingOrderWhenExtractionsFinishOutOfOrder() async {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: firstID, transcript: "first"),
            Self.pendingTodo(id: secondID, transcript: "second"),
            Self.pendingTodo(id: thirdID, transcript: "third")
        ])
        let extractor = PendingRecoveryTestExtractor()
        extractor.delays = [
            "first": 120_000_000,
            "second": 20_000_000,
            "third": 5_000_000
        ]
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.processedWithTodosIds, [firstID, secondID, thirdID])
        XCTAssertEqual(result.extractedTodos.map(\.title), ["extracted first", "extracted second", "extracted third"])
        XCTAssertEqual(result.mergedRawTranscript, "first\n---\nsecond\n---\nthird")
    }

    func testRecoverMapsExtractedTodoIdsBackToEachPendingItem() async {
        let firstID = UUID()
        let secondID = UUID()
        let firstTodoID = UUID()
        let secondTodoID = UUID()
        let thirdTodoID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: firstID, transcript: "first"),
            Self.pendingTodo(id: secondID, transcript: "second")
        ])
        let extractor = PendingRecoveryTestExtractor()
        extractor.results["first"] = .success(ExtractionResult(
            todos: [
                ExtractedTodo(id: firstTodoID, title: "first one"),
                ExtractedTodo(id: secondTodoID, title: "first two")
            ],
            ignored: ""
        ))
        extractor.results["second"] = .success(ExtractionResult(
            todos: [
                ExtractedTodo(id: thirdTodoID, title: "second one")
            ],
            ignored: ""
        ))
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.extractedTodoIdsByPendingId[firstID], [firstTodoID, secondTodoID])
        XCTAssertEqual(result.extractedTodoIdsByPendingId[secondID], [thirdTodoID])
    }

    func testRecoverUsesPendingLocaleWhenAvailable() async {
        let pendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: pendingID, transcript: "english pending", localeIdentifier: "en-US")
        ])
        let extractor = PendingRecoveryTestExtractor()
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        _ = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(extractor.locales, ["en-US"])
    }

    func testRecoverAnnotatesExtractedTodosWithEachPendingLocale() async {
        let englishPendingID = UUID()
        let chinesePendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: englishPendingID, transcript: "english pending", localeIdentifier: "en-US"),
            Self.pendingTodo(id: chinesePendingID, transcript: "中文 pending", localeIdentifier: "zh-Hans")
        ])
        let extractor = PendingRecoveryTestExtractor()
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "ja-JP"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.extractedTodos.map(\.localeIdentifier), ["en-US", "zh-Hans"])
    }

    func testRecoverFallsBackToCurrentLocaleForOldPendingWithoutLocale() async {
        let pendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: pendingID, transcript: "old pending")
        ])
        let extractor = PendingRecoveryTestExtractor()
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        _ = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(extractor.locales, ["zh-Hans"])
    }

    func testRecoverReportsSuccessfulPendingWithoutTodos() async {
        let pendingID = UUID()
        let store = PendingRecoveryTestStore(todos: [
            Self.pendingTodo(id: pendingID, transcript: "nothing actionable")
        ])
        let extractor = PendingRecoveryTestExtractor()
        extractor.results["nothing actionable"] = .success(ExtractionResult(todos: [], ignored: "nothing"))
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: { true }
        )

        let result = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertEqual(result.processedWithoutTodosIds, [pendingID])
        XCTAssertTrue(result.extractedTodos.isEmpty)
        XCTAssertNil(result.mergedRawTranscript)
        XCTAssertEqual(store.pendingItems().map(\.id), [pendingID])
    }

    func testRecoverStopsSchedulingNewPendingWhenNetworkDrops() async {
        let items = (1...4).map { index in
            Self.pendingTodo(id: UUID(), transcript: "pending \(index)")
        }
        let store = PendingRecoveryTestStore(todos: items)
        let extractor = PendingRecoveryTestExtractor()
        var connectivityChecks = 0
        let flow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: {
                connectivityChecks += 1
                return false
            }
        )

        _ = await flow.recover(
            dismissedPendingIds: [],
            locale: Locale(identifier: "zh-Hans"),
            flowID: "test-pending"
        )

        XCTAssertGreaterThanOrEqual(connectivityChecks, 1)
        XCTAssertFalse(extractor.transcripts.contains("pending 4"))
    }

    private static func pendingTodo(id: UUID, transcript: String, localeIdentifier: String? = nil) -> TodoItemData {
        TodoItemData(
            id: id,
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: localeIdentifier
        )
    }
}

private final class PendingRecoveryTestExtractor: TodoExtractorProtocol {
    enum Result {
        case success(ExtractionResult)
        case failure(Error)
    }

    var results: [String: Result] = [:]
    var delays: [String: UInt64] = [:]
    private let lock = NSLock()
    private var recordedTranscripts: [String] = []
    private var recordedLocales: [String] = []

    var transcripts: [String] {
        lock.withLock { recordedTranscripts }
    }

    var locales: [String] {
        lock.withLock { recordedLocales }
    }

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        lock.withLock {
            recordedTranscripts.append(transcript)
            recordedLocales.append(locale.identifier)
        }
        if let delay = delays[transcript] {
            try await Task.sleep(nanoseconds: delay)
        }
        switch results[transcript] {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .none:
            return ExtractionResult(
                todos: [ExtractedTodo(title: "extracted \(transcript)", detail: transcript)],
                ignored: ""
            )
        }
    }
}

@MainActor
private final class PendingRecoveryTestStore: PendingRecoveryTodoStore {
    @Published var todos: [TodoItemData]
    var deletedIds: [UUID] = []
    var deleteErrorIds: Set<UUID> = []

    init(todos: [TodoItemData] = []) {
        self.todos = todos
    }

    func add(_ item: ExtractedTodo) throws {}
    func addBatch(_ items: [ExtractedTodo]) throws {}
    func addBatch(_ items: [ExtractedTodo], localeIdentifier: String?) throws {}
    func addRawTranscript(_ transcript: String, localeIdentifier: String?) throws -> TodoItemData {
        TodoItemData(
            title: transcript,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true,
            localeIdentifier: localeIdentifier
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

    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws {}
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?, recurrenceRule: RecurrenceRule?) throws {}
    func updateRecurrence(_ id: UUID, recurrenceRule: RecurrenceRule?) throws {}
    func calendarOccurrences(from startDate: Date, to endDate: Date) -> [TodoOccurrenceData] { [] }
    func toggleOccurrenceComplete(_ id: UUID, on date: Date) throws {}
    func pendingItems() -> [TodoItemData] { todos.filter(\.needsAIProcessing) }
    func recentUncompleted(limit: Int) -> [TodoItemData] { [] }
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws {}
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?, localeIdentifier: String?) throws {}
    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?) throws {}
    func replacePendingBatchWithExtracted(_ pendingIds: [UUID], _ items: [ExtractedTodo], rawTranscript: String?, localeIdentifier: String?) throws {}
    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {}
    func reorder(ids: [UUID]) throws {}
    func refreshTodos() {}
}
