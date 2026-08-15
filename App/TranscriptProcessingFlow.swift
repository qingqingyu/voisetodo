import Foundation

enum TranscriptFlowEvent {
    case empty
    case partial(ExtractionResult)
    case success(finalTodos: [ExtractedTodo])
    case offlineSaved(TodoItemData)
    case offlineSaveFailed(Error)
    /// 外部调用失败后原始转写已保存。保留失败原因，供 UI 显示准确提示。
    case fallbackSaved(TodoItemData, reason: VoiceTodoError)
    case networkFallbackSaveFailed(Error)
    /// 配额耗尽后离线兜底成功。与 `fallbackSaved` 等价（pending 保留、稍后重试），
    /// 额外要求上层弹出 paywall 引导升级。
    case quotaFallbackSaved(TodoItemData)
    /// 确定性失败(noTodos / transcriptTooLong / apiResponseInvalid / jsonParsingFailed 等)
    /// 后原文已存为**手动卡片**(needsAIProcessing=false + .unparsed):不参与前台自动重试
    /// (这类错误对同一输入重试必败且烧额度),用户可在「没能识别」分组手动重新解析。
    /// reason 保留失败原因供 UI 显示准确提示;noTodos 非 error 场景传 nil。
    case manualSaved(TodoItemData, reason: VoiceTodoError?)
    /// 手动卡片保存失败(存储故障)。
    case manualSaveFailed(Error)
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
                        // AI 看过原文但没识别出任何待办:原文不丢,存为手动卡片,
                        // 用户可在「没能识别」分组查看/重新解析/编辑(用户拍板的「永不丢话」口径)。
                        await saveManual(
                            transcript: text,
                            localeIdentifier: locale.identifier,
                            reason: nil,
                            continuation: continuation
                        )
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
                        case .networkUnavailable, .apiTimeout, .circuitOpen, .apiServerError:
                            // apiServerError(5xx 非 503)与 serviceUnavailable 同为瞬时服务故障
                            // (TodoExtractorService.countsAsServiceFailure 同口径):pending 自动恢复,重试有意义。
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
                        case let deterministicError where deterministicError.isDeterministicParseFailure:
                            // 确定性解析失败:同一输入重试必败且每次烧一次模型额度
                            // (temperature=0,输出长度由输入决定)。原文存手动卡片,
                            // 用户可在「没能识别」分组手动重新解析(提额后的重试通常能过)。
                            // 判定清单收敛在 VoiceTodoError.isDeterministicParseFailure。
                            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.manual_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveManual(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                reason: voiceError,
                                continuation: continuation
                            )
                        default:
                            // 未归类的 VoiceTodoError:同样不丢话,手动卡片兜底。
                            VoiceTodoLog.coordinator.error("coordinator.process_transcript.manual_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            await saveManual(
                                transcript: text,
                                localeIdentifier: locale.identifier,
                                reason: voiceError,
                                continuation: continuation
                            )
                        }
                    } else {
                        // 非 VoiceTodoError 的未知错误:原文同样不丢,手动卡片兜底。
                        VoiceTodoLog.coordinator.error("coordinator.process_transcript.manual_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        await saveManual(
                            transcript: text,
                            localeIdentifier: locale.identifier,
                            reason: nil,
                            continuation: continuation
                        )
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

    /// 确定性失败兜底:原文存为手动卡片(needsAIProcessing=false + .unparsed)。
    /// 与 `saveOffline` 的差别:产物不进 pending 自动恢复队列——确定性错误自动重试
    /// 必败且每次烧一次模型额度,改为用户在「没能识别」卡片上手动触发重新解析。
    private func saveManual(
        transcript: String,
        localeIdentifier: String,
        reason: VoiceTodoError?,
        continuation: AsyncStream<TranscriptFlowEvent>.Continuation
    ) async {
        let manualID = VoiceTodoLog.makeID("manual-save")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.manual_save.start id=\(manualID, privacy: .public) locale=\(localeIdentifier, privacy: .public) reason=\(reason.map(VoiceTodoLog.errorSummary) ?? "no_todos", privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            let manualTodo = try store.addManualUnparsedTranscript(transcript, localeIdentifier: localeIdentifier)
            VoiceTodoLog.coordinator.info("coordinator.manual_save.success id=\(manualID, privacy: .public) todoID=\(manualTodo.id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            continuation.yield(.manualSaved(manualTodo, reason: reason))
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.manual_save.failed id=\(manualID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            continuation.yield(.manualSaveFailed(error))
        }
        continuation.finish()
    }
}
