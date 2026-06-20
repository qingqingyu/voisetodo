import XCTest
@testable import VoiceTodo

@MainActor
final class CalendarSyncServiceTests: XCTestCase {
    func testWritePersistsSystemCalendarIdentifiers() async {
        let item = TodoItemData(title: "写入日历", dueHint: "今天", dueDate: Date())
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter()
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueWrite(todos: [item], sourceID: "test-write").value

        XCTAssertEqual(result.status, .success)
        XCTAssertFalse(result.shouldShowFailureToast)
        XCTAssertEqual(writer.receivedTodos.map(\.id), [item.id])
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    func testWritePersistsPartialResultsWhenWriterFails() async {
        let item1 = TodoItemData(title: "部分成功", dueHint: "今天", dueDate: Date())
        let item2 = TodoItemData(title: "部分失败", dueHint: "明天", dueDate: Date())
        let partial = SystemCalendarWriteResult(todoId: item1.id, eventIdentifier: "event-partial")
        let store = CalendarSyncTestStore(todos: [item1, item2])
        let writer = CalendarSyncTestWriter(
            writeError: SystemCalendarWriteError(
                results: [partial],
                underlyingError: VoiceTodoError.storageWriteFailed("calendar failed")
            )
        )
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueWrite(todos: [item1, item2], sourceID: "test-partial").value

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.shouldShowFailureToast)
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item1.id], "event-partial")
        XCTAssertNil(store.systemCalendarEventIdentifiers[item2.id])
    }

    func testWriteRollsBackCreatedEventsWhenIdentifierPersistenceFails() async {
        let item = TodoItemData(title: "回滚日历", dueHint: "今天", dueDate: Date())
        let store = CalendarSyncTestStore(todos: [item])
        store.identifierUpdateError = VoiceTodoError.storageWriteFailed("identifier failed")
        let writer = CalendarSyncTestWriter()
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueWrite(todos: [item], sourceID: "test-rollback").value

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.shouldShowFailureToast)
        XCTAssertEqual(writer.removedIdentifiers, ["event-\(item.id.uuidString)"])
        XCTAssertNil(store.systemCalendarEventIdentifiers[item.id])
    }

    func testDeleteRemovesExistingSystemCalendarEvent() async {
        let store = CalendarSyncTestStore()
        let writer = CalendarSyncTestWriter()
        let service = CalendarSyncService(store: store, writer: writer)
        let todoID = UUID()

        let result = await service.enqueueDelete(todoID: todoID, eventIdentifier: "event-old").value

        XCTAssertEqual(result.status, .success)
        XCTAssertFalse(result.shouldShowFailureToast)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
    }

    func testReplaceRemovesOldEventAndWritesNewEvent() async {
        var item = TodoItemData(title: "替换日历", dueHint: "后天", dueDate: Date())
        item.systemCalendarEventIdentifier = "event-old"
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter()
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueReplace(
            todoID: item.id,
            oldEventIdentifier: "event-old",
            shouldWriteNewEvent: true,
            sourceID: "test-replace"
        ).value

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        XCTAssertEqual(writer.receivedTodos.map(\.id), [item.id])
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    func testReplaceStopsWhenOldEventRemovalFails() async {
        var item = TodoItemData(title: "移除失败", dueHint: "今天", dueDate: Date())
        item.systemCalendarEventIdentifier = "event-old"
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter(removeError: VoiceTodoError.storageWriteFailed("remove failed"))
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueReplace(
            todoID: item.id,
            oldEventIdentifier: "event-old",
            shouldWriteNewEvent: true,
            sourceID: "test-remove-failed"
        ).value

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.shouldShowFailureToast)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        XCTAssertTrue(writer.receivedTodos.isEmpty)
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-old")
    }
}

@MainActor
private final class CalendarSyncTestStore: CalendarSyncTodoStore {
    @Published var todos: [TodoItemData]
    var systemCalendarEventIdentifiers: [UUID: String] = [:]
    var identifierUpdateError: Error?

    init(todos: [TodoItemData] = []) {
        self.todos = todos
        self.systemCalendarEventIdentifiers = Dictionary(
            uniqueKeysWithValues: todos.compactMap { todo in
                todo.systemCalendarEventIdentifier.map { (todo.id, $0) }
            }
        )
    }

    func updateSystemCalendarEventIdentifier(_ eventIdentifier: String?, for id: UUID) throws {
        if let identifierUpdateError {
            throw identifierUpdateError
        }
        systemCalendarEventIdentifiers[id] = eventIdentifier
    }
}

private final class CalendarSyncTestWriter: SystemCalendarWritingProtocol {
    var receivedTodos: [TodoItemData] = []
    var removedIdentifiers: [String] = []
    let writeError: Error?
    let removeError: Error?

    init(writeError: Error? = nil, removeError: Error? = nil) {
        self.writeError = writeError
        self.removeError = removeError
    }

    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult] {
        receivedTodos.append(contentsOf: todos)
        if let writeError {
            throw writeError
        }
        return todos.map {
            SystemCalendarWriteResult(todoId: $0.id, eventIdentifier: "event-\($0.id.uuidString)")
        }
    }

    func removeEvents(identifiers: [String]) async throws {
        removedIdentifiers.append(contentsOf: identifiers)
        if let removeError {
            throw removeError
        }
    }
}
