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

    /// 写新事件失败时，旧事件必须保留、store identifier 不变 —— Risk 2 的核心保护。
    /// 旧逻辑（先删后写）会在「删成功 + 写失败」时永久丢事件，新逻辑（先写后删）规避此问题。
    func testReplacePreservesOldEventWhenWriteFails() async {
        var item = TodoItemData(title: "写新失败", dueHint: "今天", dueDate: Date())
        item.systemCalendarEventIdentifier = "event-old"
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter(writeError: VoiceTodoError.storageWriteFailed("write failed"))
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueReplace(
            todoID: item.id,
            oldEventIdentifier: "event-old",
            shouldWriteNewEvent: true,
            sourceID: "test-write-failed"
        ).value

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.shouldShowFailureToast)
        XCTAssertTrue(writer.removedIdentifiers.isEmpty, "写新失败时不应触碰旧事件")
        XCTAssertEqual(writer.receivedTodos.map(\.id), [item.id], "写新流程应被尝试")
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-old", "store identifier 必须保留以便重试")
    }

    /// 写新成功 + 删旧失败 → 整体 success（新事件已就位），旧事件成孤儿但不影响新 todo 呈现。
    func testReplaceSucceedsWhenOldEventCleanupFailsAfterWrite() async {
        var item = TodoItemData(title: "清理失败", dueHint: "今天", dueDate: Date())
        item.systemCalendarEventIdentifier = "event-old"
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter(removeError: VoiceTodoError.storageWriteFailed("remove failed"))
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueReplace(
            todoID: item.id,
            oldEventIdentifier: "event-old",
            shouldWriteNewEvent: true,
            sourceID: "test-cleanup-failed"
        ).value

        XCTAssertEqual(result.status, .success, "新事件已写入，整体应判定成功")
        XCTAssertEqual(writer.receivedTodos.map(\.id), [item.id])
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"], "应尝试清理旧事件")
        XCTAssertEqual(store.systemCalendarEventIdentifiers[item.id], "event-\(item.id.uuidString)")
    }

    /// appOnly 模式（shouldWriteNewEvent=false）：只清理旧事件镜像，不写新事件。
    /// 用户切回不同步模式后编辑 todo 触发此分支。
    func testReplaceInAppOnlyModeOnlyRemovesOldEvent() async {
        var item = TodoItemData(title: "切模式清理", dueHint: "今天", dueDate: Date())
        item.systemCalendarEventIdentifier = "event-old"
        let store = CalendarSyncTestStore(todos: [item])
        let writer = CalendarSyncTestWriter()
        let service = CalendarSyncService(store: store, writer: writer)

        let result = await service.enqueueReplace(
            todoID: item.id,
            oldEventIdentifier: "event-old",
            shouldWriteNewEvent: false,
            sourceID: "test-app-only"
        ).value

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(writer.removedIdentifiers, ["event-old"])
        XCTAssertTrue(writer.receivedTodos.isEmpty, "appOnly 模式不应写新事件")
        XCTAssertNil(store.systemCalendarEventIdentifiers[item.id])
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
