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
    /// - Parameter transcript: 用户语音转写文本
    /// - Returns: 提取结果
    func extract(from transcript: String) async throws -> ExtractionResult {
        var lastError: Error?

        // 重试策略：重试 1 次
        for attempt in 0...NetworkConfig.retryCount {
            do {
                // 第一次不等待，重试时等待指定间隔
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: UInt64(NetworkConfig.retryInterval * 1_000_000_000))
                }

                // 调用 API
                let responseText = try await callAPI(transcript: transcript)

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
        let title = truncateTitle(from: transcript)

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

    // MARK: - Private Methods

    /// 调用 Claude API
    private func callAPI(transcript: String) async throws -> String {
        let messages = PromptTemplates.buildMessages(for: transcript)

        return try await networkClient.callClaudeAPI(
            systemPrompt: PromptTemplates.systemPrompt,
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
            let result = try decoder.decode(ExtractionResult.self, from: jsonData)
            return result
        } catch {
            throw VoiceTodoError.jsonParsingFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }
}
