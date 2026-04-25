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
        var lastError: Error?

        // 重试策略：重试 1 次
        for attempt in 0...NetworkConfig.retryCount {
            do {
                // 第一次不等待，重试时等待指定间隔
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: UInt64(NetworkConfig.retryInterval * 1_000_000_000))
                }

                // 调用 API
                let responseText = try await callAPI(transcript: transcript, locale: locale)

                // 解析 JSON
                let result = try parseResponse(responseText)

                return result

            } catch {
                lastError = error

                // 如果是配置错误或解析错误，不重试（AI 返回格式稳定，重试无意义）
                if let voiceError = error as? VoiceTodoError {
                    switch voiceError {
                    case .apiResponseInvalid, .jsonParsingFailed:
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
        throw lastError ?? VoiceTodoError.apiResponseInvalid("Unknown error")
    }

    /// 离线降级：截取合适的长度作为标题
    /// - Parameter transcript: 用户语音转写文本
    /// - Returns: 提取结果
    func fallbackExtract(from transcript: String) -> ExtractionResult {
        let title = TextUtils.truncateTitle(from: transcript)

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
                    do {
                        let result = try await self.extract(from: transcript, locale: locale)
                        continuation.yield(result)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        let messages = PromptTemplates.buildMessages(for: transcript)
        let systemPrompt = PromptTemplates.systemPrompt(for: locale)
        let client = self.networkClient

        return AsyncThrowingStream { continuation in
            Task {
                var accumulatedText = ""
                var lastYieldedCount = 0

                do {
                    let stream = client.callClaudeAPIStreaming(
                        systemPrompt: systemPrompt,
                        messages: messages,
                        model: NetworkConfig.claudeModel,
                        temperature: 0.1,
                        maxTokens: 500
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
                            continuation.yield(ExtractionResult(todos: partialTodos, ignored: ""))
                        }
                    }

                    // 流结束后做最终完整解析
                    let finalResult = try self.parseResponse(accumulatedText)
                    continuation.yield(finalResult)
                    continuation.finish()
                } catch {
                    // 如果积累了部分文本但最终解析失败，尝试用已解析的部分结果
                    if let partialTodos = self.tryParsePartialTodos(accumulatedText), !partialTodos.isEmpty {
                        continuation.yield(ExtractionResult(todos: partialTodos, ignored: ""))
                    }
                    continuation.finish(throwing: error)
                }
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
            var idx = objStart
            while idx < arrayContent.endIndex {
                let ch = arrayContent[idx]
                if ch == "{" { depth += 1 }
                else if ch == "}" {
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
            if let data = objStr.data(using: .utf8),
               let todo = try? decoder.decode(ExtractedTodo.self, from: data) {
                todos.append(todo)
            }
            searchStart = arrayContent.index(after: end)
        }

        return todos.isEmpty ? nil : todos
    }

    // MARK: - Private Methods

    /// 调用 Claude API
    private func callAPI(transcript: String, locale: Locale) async throws -> String {
        let messages = PromptTemplates.buildMessages(for: transcript)

        return try await networkClient.callClaudeAPI(
            systemPrompt: PromptTemplates.systemPrompt(for: locale),
            messages: messages,
            model: NetworkConfig.claudeModel,
            temperature: 0.1,
            maxTokens: 500
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
            throw VoiceTodoError.jsonParsingFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }
}
