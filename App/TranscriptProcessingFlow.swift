import Foundation

enum TranscriptFlowEvent {
    case empty
    case partial(ExtractionResult)
    case success(finalTodos: [ExtractedTodo])
    case noTodos
    case offlineSaved(TodoItemData)
    case offlineSaveFailed(Error)
    /// 外部调用失败后原始转写已保存。保留失败原因，供 UI 显示准确提示。
    case fallbackSaved(TodoItemData, reason: VoiceTodoError)
    case networkFallbackSaveFailed(Error)
    /// 配额耗尽后离线兜底成功。与 `fallbackSaved` 等价（pending 保留、稍后重试），
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

                // 提到 do 块外:catch 分支需要据此判断走 partial fallback 还是原错误路径
                var receivedAny = false
                var finalTodos: [ExtractedTodo] = []

                do {
                    let stream = VoiceTodoLog.$extractID.withValue(extractID) {
                        VoiceTodoLog.$requestPath.withValue("main") {
                            ext.extractStreaming(from: trimmed, locale: locale)
                        }
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
                        continuation.finish()
                    } else {
                        VoiceTodoLog.coordinator.info("coordinator.process_transcript.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) finalTodos=\(finalTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        continuation.yield(.success(finalTodos: finalTodos))
                        continuation.finish()
                    }
                } catch {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    // 取消不是失败。必须放在下面 partial fallback 之前:否则「取消时已收到
                    // partial」会被重新提升成 .success,把用户刚关掉的确认弹层再填满。
                    // 也绝不能走 saveOffline —— 用户主动取消却在库里多出一条 pending 转写,
                    // 下次启动会被 PendingRecoveryFlow 认领并再扣一次配额。
                    //
                    // 内层 task 被取消而本 flow 未被取消是真实存在的(见
                    // AppCoordinator.stopExtractionAfterSuccessfulConfirm),所以上面的
                    // Task.isCancelled 守卫覆盖不到,需要这条按错误类型的判断。
                    if error is CancellationError {
                        VoiceTodoLog.coordinator.info("coordinator.process_transcript.cancelled id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        continuation.finish()
                        return
                    }
                    // Partial fallback:流被截断(超时/网络抖动/服务 5xx)但已收到 ≥1 条
                    // partial 时,把已收到的当成功结果上抛,而不是丢弃。
                    // 用户输入 13 条解析出 11 条后被流断 → 给用户 11 条比清空让用户重来更友好,
                    // 丢的 2 条让用户在 ConfirmSheet 里自己补。
                    // 例外:配额耗尽仍走 paywall(用户额度真用完,不应用 partial 绕过引导升级)。
                    if receivedAny {
                        if let voiceError = error as? VoiceTodoError, case .quotaExhausted = voiceError {
                            // 配额耗尽:即使有 partial 也走 paywall 路径(下方 switch 处理)
                        } else {
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.partial_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) todos=\(finalTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            continuation.yield(.success(finalTodos: finalTodos))
                            continuation.finish()
                            return
                        }
                    }
                    if let voiceError = error as? VoiceTodoError {
                        switch voiceError {
                        case .networkUnavailable, .apiTimeout, .circuitOpen:
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.network_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveOffline(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                success: { .fallbackSaved($0, reason: voiceError) },
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
                        case .rateLimited, .ipRateLimited, .serviceUnavailable:
                            // 限流/服务不可用：离线兜底，不丢转写，稍后自动重试。
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.service_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveOffline(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                success: { .fallbackSaved($0, reason: voiceError) },
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
