import Foundation

// MARK: - Codable Request/Response Models

/// VoiceTodo AI 代理请求体。iOS 端只发送转写文本和语言，不携带供应商密钥或供应商请求格式。
private struct ProxyExtractionRequest: Encodable {
    let transcript: String
    let locale: String
    let stream: Bool
}

// MARK: - SSE Parsing Models

/// 代理流式响应事件
private struct ProxyStreamEvent: Decodable {
    let text: String?
    let delta: String?
}

// MARK: - NetworkClient

/// VoiceTodo AI 代理网络客户端
final class NetworkClient {
    // MARK: - Properties

    private let session: URLSession
    private let proxyEndpoint: String
    private let appToken: String?
    private let deviceIdentifier: String

    // MARK: - Initialization

    init(
        session: URLSession = .shared,
        proxyEndpoint: String = NetworkConfig.proxyEndpoint,
        appToken: String? = NetworkConfig.proxyAppToken,
        deviceIdentifier: String = NetworkConfig.proxyDeviceIdentifier
    ) {
        self.session = session
        self.proxyEndpoint = proxyEndpoint
        self.appToken = appToken
        self.deviceIdentifier = deviceIdentifier
    }

    // MARK: - Public Methods

    /// 调用 VoiceTodo AI 代理
    /// - Parameters:
    ///   - transcript: 语音转写文本
    ///   - localeIdentifier: 语言标识
    /// - Returns: 代理返回的 ExtractionResult JSON 文本
    func callTodoExtractionProxy(
        transcript: String,
        localeIdentifier: String
    ) async throws -> String {
        let request = try buildProxyRequest(transcript: transcript, localeIdentifier: localeIdentifier, stream: false)

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
            if httpResponse.statusCode == 429 {
                throw VoiceTodoError.apiRateLimited
            }
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw VoiceTodoError.apiResponseInvalid("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw VoiceTodoError.apiResponseInvalid("代理返回空响应")
        }
        return text
    }

    /// 调用 VoiceTodo AI 代理（流式 SSE）
    /// - Returns: 逐块返回文本 delta 的 AsyncThrowingStream
    func callTodoExtractionProxyStreaming(
        transcript: String,
        localeIdentifier: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildProxyRequest(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier,
                        stream: true
                    )

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw VoiceTodoError.apiResponseInvalid("Invalid HTTP response")
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        if httpResponse.statusCode == 429 {
                            throw VoiceTodoError.apiRateLimited
                        }
                        throw VoiceTodoError.apiResponseInvalid("HTTP \(httpResponse.statusCode)")
                    }

                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }

                        guard let jsonData = jsonStr.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ProxyStreamEvent.self, from: jsonData)
                        else { continue }

                        if let text = event.text ?? event.delta, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    continuation.finish(throwing: mapURLError(urlError))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Methods

    private func buildProxyRequest(
        transcript: String,
        localeIdentifier: String,
        stream: Bool
    ) throws -> URLRequest {
        let trimmedEndpoint = proxyEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty,
              let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme,
              Self.isAllowedProxyScheme(scheme, host: url.host) else {
            throw VoiceTodoError.apiResponseInvalid("AI proxy URL 未配置")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let appToken, !appToken.isEmpty {
            request.setValue(appToken, forHTTPHeaderField: "X-App-Token")
        }
        if !deviceIdentifier.isEmpty {
            request.setValue(deviceIdentifier, forHTTPHeaderField: "X-Device-ID")
        }
        request.timeoutInterval = NetworkConfig.apiTimeout

        do {
            request.httpBody = try JSONEncoder().encode(
                ProxyExtractionRequest(
                    transcript: transcript,
                    locale: localeIdentifier,
                    stream: stream
                )
            )
            return request
        } catch {
            throw VoiceTodoError.jsonParsingFailed("请求序列化失败: \(error.localizedDescription)")
        }
    }

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

    private static func isAllowedProxyScheme(_ scheme: String, host: String?) -> Bool {
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            return false
        }
        guard normalizedScheme == "http" else {
            return true
        }
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
