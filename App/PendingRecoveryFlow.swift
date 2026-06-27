import Foundation

struct PendingRecoveryResult {
    let pendingCount: Int
    let processedWithTodosIds: [UUID]
    let processedWithoutTodosIds: [UUID]
    let deletedInvalidPendingIds: [UUID]
    let failedPendingRecoveries: [PendingRecoveryFailure]
    let extractedTodos: [ExtractedTodo]
    let extractedTodoIdsByPendingId: [UUID: [UUID]]
    let mergedRawTranscript: String?
    let deletionErrors: [Error]
    /// 本次恢复流程启动时读取 pending 列表的错误。
    /// 非 nil 表示本次根本没进恢复循环（pending 读失败），调用方应通过 handleError 透出给用户。
    let pendingReadError: Error?

    var hasPending: Bool {
        pendingCount > 0
    }

    var failedCount: Int {
        failedPendingRecoveries.count
    }
}

struct PendingRecoveryFailure: Sendable {
    let pendingId: UUID
    let error: VoiceTodoError
}

@MainActor
final class PendingRecoveryFlow {
    private let store: any PendingRecoveryTodoStore
    private let extractor: any TodoExtractorProtocol
    private let networkIsConnectedProvider: @MainActor () -> Bool

    init(
        store: any PendingRecoveryTodoStore,
        extractor: any TodoExtractorProtocol,
        networkIsConnectedProvider: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.extractor = extractor
        self.networkIsConnectedProvider = networkIsConnectedProvider
    }

    func recover(
        dismissedPendingIds: Set<UUID>,
        locale: Locale,
        flowID: String
    ) async -> PendingRecoveryResult {
        let startedAt = Date()
        // pending 读取失败时把错误包进 result 透出给调用方（AppCoordinator 会通过 handleError 弹 toast），
        // 而不是在这里静默返回 .empty —— 后者会让用户对读失败毫无感知。
        // 下次回前台仍会重试，所以这里直接 short-circuit 返回，不继续恢复循环。
        let rawPendingItems: [TodoItemData]
        do {
            rawPendingItems = try await store.pendingItems()
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.foreground.pending_read_failed id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return PendingRecoveryResult(
                pendingCount: 0,
                processedWithTodosIds: [],
                processedWithoutTodosIds: [],
                deletedInvalidPendingIds: [],
                failedPendingRecoveries: [],
                extractedTodos: [],
                extractedTodoIdsByPendingId: [:],
                mergedRawTranscript: nil,
                deletionErrors: [],
                pendingReadError: error
            )
        }
        let pendingItems = rawPendingItems.filter { !dismissedPendingIds.contains($0.id) }
        guard !pendingItems.isEmpty else {
            VoiceTodoLog.coordinator.debug("coordinator.foreground.no_pending dismissedCount=\(dismissedPendingIds.count)")
            return PendingRecoveryResult.empty
        }

        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_start id=\(flowID, privacy: .public) pending=\(VoiceTodoLog.idsSummary(pendingItems.map(\.id)), privacy: .public) dismissedCount=\(dismissedPendingIds.count)")

        var deletionErrors: [Error] = []
        var deletedInvalidPendingIds: [UUID] = []
        let validPending = pendingItems.filter { item in
            if item.rawTranscript == nil {
                VoiceTodoLog.coordinator.warning("coordinator.foreground.pending_missing_raw id=\(flowID, privacy: .public) pendingID=\(item.id.uuidString, privacy: .public)")
                do {
                    try store.delete(item.id)
                    deletedInvalidPendingIds.append(item.id)
                    VoiceTodoLog.coordinator.info("coordinator.pending.delete_processed id=\(item.id.uuidString, privacy: .public)")
                } catch {
                    deletionErrors.append(error)
                    VoiceTodoLog.coordinator.error("coordinator.pending.delete_processed_failed id=\(item.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                }
                return false
            }
            return true
        }

        let concurrency = NetworkConfig.pendingBatchConcurrency
        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_window id=\(flowID, privacy: .public) validCount=\(validPending.count) concurrency=\(concurrency)")

        var processResults: [PendingProcessResult] = []
        await withTaskGroup(of: PendingProcessResult.self) { group in
            var iterator = validPending.enumerated().makeIterator()
            var activeCount = 0

            while activeCount < concurrency, let (index, pending) = iterator.next() {
                addPendingTask(
                    group: &group,
                    index: index,
                    pending: pending,
                    fallbackLocale: locale,
                    flowID: flowID
                )
                activeCount += 1
            }

            for await result in group {
                processResults.append(result)

                if let (index, next) = iterator.next() {
                    guard networkIsConnectedProvider() else { break }
                    addPendingTask(
                        group: &group,
                        index: index,
                        pending: next,
                        fallbackLocale: locale,
                        flowID: flowID
                    )
                }
            }
        }

        let successfulResults = processResults
            .filter(\.succeeded)
            .sorted { $0.index < $1.index }
        let resultsWithTodos = successfulResults.filter { !$0.todos.isEmpty }
        let resultsWithoutTodos = successfulResults.filter { $0.todos.isEmpty }
        let failedResults = processResults
            .filter { !$0.succeeded }
            .sorted { $0.index < $1.index }
        let failedPendingRecoveries = failedResults.compactMap { result in
            result.error.map { PendingRecoveryFailure(pendingId: result.id, error: $0) }
        }
        let extractedTodos = resultsWithTodos.flatMap(\.todos)
        let extractedTodoIdsByPendingId = Dictionary(
            uniqueKeysWithValues: resultsWithTodos.map { result in
                (result.id, result.todos.map(\.id))
            }
        )
        let rawTranscripts = resultsWithTodos.compactMap(\.rawTranscript)
        let mergedRawTranscript = rawTranscripts.isEmpty ? nil : rawTranscripts.joined(separator: "\n---\n")
        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_recovered id=\(flowID, privacy: .public) extractedCount=\(extractedTodos.count) processedWithTodos=\(resultsWithTodos.count) processedWithoutTodos=\(resultsWithoutTodos.count) failed=\(failedPendingRecoveries.count) deleteErrors=\(deletionErrors.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

        return PendingRecoveryResult(
            pendingCount: pendingItems.count,
            processedWithTodosIds: resultsWithTodos.map(\.id),
            processedWithoutTodosIds: resultsWithoutTodos.map(\.id),
            deletedInvalidPendingIds: deletedInvalidPendingIds,
            failedPendingRecoveries: failedPendingRecoveries,
            extractedTodos: extractedTodos,
            extractedTodoIdsByPendingId: extractedTodoIdsByPendingId,
            mergedRawTranscript: mergedRawTranscript,
            deletionErrors: deletionErrors,
            pendingReadError: nil
        )
    }

    private func addPendingTask(
        group: inout TaskGroup<PendingProcessResult>,
        index: Int,
        pending: TodoItemData,
        fallbackLocale: Locale,
        flowID: String
    ) {
        let transcript = pending.rawTranscript ?? ""
        let pendingId = pending.id
        // 防御空串：旧数据可能写入空字符串而非 nil，Locale(identifier: "") 会退化成根 locale。
        let locale = (pending.localeIdentifier.flatMap { $0.isEmpty ? nil : Locale(identifier: $0) }) ?? fallbackLocale
        let ext = extractor
        group.addTask {
            await Self.processSinglePending(
                index: index,
                id: pendingId,
                transcript: transcript,
                extractor: ext,
                locale: locale,
                flowID: flowID
            )
        }
    }

    private struct PendingProcessResult: Sendable {
        let index: Int
        let id: UUID
        let todos: [ExtractedTodo]
        let rawTranscript: String?
        let succeeded: Bool
        let error: VoiceTodoError?
    }

    private static func processSinglePending(
        index: Int,
        id: UUID,
        transcript: String,
        extractor: any TodoExtractorProtocol,
        locale: Locale,
        flowID: String
    ) async -> PendingProcessResult {
        let startedAt = Date()
        let extractID = VoiceTodoLog.makeID("extract")
        VoiceTodoLog.coordinator.info("coordinator.pending_item.start id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) locale=\(locale.identifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            let result = try await VoiceTodoLog.$extractID.withValue(extractID) {
                try await extractor.extract(from: transcript, locale: locale)
            }
            let localizedTodos = result.todos.map { todo in
                var localized = todo
                localized.localeIdentifier = locale.identifier
                return localized
            }
            VoiceTodoLog.coordinator.info("coordinator.pending_item.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) todos=\(result.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return PendingProcessResult(index: index, id: id, todos: localizedTodos, rawTranscript: transcript, succeeded: true, error: nil)
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.pending_item.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return PendingProcessResult(
                index: index,
                id: id,
                todos: [],
                rawTranscript: transcript,
                succeeded: false,
                error: Self.normalizedVoiceTodoError(error)
            )
        }
    }

    private static func normalizedVoiceTodoError(_ error: Error) -> VoiceTodoError {
        if let voiceError = error as? VoiceTodoError {
            return voiceError
        }
        return .apiResponseInvalid(error.localizedDescription)
    }
}

private extension PendingRecoveryResult {
    static var empty: PendingRecoveryResult {
        PendingRecoveryResult(
            pendingCount: 0,
            processedWithTodosIds: [],
            processedWithoutTodosIds: [],
            deletedInvalidPendingIds: [],
            failedPendingRecoveries: [],
            extractedTodos: [],
            extractedTodoIdsByPendingId: [:],
            mergedRawTranscript: nil,
            deletionErrors: [],
            pendingReadError: nil
        )
    }
}
