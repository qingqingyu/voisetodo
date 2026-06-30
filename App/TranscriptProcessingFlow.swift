import Foundation

enum TranscriptFlowEvent {
    case empty
    case partial(ExtractionResult)
    case success(finalTodos: [ExtractedTodo])
    case noTodos
    case offlineSaved(TodoItemData)
    case offlineSaveFailed(Error)
    case networkFallbackSaved(TodoItemData)
    case networkFallbackSaveFailed(Error)
    /// 配额耗尽后离线兜底成功。与 `networkFallbackSaved` 等价（pending 保留、稍后重试），
    /// 额外要求上层弹出 paywall 引导升级。
    case quotaFallbackSaved(TodoItemData)
    case failed(Error)
}

@MainActor
final class TranscriptProcessingFlow {
    private let store: any PendingTranscriptCreating
    private let extractor: any TodoExtractorProtocol
    private let networkIsConnectedProvider: @MainActor () -> Bool

    init(
        store: any PendingTranscriptCreating,
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
                        localeIdentifier: locale.identifier,
                        success: TranscriptFlowEvent.offlineSaved,
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
                        if !partialResult.todos.isEmpty {
                            finalTodos = partialResult.todos
                            receivedAny = true
                        }
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
                    if let voiceError = error as? VoiceTodoError {
                        switch voiceError {
                        case .networkUnavailable, .apiTimeout:
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.network_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveOffline(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                success: TranscriptFlowEvent.networkFallbackSaved,
                                failure: TranscriptFlowEvent.networkFallbackSaveFailed,
                                continuation: continuation
                            )
                        case .quotaExhausted(let tier, let resetAt):
                            // 配额耗尽：离线兜底保留转写（稍后重试）+ 上抛 paywall 信号。
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.quota_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) tier=\(tier, privacy: .public) resetAt=\(resetAt, privacy: .public)")
                            await saveOffline(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                success: TranscriptFlowEvent.quotaFallbackSaved,
                                failure: TranscriptFlowEvent.networkFallbackSaveFailed,
                                continuation: continuation
                            )
                        case .rateLimited, .serviceUnavailable:
                            // 限流/服务不可用：离线兜底，不丢转写，稍后自动重试。
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.service_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveOffline(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                success: TranscriptFlowEvent.networkFallbackSaved,
                                failure: TranscriptFlowEvent.networkFallbackSaveFailed,
                                continuation: continuation
                            )
                        default:
                            VoiceTodoLog.coordinator.error("coordinator.process_transcript.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            continuation.yield(.failed(error))
                            continuation.finish()
                        }
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
        localeIdentifier: String,
        success: (TodoItemData) -> TranscriptFlowEvent,
        failure: (Error) -> TranscriptFlowEvent,
        continuation: AsyncStream<TranscriptFlowEvent>.Continuation
    ) async {
        let offlineID = VoiceTodoLog.makeID("offline")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.offline_save.start id=\(offlineID, privacy: .public) locale=\(localeIdentifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            let pendingTodo = try store.addRawTranscript(transcript, localeIdentifier: localeIdentifier)
            VoiceTodoLog.coordinator.info("coordinator.offline_save.success id=\(offlineID, privacy: .public) pendingID=\(pendingTodo.id.uuidString, privacy: .public) locale=\(localeIdentifier, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            continuation.yield(success(pendingTodo))
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.offline_save.failed id=\(offlineID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            continuation.yield(failure(error))
        }
        continuation.finish()
    }
}
