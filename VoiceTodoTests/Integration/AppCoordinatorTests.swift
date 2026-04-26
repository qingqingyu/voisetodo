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

    init(todos: [TodoItemData]) {
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

    func reorder(ids: [UUID]) throws {}

    func refreshTodos() {}
}
