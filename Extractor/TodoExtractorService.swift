import Foundation

/// 待办提取服务
final class TodoExtractorService: TodoExtractorProtocol {
    // MARK: - Properties

    private let networkClient: NetworkClient
    private let vocabularyProvider: any UserVocabularyProviding
    private let glossaryProvider: any PersonalGlossaryProviding
    private let circuitBreaker: ExtractorCircuitBreaker
    /// 可注入的退避延时，便于测试注入空实现以消除真实 sleep 耗时。
    private let sleep: (TimeInterval) async -> Void

    // MARK: - Initialization

    init(
        networkClient: NetworkClient = NetworkClient(),
        vocabularyProvider: any UserVocabularyProviding = UserVocabularyStore.shared,
        glossaryProvider: any PersonalGlossaryProviding = PersonalGlossaryStore.shared,
        circuitBreaker: ExtractorCircuitBreaker = ExtractorCircuitBreaker(),
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.networkClient = networkClient
        self.vocabularyProvider = vocabularyProvider
        self.glossaryProvider = glossaryProvider
        self.circuitBreaker = circuitBreaker
        self.sleep = sleep
    }

    // MARK: - TodoExtractorProtocol Implementation

    /// 从转写文本中提取待办（带重试）
    /// - Parameters:
    ///   - transcript: 用户语音转写文本
    ///   - locale: 语音识别语言环境
    /// - Returns: 提取结果
    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        let extractionID = VoiceTodoLog.currentExtractID(fallbackPrefix: "extract")
        let startedAt = Date()
        VoiceTodoLog.extractor.info("extract.start id=\(extractionID, privacy: .public) locale=\(locale.identifier, privacy: .public) retryCount=\(NetworkConfig.retryCount) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")

        // 熔断：冷却窗口内直接失败，避免持续打击故障代理。调用方按网络错误处理（保留 pending / 走 fallback）。
        if await circuitBreaker.shouldShortCircuit() {
            VoiceTodoLog.extractor.warning("extract.circuit_open id=\(extractionID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            Telemetry.record(.extractFailed(reason: "circuitOpen", attempt: 0))
            throw VoiceTodoError.networkUnavailable
        }

        var lastError: Error?
        // 用于 429 Retry-After：命中时覆盖下一次的退避间隔
        var nextDelayOverride: TimeInterval?

        for attempt in 0...NetworkConfig.retryCount {
            let attemptStart = Date()
            do {
                // 第一次不等待；重试时按指数退避（或 Retry-After 覆盖）等待
                if attempt > 0 {
                    let delay = nextDelayOverride ?? Self.backoffDelay(forRetry: attempt)
                    nextDelayOverride = nil
                    VoiceTodoLog.extractor.info("extract.retry_wait id=\(extractionID, privacy: .public) attempt=\(attempt) waitIntervalSeconds=\(delay)")
                    await self.sleep(delay)
                }
                VoiceTodoLog.extractor.info("extract.attempt.start id=\(extractionID, privacy: .public) attempt=\(attempt)")

                // 调用 API
                let responseText = try await callAPI(transcript: transcript, locale: locale)
                VoiceTodoLog.extractor.debug("extract.attempt.response id=\(extractionID, privacy: .public) attempt=\(attempt) responseChars=\(responseText.count) durationMS=\(VoiceTodoLog.durationMS(since: attemptStart))")

                // 解析 JSON
                let result = try parseResponse(responseText)

                await circuitBreaker.recordSuccess()
                VoiceTodoLog.extractor.info("extract.success id=\(extractionID, privacy: .public) attempt=\(attempt) todos=\(result.todos.count) ignoredChars=\(result.ignored.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                Telemetry.record(.extractOutcome(
                    outcome: .success,
                    todosCount: result.todos.count,
                    durationMS: VoiceTodoLog.durationMS(since: startedAt),
                    attempts: attempt + 1
                ))
                return result

            } catch {
                lastError = error
                VoiceTodoLog.extractor.error("extract.attempt.failed id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: attemptStart)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")

                if let voiceError = error as? VoiceTodoError {
                    // 仅服务类故障计入熔断（解析类错误不代表代理不健康）
                    if Self.countsAsServiceFailure(voiceError) {
                        await circuitBreaker.recordFailure()
                    }

                    switch voiceError {
                    case .apiResponseInvalid, .jsonParsingFailed, .quotaExhausted:
                        // 配置/解析/配额错误，重试无意义（配额当日不会因重试恢复，交由上层离线兜底 + paywall）
                        VoiceTodoLog.extractor.error("extract.non_retryable id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        throw error
                    case .rateLimited(let retryAfter):
                        // 有 Retry-After 才按其等待重试；否则不盲目重试以免加剧限流
                        guard let retryAfter, attempt < NetworkConfig.retryCount else {
                            VoiceTodoLog.extractor.warning("extract.rate_limited_stop id=\(extractionID, privacy: .public) attempt=\(attempt) hasRetryAfter=\(retryAfter != nil)")
                            throw error
                        }
                        nextDelayOverride = min(retryAfter, NetworkConfig.retryMaxInterval)
                    default:
                        break
                    }
                }

                // 最后一次重试失败，跳出
                if attempt == NetworkConfig.retryCount {
                    break
                }
            }
        }

        // 所有重试都失败
        VoiceTodoLog.extractor.error("extract.failed id=\(extractionID, privacy: .public) attempts=\(NetworkConfig.retryCount + 1) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) lastError=\(lastError.map(VoiceTodoLog.errorSummary) ?? "none", privacy: .public)")
        Telemetry.record(.extractFailed(
            reason: lastError.map { Telemetry.reason(for: $0) } ?? "unknown",
            attempt: NetworkConfig.retryCount + 1
        ))
        throw lastError ?? VoiceTodoError.apiResponseInvalid("Unknown error")
    }

    /// 离线降级：截取合适的长度作为标题
    /// - Parameter transcript: 用户语音转写文本
    /// - Returns: 提取结果
    func fallbackExtract(from transcript: String) -> ExtractionResult {
        let title = TextUtils.truncateTitle(from: transcript)
        VoiceTodoLog.extractor.info("extract.fallback id=\(VoiceTodoLog.makeID("fallback"), privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public) titleChars=\(title.count)")
        Telemetry.record(.extractOutcome(
            outcome: .offlineFallback,
            todosCount: 1,
            durationMS: 0,
            attempts: 0
        ))

        let todo = ExtractedTodo(
            id: UUID(),
            title: title,
            detail: transcript,
            dueHint: nil,
            priority: .normal,
            categoryHint: .other
        )

        return ExtractionResult(todos: [todo], ignored: "")
    }

    // MARK: - Streaming Implementation

    /// 流式提取：逐步解析 SSE delta，每解析出新 todo 即 yield
    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error> {
        guard NetworkConfig.streamingEnabled else {
            return AsyncThrowingStream { continuation in
                Task {
                    let streamID = VoiceTodoLog.currentExtractID(fallbackPrefix: "stream-off")
                    let startedAt = Date()
                    VoiceTodoLog.extractor.info("extract.stream.disabled id=\(streamID, privacy: .public) locale=\(locale.identifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
                    do {
                        let result = try await self.extract(from: transcript, locale: locale)
                        continuation.yield(result)
                        VoiceTodoLog.extractor.info("extract.stream.disabled_success id=\(streamID, privacy: .public) todos=\(result.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        continuation.finish()
                    } catch {
                        VoiceTodoLog.extractor.error("extract.stream.disabled_failed id=\(streamID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        let client = self.networkClient
        let localeIdentifier = locale.identifier
        let streamID = VoiceTodoLog.currentExtractID(fallbackPrefix: "extract-stream")
        let startedAt = Date()
        let vocabularyHints = vocabularyProvider.vocabularyHints(
            localeIdentifier: localeIdentifier,
            limit: UserVocabularyConfig.aiHintsLimit
        )
        let personalHints = glossaryProvider.personalHints(localeIdentifier: localeIdentifier)
        VoiceTodoLog.extractor.info("extract.stream.start id=\(streamID, privacy: .public) locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) personalHints=\(personalHints != nil, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")

        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulatedText = ""
                var lastYieldedCount = 0

                // 熔断：冷却窗口内直接失败，交由上层（TranscriptProcessingFlow）做离线兜底
                if await self.circuitBreaker.shouldShortCircuit() {
                    VoiceTodoLog.extractor.warning("extract.stream.circuit_open id=\(streamID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.finish(throwing: VoiceTodoError.networkUnavailable)
                    return
                }

                do {
                    let stream = client.callTodoExtractionProxyStreaming(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier,
                        vocabularyHints: vocabularyHints,
                        personalHints: personalHints
                    )

                    for try await delta in stream {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }

                        accumulatedText += delta

                        if let partialTodos = self.tryParsePartialTodos(accumulatedText),
                           partialTodos.count > lastYieldedCount {
                            lastYieldedCount = partialTodos.count
                            VoiceTodoLog.extractor.debug("extract.stream.partial id=\(streamID, privacy: .public) todos=\(partialTodos.count) accumulatedChars=\(accumulatedText.count)")
                            continuation.yield(ExtractionResult(todos: partialTodos, ignored: ""))
                        }
                    }

                    // 流结束后做最终完整解析
                    let finalResult = try self.parseResponse(accumulatedText)
                    await self.circuitBreaker.recordSuccess()
                    continuation.yield(finalResult)
                    VoiceTodoLog.extractor.info("extract.stream.success id=\(streamID, privacy: .public) todos=\(finalResult.todos.count) accumulatedChars=\(accumulatedText.count) partialYields=\(lastYieldedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.finish()
                } catch {
                    // 如果积累了部分文本但最终解析失败，尝试用已解析的部分结果
                    if let partialTodos = self.tryParsePartialTodos(accumulatedText), !partialTodos.isEmpty {
                        VoiceTodoLog.extractor.warning("extract.stream.partial_before_error id=\(streamID, privacy: .public) todos=\(partialTodos.count) accumulatedChars=\(accumulatedText.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        continuation.yield(ExtractionResult(todos: partialTodos, ignored: ""))
                    }
                    // 服务类失败喂熔断器（与 extract() 同一分类口径）
                    if let voiceError = error as? VoiceTodoError, Self.countsAsServiceFailure(voiceError) {
                        await self.circuitBreaker.recordFailure()
                    }
                    VoiceTodoLog.extractor.error("extract.stream.failed id=\(streamID, privacy: .public) accumulatedChars=\(accumulatedText.count) partialYields=\(lastYieldedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                VoiceTodoLog.extractor.debug("extract.stream.terminated id=\(streamID, privacy: .public) reason=\(String(describing: termination), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                task.cancel()
            }
        }
    }

    /// 贪心解析：从累积文本中尝试提取已闭合的 todo JSON 对象
    private func tryParsePartialTodos(_ text: String) -> [ExtractedTodo]? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = cleaned.range(of: "^```(?:json|JSON)?\\s*\\n", options: .regularExpression) {
            cleaned.removeSubrange(range)
        }

        guard let todosStart = cleaned.range(of: "\"todos\"\\s*:\\s*\\[", options: .regularExpression) else {
            return nil
        }

        let arrayContent = cleaned[todosStart.upperBound...]
        var todos: [ExtractedTodo] = []
        var searchStart = arrayContent.startIndex
        let decoder = JSONCoding.makeResponseDecoder()

        while searchStart < arrayContent.endIndex {
            guard let objStart = arrayContent[searchStart...].firstIndex(of: "{") else { break }

            var depth = 0
            var objEnd: String.Index?
            var isInsideString = false
            var isEscaped = false
            var idx = objStart
            while idx < arrayContent.endIndex {
                let ch = arrayContent[idx]
                if isInsideString {
                    if isEscaped {
                        isEscaped = false
                    } else if ch == "\\" {
                        isEscaped = true
                    } else if ch == "\"" {
                        isInsideString = false
                    }
                } else if ch == "\"" {
                    isInsideString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        objEnd = idx
                        break
                    }
                }
                idx = arrayContent.index(after: idx)
            }

            guard let end = objEnd else { break }

            let objStr = String(arrayContent[objStart...end])
            if let data = objStr.data(using: .utf8) {
                if let todo = try? decoder.decode(ExtractedTodo.self, from: data) {
                    todos.append(todo)
                } else {
                    VoiceTodoLog.extractor.warning("extract.stream.partial_decode_failed objectChars=\(objStr.count)")
                }
            }
            searchStart = arrayContent.index(after: end)
        }

        return todos.isEmpty ? nil : todos
    }

    // MARK: - Retry / Circuit Helpers

    /// 指数退避 + 抖动：第 N 次重试等待 base * 2^(N-1)（封顶 max）再加 0~30% 抖动。
    private static func backoffDelay(forRetry attempt: Int) -> TimeInterval {
        let exponential = NetworkConfig.retryBaseInterval * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exponential, NetworkConfig.retryMaxInterval)
        let jitter = Double.random(in: 0...(capped * 0.3))
        return capped + jitter
    }

    /// 是否计入熔断的「服务类」故障：网络不可用 / 超时 / 限流。
    /// 解析类错误（apiResponseInvalid / jsonParsingFailed）不代表代理不健康，不计入。
    private static func countsAsServiceFailure(_ error: VoiceTodoError) -> Bool {
        switch error {
        case .networkUnavailable, .apiTimeout, .rateLimited, .apiServerError, .serviceUnavailable:
            return true
        default:
            return false
        }
    }

    // MARK: - Private Methods

    /// 调用 VoiceTodo AI 代理
    private func callAPI(transcript: String, locale: Locale) async throws -> String {
        let vocabularyHints = vocabularyProvider.vocabularyHints(
            localeIdentifier: locale.identifier,
            limit: UserVocabularyConfig.aiHintsLimit
        )
        let personalHints = glossaryProvider.personalHints(localeIdentifier: locale.identifier)
        VoiceTodoLog.extractor.info("extract.context.ready id=\(VoiceTodoLog.currentExtractID(fallbackPrefix: "extract"), privacy: .public) vocabularyHints=\(vocabularyHints.count) personalHints=\(personalHints != nil, privacy: .public)")
        return try await networkClient.callTodoExtractionProxy(
            transcript: transcript,
            localeIdentifier: locale.identifier,
            vocabularyHints: vocabularyHints,
            personalHints: personalHints
        )
    }

    /// 解析 API 响应
    private func parseResponse(_ responseText: String) throws -> ExtractionResult {
        var cleanedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 使用正则移除 markdown 代码块标记（兼容大小写、有无语言标注）
        if let range = cleanedText.range(of: "^```(?:json|JSON)?\\s*\\n", options: .regularExpression) {
            cleanedText.removeSubrange(range)
        }
        if let range = cleanedText.range(of: "\\n\\s*```\\s*$", options: .regularExpression) {
            cleanedText.removeSubrange(range)
        }

        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 解析 JSON
        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw VoiceTodoError.jsonParsingFailed("无法转换为 UTF-8 数据")
        }

        do {
            let decoder = JSONCoding.makeResponseDecoder()
            let result = try decoder.decode(ExtractionResult.self, from: jsonData)
            return result
        } catch {
            VoiceTodoLog.extractor.error("extract.parse.failed responseChars=\(responseText.count) cleanedChars=\(cleanedText.count) summary=\(VoiceTodoLog.textSummary(cleanedText, previewLimit: 160), privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.jsonParsingFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }
}
