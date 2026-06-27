import Foundation

// MARK: - Codable Request/Response Models

/// VoiceTodo AI 代理请求体。iOS 端只发送转写文本和语言，不携带供应商密钥或供应商请求格式。
private struct ProxyExtractionRequest: Encodable {
    let transcript: String
    let locale: String
    let stream: Bool
    let vocabularyHints: [String]?
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
        localeIdentifier: String,
        vocabularyHints: [String] = []
    ) async throws -> String {
        let requestID = VoiceTodoLog.makeID("proxy")
        let extractID = VoiceTodoLog.extractID ?? "none"
        let startedAt = Date()
        VoiceTodoLog.network.info("proxy.request.start id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) stream=false locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) \(VoiceTodoLog.textSummary(transcript), privacy: .public) endpoint=\(self.endpointSummary(), privacy: .public)")

        let request: URLRequest
        do {
            request = try buildProxyRequest(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                stream: false,
                vocabularyHints: vocabularyHints,
                requestID: requestID,
                extractID: extractID
            )
        } catch {
            VoiceTodoLog.network.error("proxy.request.build_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw error
        }

        // 发送请求
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            VoiceTodoLog.network.error("proxy.request.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) urlError=\(String(describing: urlError), privacy: .public) code=\(urlError.code.rawValue)")
            throw mapURLError(urlError)
        } catch {
            VoiceTodoLog.network.error("proxy.request.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.networkUnavailable
        }

        // 检查 HTTP 响应
        guard let httpResponse = response as? HTTPURLResponse else {
            VoiceTodoLog.network.error("proxy.request.invalid_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) response=\(String(describing: response), privacy: .public)")
            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            VoiceTodoLog.network.error("proxy.request.http_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) responseBytes=\(data.count) bodyChars=\(errorMessage.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            if httpResponse.statusCode == 429 {
                throw VoiceTodoError.apiRateLimited(retryAfter: Self.parseRetryAfter(httpResponse))
            }
            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            VoiceTodoLog.network.error("proxy.request.empty_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) responseBytes=\(data.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
        }
        VoiceTodoLog.network.info("proxy.request.success id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) responseBytes=\(data.count) responseChars=\(text.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return text
    }

    /// 调用 VoiceTodo AI 代理（流式 SSE）
    /// - Returns: 逐块返回文本 delta 的 AsyncThrowingStream
    func callTodoExtractionProxyStreaming(
        transcript: String,
        localeIdentifier: String,
        vocabularyHints: [String] = []
    ) -> AsyncThrowingStream<String, Error> {
        let requestID = VoiceTodoLog.makeID("stream")
        let extractID = VoiceTodoLog.extractID ?? "none"
        let startedAt = Date()
        VoiceTodoLog.network.info("proxy.stream.start id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) \(VoiceTodoLog.textSummary(transcript), privacy: .public) endpoint=\(self.endpointSummary(), privacy: .public)")

        return AsyncThrowingStream { continuation in
            let task = Task {
                var deltaCount = 0
                var totalChars = 0
                var receivedDone = false
                do {
                    let request = try buildProxyRequest(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier,
                        stream: true,
                        vocabularyHints: vocabularyHints,
                        requestID: requestID,
                        extractID: extractID
                    )

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        VoiceTodoLog.network.error("proxy.stream.invalid_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) response=\(String(describing: response), privacy: .public)")
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        VoiceTodoLog.network.error("proxy.stream.http_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        if httpResponse.statusCode == 429 {
                            throw VoiceTodoError.apiRateLimited(retryAfter: Self.parseRetryAfter(httpResponse))
                        }
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    VoiceTodoLog.network.info("proxy.stream.connected id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" {
                            receivedDone = true
                            break
                        }

                        guard let jsonData = jsonStr.data(using: .utf8) else {
                            VoiceTodoLog.network.error("proxy.stream.invalid_event_encoding id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) eventChars=\(jsonStr.count)")
                            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                        }

                        let event: ProxyStreamEvent
                        do {
                            event = try JSONDecoder().decode(ProxyStreamEvent.self, from: jsonData)
                        } catch {
                            VoiceTodoLog.network.error("proxy.stream.invalid_event_json id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) eventChars=\(jsonStr.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                        }

                        if let text = event.text ?? event.delta, !text.isEmpty {
                            deltaCount += 1
                            totalChars += text.count
                            VoiceTodoLog.network.debug("proxy.stream.delta id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(deltaCount) chars=\(text.count)")
                            continuation.yield(text)
                        }
                    }

                    guard receivedDone else {
                        VoiceTodoLog.network.error("proxy.stream.missing_done id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    VoiceTodoLog.network.info("proxy.stream.finished id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    continuation.finish()
                } catch let urlError as URLError {
                    VoiceTodoLog.network.error("proxy.stream.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) urlError=\(String(describing: urlError), privacy: .public) code=\(urlError.code.rawValue)")
                    continuation.finish(throwing: mapURLError(urlError))
                } catch {
                    VoiceTodoLog.network.error("proxy.stream.failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                VoiceTodoLog.network.debug("proxy.stream.terminated id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) reason=\(String(describing: termination), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                task.cancel()
            }
        }
    }

    // MARK: - Private Methods

    private func buildProxyRequest(
        transcript: String,
        localeIdentifier: String,
        stream: Bool,
        vocabularyHints: [String],
        requestID: String,
        extractID: String
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
        // 跨端链路追踪：requestID 标识单次请求，extractID 串联一次提取（含重试）
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        if extractID != "none" {
            request.setValue(extractID, forHTTPHeaderField: "X-Extract-ID")
        }
        request.timeoutInterval = NetworkConfig.apiTimeout

        do {
            request.httpBody = try JSONEncoder().encode(
                ProxyExtractionRequest(
                    transcript: transcript,
                    locale: localeIdentifier,
                    stream: stream,
                    vocabularyHints: vocabularyHints.isEmpty ? nil : vocabularyHints
                )
            )
            return request
        } catch {
            VoiceTodoLog.network.error("proxy.request.encode_failed stream=\(stream) locale=\(localeIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.jsonParsingFailed("请求序列化失败: \(error.localizedDescription)")
        }
    }

    /// 解析 Retry-After 响应头（仅支持 delta-seconds 形式；HTTP-date 形式返回 nil）
    private static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(raw),
              seconds >= 0 else {
            return nil
        }
        return seconds
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

    private func endpointSummary() -> String {
        let trimmedEndpoint = proxyEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint) else {
            return "invalid"
        }
        return "\(url.scheme ?? "unknown")://\(url.host ?? "missing-host")\(url.path)"
    }
}
