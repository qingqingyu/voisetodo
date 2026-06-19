import Foundation

/// 待办提取服务
final class TodoExtractorService: TodoExtractorProtocol {
    // MARK: - Properties

    private let networkClient: NetworkClient

    // MARK: - Initialization

    init(networkClient: NetworkClient = NetworkClient()) {
        self.networkClient = networkClient
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

        var lastError: Error?

        // 重试策略：重试 1 次
        for attempt in 0...NetworkConfig.retryCount {
            let attemptStart = Date()
            do {
                // 第一次不等待，重试时等待指定间隔
                if attempt > 0 {
                    VoiceTodoLog.extractor.info("extract.retry_wait id=\(extractionID, privacy: .public) attempt=\(attempt) waitIntervalSeconds=\(NetworkConfig.retryInterval)")
                    try await Task.sleep(nanoseconds: UInt64(NetworkConfig.retryInterval * 1_000_000_000))
                }
                VoiceTodoLog.extractor.info("extract.attempt.start id=\(extractionID, privacy: .public) attempt=\(attempt)")

                // 调用 API
                let responseText = try await callAPI(transcript: transcript, locale: locale)
                VoiceTodoLog.extractor.debug("extract.attempt.response id=\(extractionID, privacy: .public) attempt=\(attempt) responseChars=\(responseText.count) durationMS=\(VoiceTodoLog.durationMS(since: attemptStart))")

                // 解析 JSON
                let result = try parseResponse(responseText)

                VoiceTodoLog.extractor.info("extract.success id=\(extractionID, privacy: .public) attempt=\(attempt) todos=\(result.todos.count) ignoredChars=\(result.ignored.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                return result

            } catch {
                lastError = error
                VoiceTodoLog.extractor.error("extract.attempt.failed id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: attemptStart)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")

                // 如果是配置错误或解析错误，不重试（AI 返回格式稳定，重试无意义）
                if let voiceError = error as? VoiceTodoError {
                    switch voiceError {
                    case .apiResponseInvalid, .jsonParsingFailed:
                        VoiceTodoLog.extractor.error("extract.non_retryable id=\(extractionID, privacy: .public) attempt=\(attempt) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        throw error
                    default:
                        break
                    }
                }

                // 最后一次重试失败，抛出错误
                if attempt == NetworkConfig.retryCount {
                    break
                }
            }
        }

        // 所有重试都失败
        VoiceTodoLog.extractor.error("extract.failed id=\(extractionID, privacy: .public) attempts=\(NetworkConfig.retryCount + 1) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) lastError=\(lastError.map(VoiceTodoLog.errorSummary) ?? "none", privacy: .public)")
        throw lastError ?? VoiceTodoError.apiResponseInvalid("Unknown error")
    }

    /// 离线降级：截取合适的长度作为标题
    /// - Parameter transcript: 用户语音转写文本
    /// - Returns: 提取结果
    func fallbackExtract(from transcript: String) -> ExtractionResult {
        let title = TextUtils.truncateTitle(from: transcript)
        VoiceTodoLog.extractor.info("extract.fallback id=\(VoiceTodoLog.makeID("fallback"), privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public) titleChars=\(title.count)")

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
        VoiceTodoLog.extractor.info("extract.stream.start id=\(streamID, privacy: .public) locale=\(localeIdentifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")

        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulatedText = ""
                var lastYieldedCount = 0

                do {
                    let stream = client.callTodoExtractionProxyStreaming(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier
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
                    continuation.yield(finalResult)
                    VoiceTodoLog.extractor.info("extract.stream.success id=\(streamID, privacy: .public) todos=\(finalResult.todos.count) accumulatedChars=\(accumulatedText.count) partialYields=\(lastYieldedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.finish()
                } catch {
                    // 如果积累了部分文本但最终解析失败，尝试用已解析的部分结果
                    if let partialTodos = self.tryParsePartialTodos(accumulatedText), !partialTodos.isEmpty {
                        VoiceTodoLog.extractor.warning("extract.stream.partial_before_error id=\(streamID, privacy: .public) todos=\(partialTodos.count) accumulatedChars=\(accumulatedText.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        continuation.yield(ExtractionResult(todos: partialTodos, ignored: ""))
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

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

    // MARK: - Private Methods

    /// 调用 VoiceTodo AI 代理
    private func callAPI(transcript: String, locale: Locale) async throws -> String {
        try await networkClient.callTodoExtractionProxy(
            transcript: transcript,
            localeIdentifier: locale.identifier
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
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(ExtractionResult.self, from: jsonData)
            return result
        } catch {
            VoiceTodoLog.extractor.error("extract.parse.failed responseChars=\(responseText.count) cleanedChars=\(cleanedText.count) summary=\(VoiceTodoLog.textSummary(cleanedText, previewLimit: 160), privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.jsonParsingFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }
}
