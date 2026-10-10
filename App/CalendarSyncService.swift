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
        // 顺序：先写新事件 → 成功后再删旧事件。
        // 反过来（先删后写）会在「删成功 + 写失败」时永久丢失日历事件且无法自愈
        // （store 里的 eventID 已被置 nil，下次编辑不会再触发 replace）。
        // 改成「先写后删」后：写新失败 → 旧事件保留，用户重试即可；
        // 写新成功 + 删旧失败 → 旧事件成孤儿留在日历，但不影响新 todo 呈现。

        guard shouldWriteNewEvent else {
            // appOnly 模式：用户切回不同步，只需清理旧镜像（不写新事件）
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
            return oldEventIdentifier == nil ? .skipped(.replace) : .success(.replace)
        }

        // 工作集窗口化后用 findTodo 查库,以命中窗口外的项(见 docs/completed-todos-performance.md Step 2)
        guard var updated = store.findTodo(by: todoID) else {
            VoiceTodoLog.calendar.warning("calendar.update.write_skipped todoID=\(todoID.uuidString, privacy: .public) reason=todo_missing sourceID=\(sourceID, privacy: .public)")
            return .skipped(.replace)
        }

        // 真实 writer 只写 systemCalendarEventIdentifier == nil 的待办(批量首写的
        // 幂等过滤,SystemCalendarWriter.writeEvents)。replace 语义是"删旧写新",
        // 待办此刻还带着旧标识,不过滤副本会被跳过 → 演变成"删旧不写新",镜像静默
        // 丢失且不自愈。这里在**副本**上清掉旧标识让新事件可写;成功后由
        // persistSystemCalendarResults 落新 ID,失败时 store 里的旧标识原样保留(可重试)。
        updated.systemCalendarEventIdentifier = nil
        let writeResult = await write(todos: [updated], sourceID: sourceID)
        if writeResult.status == .failed {
            // 写新失败：旧事件未动，store 里 oldEventIdentifier 也未变，下次编辑可重试
            return CalendarSyncResult(
                operation: .replace,
                status: .failed,
                shouldShowFailureToast: writeResult.shouldShowFailureToast,
                error: writeResult.error
            )
        }

        // 写新成功或被跳过后：现在安全地删旧事件。
        if let oldEventIdentifier {
            do {
                try await writer.removeEvents(identifiers: [oldEventIdentifier])
                VoiceTodoLog.calendar.info("calendar.update.removed_old_after_write todoID=\(todoID.uuidString, privacy: .public) eventID=\(oldEventIdentifier, privacy: .public)")
            } catch {
                VoiceTodoLog.calendar.warning("calendar.update.remove_old_failed_after_write todoID=\(todoID.uuidString, privacy: .public) eventID=\(oldEventIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                // 写新成功路径：删旧失败只容忍为孤儿旧事件（新镜像已就位、标识已是
                // 新 ID，不影响 todo 呈现），不失败。写新被跳过路径没有新事件兜底：
                // 旧事件此刻还活着（removeEvents 只对「存在但删不掉」抛错，missing
                // 不抛），若仍清空标识，活事件将永久失联成幽灵事件（且下次补日期会
                // 建出重复事件）——必须显式失败，保留标识供下次内容性编辑重试删。
                if writeResult.status == .skipped {
                    return .failed(.replace, error: error)
                }
            }
            // 写新被跳过（典型：编辑后草稿为 nil——删掉日期且无重复规则，无事件可写）
            // 且旧镜像已移除（删成功或本就 missing）：清空 store 里的旧标识。否则残留
            // 死 ID——它指向已删除的事件，后续每次内容性编辑都会带着它重跑一遍
            // 「删不存在的旧事件」。写新成功时不清：persistSystemCalendarResults 已落新标识。
            if writeResult.status == .skipped {
                do {
                    try store.updateSystemCalendarEventIdentifier(nil, for: todoID)
                    VoiceTodoLog.calendar.info("calendar.update.cleared_identifier_after_skip todoID=\(todoID.uuidString, privacy: .public)")
                } catch {
                    VoiceTodoLog.calendar.error("calendar.update.clear_identifier_failed todoID=\(todoID.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    return .failed(.replace, error: error)
                }
            }
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
