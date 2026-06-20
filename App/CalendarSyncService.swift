import Foundation

enum CalendarSyncOperation: Equatable {
    case write
    case delete
    case replace
}

enum CalendarSyncStatus: Equatable {
    case success
    case skipped
    case failed
}

struct CalendarSyncResult {
    let operation: CalendarSyncOperation
    let status: CalendarSyncStatus
    let shouldShowFailureToast: Bool
    let error: Error?

    static func success(_ operation: CalendarSyncOperation) -> CalendarSyncResult {
        CalendarSyncResult(
            operation: operation,
            status: .success,
            shouldShowFailureToast: false,
            error: nil
        )
    }

    static func skipped(_ operation: CalendarSyncOperation) -> CalendarSyncResult {
        CalendarSyncResult(
            operation: operation,
            status: .skipped,
            shouldShowFailureToast: false,
            error: nil
        )
    }

    static func failed(_ operation: CalendarSyncOperation, error: Error) -> CalendarSyncResult {
        CalendarSyncResult(
            operation: operation,
            status: .failed,
            shouldShowFailureToast: true,
            error: error
        )
    }
}

@MainActor
final class CalendarSyncService {
    private let store: any CalendarSyncTodoStore
    private let writer: any SystemCalendarWritingProtocol
    private var previousTask: Task<CalendarSyncResult, Never>?

    init(
        store: any CalendarSyncTodoStore,
        writer: any SystemCalendarWritingProtocol
    ) {
        self.store = store
        self.writer = writer
    }

    func enqueueWrite(todos: [TodoItemData], sourceID: String) -> Task<CalendarSyncResult, Never> {
        enqueue(operation: .write) {
            await self.write(todos: todos, sourceID: sourceID)
        }
    }

    func enqueueDelete(
        todoID: UUID,
        eventIdentifier: String
    ) -> Task<CalendarSyncResult, Never> {
        enqueue(operation: .delete) {
            await self.delete(todoID: todoID, eventIdentifier: eventIdentifier)
        }
    }

    func enqueueReplace(
        todoID: UUID,
        oldEventIdentifier: String?,
        shouldWriteNewEvent: Bool,
        sourceID: String
    ) -> Task<CalendarSyncResult, Never> {
        enqueue(operation: .replace) {
            await self.replace(
                todoID: todoID,
                oldEventIdentifier: oldEventIdentifier,
                shouldWriteNewEvent: shouldWriteNewEvent,
                sourceID: sourceID
            )
        }
    }

    private func enqueue(
        operation: CalendarSyncOperation,
        perform: @escaping @MainActor () async -> CalendarSyncResult
    ) -> Task<CalendarSyncResult, Never> {
        let previousTask = previousTask
        let task = Task { @MainActor in
            _ = await previousTask?.value
            return await perform()
        }
        self.previousTask = task
        VoiceTodoLog.calendar.debug("calendar.queue.enqueued operation=\(String(describing: operation), privacy: .public)")
        return task
    }

    private func write(todos: [TodoItemData], sourceID: String) async -> CalendarSyncResult {
        let syncID = VoiceTodoLog.makeID("calendar")
        let startedAt = Date()
        VoiceTodoLog.calendar.info("calendar.sync.start id=\(syncID, privacy: .public) sourceID=\(sourceID, privacy: .public) todoCount=\(todos.count) todoIDs=\(VoiceTodoLog.idsSummary(todos.map(\.id)), privacy: .public)")
        do {
            let results = try await writer.writeEvents(for: todos)
            try await persistSystemCalendarResults(results)
            VoiceTodoLog.calendar.info("calendar.sync.success id=\(syncID, privacy: .public) sourceID=\(sourceID, privacy: .public) resultCount=\(results.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return results.isEmpty ? .skipped(.write) : .success(.write)
        } catch let partialError as SystemCalendarWriteError {
            VoiceTodoLog.calendar.error("calendar.sync.partial_failed id=\(syncID, privacy: .public) sourceID=\(sourceID, privacy: .public) partialResults=\(partialError.results.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(partialError), privacy: .public)")
            do {
                try await persistSystemCalendarResults(partialError.results)
            } catch {
                VoiceTodoLog.calendar.error("calendar.sync.persist_partial_failed id=\(syncID, privacy: .public) sourceID=\(sourceID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
            return .failed(.write, error: partialError.underlyingError)
        } catch {
            VoiceTodoLog.calendar.error("calendar.sync.failed id=\(syncID, privacy: .public) sourceID=\(sourceID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .failed(.write, error: error)
        }
    }

    private func delete(todoID: UUID, eventIdentifier: String) async -> CalendarSyncResult {
        let startedAt = Date()
        do {
            try await writer.removeEvents(identifiers: [eventIdentifier])
            VoiceTodoLog.calendar.info("calendar.delete.success todoID=\(todoID.uuidString, privacy: .public) eventID=\(eventIdentifier, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return .success(.delete)
        } catch {
            VoiceTodoLog.calendar.error("calendar.delete.failed todoID=\(todoID.uuidString, privacy: .public) eventID=\(eventIdentifier, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .failed(.delete, error: error)
        }
    }

    private func replace(
        todoID: UUID,
        oldEventIdentifier: String?,
        shouldWriteNewEvent: Bool,
        sourceID: String
    ) async -> CalendarSyncResult {
        if let oldEventIdentifier {
            do {
                try await writer.removeEvents(identifiers: [oldEventIdentifier])
                try store.updateSystemCalendarEventIdentifier(nil, for: todoID)
                VoiceTodoLog.calendar.info("calendar.update.removed_old todoID=\(todoID.uuidString, privacy: .public) eventID=\(oldEventIdentifier, privacy: .public)")
            } catch {
                VoiceTodoLog.calendar.error("calendar.update.remove_old_failed todoID=\(todoID.uuidString, privacy: .public) eventID=\(oldEventIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                return .failed(.replace, error: error)
            }
        }

        guard shouldWriteNewEvent else {
            return oldEventIdentifier == nil ? .skipped(.replace) : .success(.replace)
        }

        guard let updated = store.todos.first(where: { $0.id == todoID }) else {
            VoiceTodoLog.calendar.warning("calendar.update.write_skipped todoID=\(todoID.uuidString, privacy: .public) reason=todo_missing sourceID=\(sourceID, privacy: .public)")
            return .skipped(.replace)
        }

        let writeResult = await write(todos: [updated], sourceID: sourceID)
        if writeResult.status == .failed {
            return CalendarSyncResult(
                operation: .replace,
                status: .failed,
                shouldShowFailureToast: writeResult.shouldShowFailureToast,
                error: writeResult.error
            )
        }
        return CalendarSyncResult(
            operation: .replace,
            status: writeResult.status,
            shouldShowFailureToast: false,
            error: nil
        )
    }

    private func persistSystemCalendarResults(_ results: [SystemCalendarWriteResult]) async throws {
        var failedResults: [SystemCalendarWriteResult] = []

        for result in results {
            do {
                try store.updateSystemCalendarEventIdentifier(result.eventIdentifier, for: result.todoId)
                VoiceTodoLog.calendar.info("calendar.persist_identifier.success todoID=\(result.todoId.uuidString, privacy: .public) eventID=\(result.eventIdentifier, privacy: .public)")
            } catch {
                failedResults.append(result)
                VoiceTodoLog.calendar.error("calendar.persist_identifier.failed todoID=\(result.todoId.uuidString, privacy: .public) eventID=\(result.eventIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }

        guard !failedResults.isEmpty else { return }

        do {
            try await writer.removeEvents(identifiers: failedResults.map(\.eventIdentifier))
        } catch {
            VoiceTodoLog.calendar.error("calendar.cleanup_after_persist_failed failedCount=\(failedResults.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }

        throw VoiceTodoError.storageWriteFailed("Failed to persist system calendar event identifier")
    }
}
