import Foundation

enum TranscriptFlowEvent {
    case empty
    case partial(ExtractionResult)
    case success(finalTodos: [ExtractedTodo])
    case noTodos
    case offlineSaved
    case offlineSaveFailed(Error)
    case networkFallbackSaved
    case networkFallbackSaveFailed(Error)
    case failed(Error)
}

@MainActor
final class TranscriptProcessingFlow {
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

    func process(
        text: String,
        locale: Locale,
        flowID: String,
        extractID: String
    ) -> AsyncStream<TranscriptFlowEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConnected = networkIsConnectedProvider()
        let ext = extractor
        VoiceTodoLog.coordinator.info("coordinator.process_transcript.start id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) locale=\(locale.identifier, privacy: .public) isConnected=\(isConnected) \(VoiceTodoLog.textSummary(trimmed), privacy: .public)")

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let startedAt = Date()
                guard !trimmed.isEmpty else {
                    VoiceTodoLog.coordinator.info("coordinator.process_transcript.empty id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.yield(.empty)
                    continuation.finish()
                    return
                }

                guard isConnected else {
                    VoiceTodoLog.coordinator.warning("coordinator.process_transcript.offline id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public)")
                    await saveOffline(
                        transcript: text,
                        fallbackEvent: .offlineSaved,
                        failure: TranscriptFlowEvent.offlineSaveFailed,
                        continuation: continuation
                    )
                    return
                }

                do {
                    var receivedAny = false
                    var finalTodos: [ExtractedTodo] = []
                    let stream = VoiceTodoLog.$extractID.withValue(extractID) {
                        ext.extractStreaming(from: trimmed, locale: locale)
                    }
                    for try await partialResult in stream {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        finalTodos = partialResult.todos
                        receivedAny = !partialResult.todos.isEmpty
                        VoiceTodoLog.coordinator.debug("coordinator.process_transcript.partial id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) todos=\(partialResult.todos.count)")
                        continuation.yield(.partial(partialResult))
                    }

                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    if !receivedAny {
                        VoiceTodoLog.coordinator.info("coordinator.process_transcript.no_todos id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        continuation.yield(.noTodos)
                    } else {
                        VoiceTodoLog.coordinator.info("coordinator.process_transcript.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) finalTodos=\(finalTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        continuation.yield(.success(finalTodos: finalTodos))
                    }
                } catch {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    if let voiceError = error as? VoiceTodoError,
                       voiceError == .networkUnavailable || voiceError == .apiTimeout {
                        VoiceTodoLog.coordinator.warning("coordinator.process_transcript.network_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        await saveOffline(
                            transcript: text,
                            fallbackEvent: .networkFallbackSaved,
                            failure: TranscriptFlowEvent.networkFallbackSaveFailed,
                            continuation: continuation
                        )
                    } else {
                        VoiceTodoLog.coordinator.error("coordinator.process_transcript.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        continuation.yield(.failed(error))
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func saveOffline(
        transcript: String,
        fallbackEvent: TranscriptFlowEvent,
        failure: (Error) -> TranscriptFlowEvent,
        continuation: AsyncStream<TranscriptFlowEvent>.Continuation
    ) async {
        let offlineID = VoiceTodoLog.makeID("offline")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.offline_save.start id=\(offlineID, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            try store.addRawTranscript(transcript)
            VoiceTodoLog.coordinator.info("coordinator.offline_save.success id=\(offlineID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            continuation.yield(fallbackEvent)
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.offline_save.failed id=\(offlineID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            continuation.yield(failure(error))
        }
        continuation.finish()
    }
}
