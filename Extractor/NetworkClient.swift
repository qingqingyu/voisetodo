import Foundation

// MARK: - Codable Request/Response Models

/// Claude API 请求体（类型安全）
private struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let temperature: Double
    let system: String
    let messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case temperature
        case system
        case messages
    }
}

/// Claude API 消息
private struct ClaudeMessage: Encodable {
    let role: String
    let content: String
}

// MARK: - NetworkClient

/// Claude API 网络客户端
final class NetworkClient {
    // MARK: - Properties

    private let session: URLSession
    private let apiKey: String?

    // MARK: - Initialization

    init(session: URLSession = .shared) {
        self.session = session

        // 优先从环境变量读取（开发环境），其次从 Keychain 读取（生产环境）
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            self.apiKey = envKey
        } else {
            self.apiKey = KeychainHelper.shared.get(for: .claudeAPIKey)
        }
    }

    // MARK: - Public Methods

    /// 调用 Claude API
    /// - Parameters:
    ///   - systemPrompt: System Prompt
    ///   - messages: 消息数组
    ///   - model: 模型名称
    ///   - temperature: 温度参数
    ///   - maxTokens: 最大 token 数
    /// - Returns: API 响应文本
    func callClaudeAPI(
        systemPrompt: String,
        messages: [[String: String]],
        model: String = NetworkConfig.claudeModel,
        temperature: Double = 0.1,
        maxTokens: Int = 500
    ) async throws -> String {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw VoiceTodoError.apiResponseInvalid("API Key 未配置")
        }

        // 使用 Codable 结构体构建请求体
        let claudeMessages = messages.map { ClaudeMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "") }
        let requestBody = ClaudeRequest(
            model: model,
            maxTokens: maxTokens,
            temperature: temperature,
            system: systemPrompt,
            messages: claudeMessages
        )

        // 创建请求
        guard let url = URL(string: NetworkConfig.apiEndpoint) else {
            throw VoiceTodoError.apiResponseInvalid("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NetworkConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = NetworkConfig.apiTimeout

        // 序列化请求体
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            throw VoiceTodoError.jsonParsingFailed("请求序列化失败: \(error.localizedDescription)")
        }

        // 发送请求
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw VoiceTodoError.networkUnavailable
        }

        // 检查 HTTP 响应
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceTodoError.apiResponseInvalid("无效的 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw VoiceTodoError.apiResponseInvalid("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // 解析响应
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstContent = content.first,
                  let text = firstContent["text"] as? String else {
                throw VoiceTodoError.jsonParsingFailed("响应格式不正确")
            }
            return text
        } catch let error as VoiceTodoError {
            throw error
        } catch {
            throw VoiceTodoError.jsonParsingFailed("响应解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// 将 URLError 映射为 VoiceTodoError
    private func mapURLError(_ error: URLError) -> VoiceTodoError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .networkUnavailable
        case .timedOut:
            return .apiTimeout
        default:
            return .networkUnavailable
        }
    }
}
