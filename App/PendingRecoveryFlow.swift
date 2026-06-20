import Foundation

struct PendingRecoveryResult {
    let pendingCount: Int
    let processedWithTodosIds: [UUID]
    let processedWithoutTodosIds: [UUID]
    let extractedTodos: [ExtractedTodo]
    let mergedRawTranscript: String?
    let failedCount: Int
    let deletionErrors: [Error]

    var hasPending: Bool {
        pendingCount > 0
    }
}

@MainActor
final class PendingRecoveryFlow {
    private let store: any TodoStoreProtocol
    private let extractor: any TodoExtractorProtocol
    private let networkIsConnectedProvider: @MainActor () -> Bool

    init(
        store: any TodoStoreProtocol,
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
        let pendingItems = store.pendingItems().filter { !dismissedPendingIds.contains($0.id) }
        guard !pendingItems.isEmpty else {
            VoiceTodoLog.coordinator.debug("coordinator.foreground.no_pending dismissedCount=\(dismissedPendingIds.count)")
            return PendingRecoveryResult.empty
        }

        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_start id=\(flowID, privacy: .public) pending=\(VoiceTodoLog.idsSummary(pendingItems.map(\.id)), privacy: .public) dismissedCount=\(dismissedPendingIds.count)")

        var deletionErrors: [Error] = []
        let validPending = pendingItems.filter { item in
            if item.rawTranscript == nil {
                VoiceTodoLog.coordinator.warning("coordinator.foreground.pending_missing_raw id=\(flowID, privacy: .public) pendingID=\(item.id.uuidString, privacy: .public)")
                do {
                    try store.delete(item.id)
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
                    locale: locale,
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
                        locale: locale,
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
        let extractedTodos = resultsWithTodos.flatMap(\.todos)
        let rawTranscripts = resultsWithTodos.compactMap(\.rawTranscript)
        let mergedRawTranscript = rawTranscripts.isEmpty ? nil : rawTranscripts.joined(separator: "\n---\n")
        let failedCount = processResults.filter { !$0.succeeded }.count

        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_recovered id=\(flowID, privacy: .public) extractedCount=\(extractedTodos.count) processedWithTodos=\(resultsWithTodos.count) processedWithoutTodos=\(resultsWithoutTodos.count) failed=\(failedCount) deleteErrors=\(deletionErrors.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

        return PendingRecoveryResult(
            pendingCount: pendingItems.count,
            processedWithTodosIds: resultsWithTodos.map(\.id),
            processedWithoutTodosIds: resultsWithoutTodos.map(\.id),
            extractedTodos: extractedTodos,
            mergedRawTranscript: mergedRawTranscript,
            failedCount: failedCount,
            deletionErrors: deletionErrors
        )
    }

    private func addPendingTask(
        group: inout TaskGroup<PendingProcessResult>,
        index: Int,
        pending: TodoItemData,
        locale: Locale,
        flowID: String
    ) {
        let transcript = pending.rawTranscript ?? ""
        let pendingId = pending.id
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
            VoiceTodoLog.coordinator.info("coordinator.pending_item.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) todos=\(result.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return PendingProcessResult(index: index, id: id, todos: result.todos, rawTranscript: transcript, succeeded: true)
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.pending_item.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return PendingProcessResult(index: index, id: id, todos: [], rawTranscript: transcript, succeeded: false)
        }
    }
}

private extension PendingRecoveryResult {
    static var empty: PendingRecoveryResult {
        PendingRecoveryResult(
            pendingCount: 0,
            processedWithTodosIds: [],
            processedWithoutTodosIds: [],
            extractedTodos: [],
            mergedRawTranscript: nil,
            failedCount: 0,
            deletionErrors: []
        )
    }
}
