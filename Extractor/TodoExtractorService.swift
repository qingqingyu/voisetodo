import Foundation

/// 待办提取服务
final class TodoExtractorService: TodoExtractorProtocol, TodoSplitterProtocol {
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

        // 熔断：冷却窗口内直接失败，避免持续打击故障代理。
        // 抛 .circuitOpen（而非 .networkUnavailable）——熔断是"近期失败太多的自我保护"，
        // 与"当下网络不通"语义不同；UI 因此能显示精准文案，不误导用户检查网络。
        if await circuitBreaker.shouldShortCircuit() {
            VoiceTodoLog.extractor.warning("extract.circuit_open id=\(extractionID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            Telemetry.record(.extractFailed(reason: "circuitOpen", attempt: 0))
            throw VoiceTodoError.circuitOpen
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

                await noteSuccess(id: extractionID)
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

                // 取消：立刻退出重试循环，不计熔断、不上报失败。
                // 若不在这里拦截，CancellationError 会一路落到下面的
                // `if attempt == retryCount { break }`，导致用户取消后还继续重试。
                if Self.isCancellation(error) {
                    VoiceTodoLog.extractor.info("extract.cancelled id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    Telemetry.record(.extractOutcome(
                        outcome: .cancelled,
                        todosCount: 0,
                        durationMS: VoiceTodoLog.durationMS(since: startedAt),
                        attempts: attempt + 1
                    ))
                    throw error
                }

                VoiceTodoLog.extractor.error("extract.attempt.failed id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: attemptStart)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")

                if let voiceError = error as? VoiceTodoError {
                    // 仅服务类故障计入熔断（解析类错误不代表代理不健康）
                    if Self.countsAsServiceFailure(voiceError) {
                        await noteFailure(id: extractionID, reason: Telemetry.reason(for: voiceError))
                    }

                    switch voiceError {
                    case .apiResponseInvalid, .jsonParsingFailed, .transcriptTooLong, .quotaExhausted, .ipRateLimited:
                        // 配置/解析/配额/IP 当日限额错误，重试无意义（当日不会因重试恢复），交由上层离线兜底。
                        // ipRateLimited 特别说明：当天 IP 配额耗尽，Retry-After 通常是到 UTC 0 点的几万秒，
                        // 重试只会加剧计数并拖慢用户感知。直接抛，让上层显示"明天再试"。
                        VoiceTodoLog.extractor.error("extract.non_retryable id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        throw error
                    case .rateLimited(let retryAfter):
                        // 仅当服务端要求的等待时间落在客户端可接受窗口内才重试。
                        // 例如 velocity 返回 60s 时，不能截成 8s 提前请求；直接交给上层离线兜底。
                        guard let retryAfter,
                              retryAfter >= 0,
                              retryAfter <= NetworkConfig.retryMaxInterval,
                              attempt < NetworkConfig.retryCount else {
                            VoiceTodoLog.extractor.warning("extract.rate_limited_stop id=\(extractionID, privacy: .public) attempt=\(attempt) retryAfter=\(retryAfter.map { String($0) } ?? "nil")")
                            throw error
                        }
                        nextDelayOverride = retryAfter
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

    // MARK: - TodoSplitterProtocol Implementation

    /// 任务拆小(2026-08-23 拆小改版):走代理 `mode=split`。
    /// 与主提取链路的差异(拍板口径):单次调用不重试、不喂熔断器、不计费额度;
    /// 失败由调用方降级为手动输入。
    func splitSteps(for input: String, locale: Locale, wantsAlternative: Bool) async throws -> [String] {
        let splitID = VoiceTodoLog.makeID("split")
        let startedAt = Date()
        // 「换一批」的多样性指令拼在用户输入后(按内容语言选措辞,避免给英文/日文
        // 输入拼中文指令干扰「输出语言与输入一致」规则)——代理/模型侧无需感知 variant 概念
        let message = wantsAlternative ? input + Self.alternativeInstruction(for: locale) : input
        VoiceTodoLog.extractor.info("split.start id=\(splitID, privacy: .public) locale=\(locale.identifier, privacy: .public) alternative=\(wantsAlternative) \(VoiceTodoLog.textSummary(input), privacy: .public)")
        do {
            let responseText = try await networkClient.callTodoExtractionProxy(
                transcript: message,
                localeIdentifier: locale.identifier,
                mode: "split"
            )
            let steps = try parseSplitResponse(responseText)
            VoiceTodoLog.extractor.info("split.success id=\(splitID, privacy: .public) steps=\(steps.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return steps
        } catch {
            VoiceTodoLog.extractor.error("split.failed id=\(splitID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw error
        }
    }

    /// split 模式响应体:{"steps":["...", "..."]}
    private struct SplitStepsResponse: Decodable {
        let steps: [String]
    }

    /// 「换一批」多样性指令:与用户输入同语言(不给英文/日文输入拼中文)。
    private static func alternativeInstruction(for locale: Locale) -> String {
        let id = locale.identifier
        if id.hasPrefix("zh") { return "\n\n(给出与上次不同角度的拆法)" }
        if id.hasPrefix("ja") { return "\n\n(前回とは異なる切り口で分解してください)" }
        return "\n\n(Break it down from a different angle than last time)"
    }

    /// 解析 split 响应。与 parseResponse 同样的 fence 清理套路;空步骤按失败抛错
    /// (协议契约:拆不出东西不该静默返回空数组让 UI 显示空候选区)。
    private func parseSplitResponse(_ responseText: String) throws -> [String] {
        var cleanedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = cleanedText.range(of: "^```(?:json|JSON)?\\s*\\n", options: .regularExpression) {
            cleanedText.removeSubrange(range)
        }
        if let range = cleanedText.range(of: "\\n\\s*```\\s*$", options: .regularExpression) {
            cleanedText.removeSubrange(range)
        }
        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw VoiceTodoError.jsonParsingFailed("无法转换为 UTF-8 数据")
        }
        do {
            let decoded = try JSONCoding.makeResponseDecoder().decode(SplitStepsResponse.self, from: jsonData)
            let steps = decoded.steps
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !steps.isEmpty else {
                throw VoiceTodoError.jsonParsingFailed("split 返回空步骤")
            }
            return steps
        } catch let error as VoiceTodoError {
            throw error
        } catch {
            throw VoiceTodoError.jsonParsingFailed("split JSON 解析失败: \(error.localizedDescription)")
        }
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
                // 跨 partial / final 帧稳定的 id 池。tryParsePartialTodos 与 parseResponse 每次
                // 都重新 decode → ?? UUID() 兜底生成新 UUID,id 全变 → ForEach 把每个 partial 识别
                // 为「全删 + 全增」→ 触发 ConfirmGroupedList 的 removal: .move(edge: .trailing)
                // = 用户看到的「卡片向右闪出」。维护本池按 index 复用 id,见 reassignedIDs。
                var stableIDs: [UUID] = []

                // 熔断：冷却窗口内直接失败，交由上层（TranscriptProcessingFlow）做离线兜底
                // 抛 .circuitOpen 而非 .networkUnavailable，让 UI 能区分"熔断自我保护"与"网络不可达"
                if await self.circuitBreaker.shouldShortCircuit() {
                    VoiceTodoLog.extractor.warning("extract.stream.circuit_open id=\(streamID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    // 主路径（streamingEnabled = true）此前完全没有遥测，而这里正是
                    // 「远端 AI 不生效」的症状本身。没有它就无从证明修复后降到了 0。
                    Telemetry.record(.extractFailed(reason: "circuitOpen", attempt: 0))
                    continuation.finish(throwing: VoiceTodoError.circuitOpen)
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
                            let stabilized = self.reassignedIDs(partialTodos, stableIDs: &stableIDs)
                            VoiceTodoLog.extractor.debug("extract.stream.partial id=\(streamID, privacy: .public) todos=\(partialTodos.count) accumulatedChars=\(accumulatedText.count)")
                            continuation.yield(ExtractionResult(todos: stabilized, ignored: ""))
                        }
                    }

                    // 流结束后做最终完整解析
                    let finalResult = try self.parseResponse(accumulatedText)
                    // final 是一次独立的全量 decode,同样会 churn id;用同一份 stableIDs 把 final 的
                    // id 对齐到 partial 期间用的 id,避免最后一次 partial → final 切换瞬间所有卡片
                    // 重播 removal + insertion transition(否则用户会看到流结束瞬间整批闪一下)。
                    let stabilizedFinal = self.reassignedIDs(finalResult.todos, stableIDs: &stableIDs)
                    await self.noteSuccess(id: streamID)
                    continuation.yield(ExtractionResult(todos: stabilizedFinal, ignored: finalResult.ignored))
                    VoiceTodoLog.extractor.info("extract.stream.success id=\(streamID, privacy: .public) todos=\(finalResult.todos.count) accumulatedChars=\(accumulatedText.count) partialYields=\(lastYieldedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.finish()
                } catch {
                    // 取消优先于一切,必须放在 partial fallback 之前:
                    //   - 不 yield partial —— 用户已经离开弹层,再推结果只会让下一次录音闪现旧数据
                    //     (AppCoordinator 的 stale_extracted_cleared 兜底就是为此存在的)
                    //   - 不喂熔断器 —— 取消不是 provider 故障
                    //   - 不抛错 —— 上层 TranscriptProcessingFlow / AppCoordinator 各自有
                    //     Task.isCancelled 守卫,静默 finish 即可,不该弹错也不该走离线兜底
                    if Self.isCancellation(error) {
                        VoiceTodoLog.extractor.info("extract.stream.cancelled id=\(streamID, privacy: .public) accumulatedChars=\(accumulatedText.count) partialYields=\(lastYieldedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        Telemetry.record(.extractOutcome(
                            outcome: .cancelled,
                            todosCount: lastYieldedCount,
                            durationMS: VoiceTodoLog.durationMS(since: startedAt),
                            attempts: 1
                        ))
                        continuation.finish()
                        return
                    }

                    // 如果积累了部分文本但最终解析失败，尝试用已解析的部分结果
                    if let partialTodos = self.tryParsePartialTodos(accumulatedText), !partialTodos.isEmpty {
                        let stabilized = self.reassignedIDs(partialTodos, stableIDs: &stableIDs)
                        VoiceTodoLog.extractor.warning("extract.stream.partial_before_error id=\(streamID, privacy: .public) todos=\(partialTodos.count) accumulatedChars=\(accumulatedText.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        continuation.yield(ExtractionResult(todos: stabilized, ignored: ""))
                    }
                    // 服务类失败喂熔断器（与 extract() 同一分类口径）
                    if let voiceError = error as? VoiceTodoError, Self.countsAsServiceFailure(voiceError) {
                        await self.noteFailure(id: streamID, reason: Telemetry.reason(for: voiceError))
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

    /// 流式期间覆盖新 decode 出来的 ExtractedTodo.id,保证同一 index 的 todo 跨帧 id 稳定。
    ///
    /// 为什么需要:ForEach 以 id 做身份,稳定 id 避免每个 partial 都触发整批 removal +
    /// insertion transition(ConfirmGroupedList 的 removal: .move(edge: .trailing) 就是
    /// 用户看到的「卡片向右闪出」现象的根因)。
    ///
    /// 按 index 做 key 安全性证明:
    /// - tryParsePartialTodos 用括号深度匹配,只吐完整的 {...} 对象——对象一旦闭合,
    ///   字符范围固定,decode 出来的内容(title/dueDate 等)即最终态,不会随后续 delta 变化
    /// - 调用点用 partialTodos.count > lastYieldedCount 守卫,保证条目数单调增长
    /// - parseResponse(流结束后)基于同一份 accumulatedText,产出顺序与 partial 一致
    /// 故 index N 在所有 partial / final 帧里恒指向同一逻辑 todo,用 stableIDs[N] 复用 id。
    ///
    /// stableIDs 只增不减:即使某次 todos.count 缩短(理论上不应发生,守卫已挡),
    /// 也不清空 stableIDs——下次重新对齐时仍用旧 id,identity 持续稳定。
    private func reassignedIDs(_ todos: [ExtractedTodo], stableIDs: inout [UUID]) -> [ExtractedTodo] {
        var result = todos
        for index in result.indices {
            while stableIDs.count <= index {
                stableIDs.append(UUID())
            }
            result[index].id = stableIDs[index]
        }
        return result
    }

    // MARK: - Retry / Circuit Helpers

    /// 指数退避 + 抖动：第 N 次重试等待 base * 2^(N-1)（封顶 max）再加 0~30% 抖动。
    private static func backoffDelay(forRetry attempt: Int) -> TimeInterval {
        let exponential = NetworkConfig.retryBaseInterval * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exponential, NetworkConfig.retryMaxInterval)
        let jitter = Double.random(in: 0...(capped * 0.3))
        return capped + jitter
    }

    /// 记录一次成功并把熔断器的状态迁移落到日志 + 遥测。
    private func noteSuccess(id: String) async {
        let transition = await circuitBreaker.recordSuccess()
        guard transition == .closed else { return }
        VoiceTodoLog.extractor.info("extract.circuit.closed id=\(id, privacy: .public)")
        Telemetry.record(.extractorCircuitChanged(state: "closed", reason: "success"))
    }

    /// 记录一次服务类失败并把熔断器的状态迁移落到日志 + 遥测。
    /// 只有 `.opened` 值得上报——它等价于「接下来一段时间远端 AI 会被静默降级」。
    private func noteFailure(id: String, reason: String) async {
        let transition = await circuitBreaker.recordFailure()
        guard case .opened(let until) = transition else { return }
        let cooldown = Int(until.timeIntervalSinceNow.rounded())
        VoiceTodoLog.extractor.error("extract.circuit.opened id=\(id, privacy: .public) cooldownSeconds=\(cooldown) reason=\(reason, privacy: .public)")
        Telemetry.record(.extractorCircuitChanged(state: "opened", reason: reason))
    }

    /// 是否为「取消」而非「故障」。
    ///
    /// 取消永远由用户发起（关闭确认弹层、开始新一次录音、确认成功后主动收流——见
    /// `AppCoordinator.cancelExtraction` / `stopExtractionAfterSuccessfulConfirm`），
    /// 绝不能计入熔断：一次取消若被记成一次 provider 故障，攒够阈值就把远端 AI 静默熔断掉。
    ///
    /// 三个来源都要认：`NetworkClient.mapURLError` 抛的 `CancellationError`、退避
    /// `Task.sleep` 抛的 `CancellationError`、以及 URLSession 直接冒上来的 `URLError.cancelled`。
    private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled { return true }
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// 是否计入熔断的「服务类」故障：网络不可用 / 超时 / 服务端错误。
    /// 解析类错误（apiResponseInvalid / jsonParsingFailed）不代表代理不健康，不计入。
    /// 限流（rateLimited）也不计入——限流是客户端 IP/设备配额问题，不代表代理本身不健康，
    /// 若计入会让单个 IP 触发配额后熔断掉所有人的代理访问。
    private static func countsAsServiceFailure(_ error: VoiceTodoError) -> Bool {
        switch error {
        case .networkUnavailable, .apiTimeout, .apiServerError, .serviceUnavailable:
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

        // 诊断:打印 AI 返回的完整 JSON 原文(去掉 markdown fence 后)。
        // 用于排查"一句话被拆两条 todo"类问题——能看到模型实际返回了几条、
        // 每条的 id/title/due_date 是什么。OSLog 有 size 限制会截断长字符串,
        // 用 print 保证完整输出到 Xcode console。
        // 隐私:JSON 内容来自 AI 对用户语音的解析,可能含用户原话。仅 DEBUG configuration
        // 下编译进二进制(默认 Debug configuration 才设 DEBUG=1),Release/TestFlight 不含。
        // 注意:若未来 Archive 时误启用 DEBUG 符号,日志会随 syslog 流出——上线前需确认 configuration。
        #if DEBUG
        print("extract.parse.raw_json \(cleanedText)")
        #endif

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
            // 截断识别:JSON 末尾不完整(Unexpected end of file)通常是 AI 输出被 max_tokens 切断。
            // 这种 case 用户可解决(分批输入),跟服务端格式异常(重试可解决)语义不同,需走 transcriptTooLong。
            // 检测特征(见 isJsonTruncationError):DecodingError.dataCorrupted 的 underlyingError
            // 是 NSCocoaErrorDomain 3840 + NSDebugDescription 含 "Unexpected end of file"。
            // 用 NSDebugDescription(英文程序员向,不随 locale 变)而非 localizedDescription(随系统语言变)。
            // 其他 DecodingError 子类(schema 不匹配、类型错误等)仍走 jsonParsingFailed。
            if isJsonTruncationError(error) {
                throw VoiceTodoError.transcriptTooLong
            }
            throw VoiceTodoError.jsonParsingFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }

    /// 判断底层 JSON 解析错误是否是"流被截断/末尾不完整"。
    /// 用于把 `transcriptTooLong`(用户可解决)从 `jsonParsingFailed`(服务端问题)中区分出来。
    ///
    /// - 顶层错误是 `DecodingError.dataCorrupted`(NSError domain=NSCocoaErrorDomain code=4864),
    ///   它的 `userInfo[NSUnderlyingErrorKey]` 才是真正的 JSONSerialization 错误
    ///   (domain=NSCocoaErrorDomain code=3840,NSDebugDescription 含 "Unexpected end of file")。
    ///   顶层错误的 NSDebugDescription 是 "The given data was not valid JSON."(不含 "end of file"),
    ///   直接查顶层会漏判。
    /// - 用 `userInfo[NSDebugDescriptionErrorKey]` 而非 `localizedDescription`:debug 描述是程序员向英文,
    ///   不随系统 locale 变化;localizedDescription 在 zh-Hans 下会本地化为"数据无法读取,因为文件结尾意外"等
    ///   不同文案,导致匹配失效。
    /// - 其他 case(typeMismatch、valueNotFound 等 DecodingError 子类)不算截断,
    ///   通常是 schema 不匹配或格式异常。
    private func isJsonTruncationError(_ error: Error) -> Bool {
        // 先看顶层,再回退到 underlyingError
        let candidates: [NSError] = [error as NSError] + underlyingErrors(of: error as NSError)
        for candidate in candidates {
            guard candidate.domain == NSCocoaErrorDomain, candidate.code == 3840 else { continue }
            let debugDescription = (candidate.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
            if debugDescription.contains("end of file") {
                return true
            }
        }
        return false
    }

    /// 递归取出 NSError 的 underlyingError 链(最多 5 层防循环)。
    private func underlyingErrors(of error: NSError) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error
        var depth = 0
        while let cur = current, depth < 5 {
            if let underlying = cur.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== cur {
                result.append(underlying)
                current = underlying
                depth += 1
            } else {
                break
            }
        }
        return result
    }
}
