import Foundation

// MARK: - Codable Request/Response Models

/// VoiceTodo AI 代理请求体。iOS 端只发送转写文本和语言，不携带供应商密钥或供应商请求格式。
private struct ProxyExtractionRequest: Encodable {
    let transcript: String
    let locale: String
    let stream: Bool
    let vocabularyHints: [String]?
    let personalHints: String?
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
    /// 订阅 JWS 提供者（StoreKit 2 EntitlementManager）。nil → 不发 X-Subscription-JWS，代理按免费档处理。
    private let subscriptionJWSProvider: @MainActor () -> String?
    /// 额度模型（权威数据来自代理 X-Quota-* 头）。nil → 不更新额度展示。
    private weak var quotaProvider: (any QuotaProviding)?

    // MARK: - Initialization

    init(
        session: URLSession = .shared,
        proxyEndpoint: String = NetworkConfig.proxyEndpoint,
        appToken: String? = NetworkConfig.proxyAppToken,
        deviceIdentifier: String = NetworkConfig.proxyDeviceIdentifier,
        subscriptionJWSProvider: @escaping @MainActor () -> String? = { nil },
        quotaProvider: (any QuotaProviding)? = nil
    ) {
        self.session = session
        self.proxyEndpoint = proxyEndpoint
        self.appToken = appToken
        self.deviceIdentifier = deviceIdentifier
        self.subscriptionJWSProvider = subscriptionJWSProvider
        self.quotaProvider = quotaProvider
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
        vocabularyHints: [String] = [],
        personalHints: String? = nil
    ) async throws -> String {
        let requestID = VoiceTodoLog.makeID("proxy")
        let extractID = VoiceTodoLog.extractID ?? "none"
        let startedAt = Date()
        VoiceTodoLog.network.info("proxy.request.start id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) stream=false locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) personalHints=\(personalHints != nil, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public) endpoint=\(self.endpointSummary(), privacy: .public)")

        let request: URLRequest
        do {
            let subscriptionJWS = await subscriptionJWSProvider()
            request = try buildProxyRequest(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                stream: false,
                vocabularyHints: vocabularyHints,
                personalHints: personalHints,
                requestID: requestID,
                extractID: extractID,
                subscriptionJWS: subscriptionJWS
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
            VoiceTodoLog.network.error("proxy.request.http_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) rateLimitType=\(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Type") ?? "nil", privacy: .public) responseBytes=\(data.count) bodyChars=\(errorMessage.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            // 配额耗尽的 429 也携带 X-Quota-* 头，先喂给额度模型再抛错。
            await pushQuotaHeaders(httpResponse)
            if httpResponse.statusCode == 429 {
                throw Self.classify429(httpResponse, body: data)
            }
            if httpResponse.statusCode == 503 {
                throw VoiceTodoError.serviceUnavailable
            }
            if (500...599).contains(httpResponse.statusCode) {
                throw VoiceTodoError.apiServerError(statusCode: httpResponse.statusCode)
            }
            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
        }

        await pushQuotaHeaders(httpResponse)

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            VoiceTodoLog.network.error("proxy.request.empty_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) responseBytes=\(data.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
        }
        VoiceTodoLog.network.info("proxy.request.success id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) plan=\(httpResponse.value(forHTTPHeaderField: "X-Quota-Plan") ?? "nil", privacy: .public) remaining=\(httpResponse.value(forHTTPHeaderField: "X-Quota-Remaining") ?? "nil", privacy: .public) responseBytes=\(data.count) responseChars=\(text.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return text
    }

    /// 调用 VoiceTodo AI 代理（流式 SSE）
    /// - Returns: 逐块返回文本 delta 的 AsyncThrowingStream
    func callTodoExtractionProxyStreaming(
        transcript: String,
        localeIdentifier: String,
        vocabularyHints: [String] = [],
        personalHints: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let requestID = VoiceTodoLog.makeID("stream")
        let extractID = VoiceTodoLog.extractID ?? "none"
        let startedAt = Date()
        VoiceTodoLog.network.info("proxy.stream.start id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) personalHints=\(personalHints != nil, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public) endpoint=\(self.endpointSummary(), privacy: .public)")

        return AsyncThrowingStream { continuation in
            let task = Task {
                var deltaCount = 0
                var totalChars = 0
                var receivedDone = false
                do {
                    let subscriptionJWS = await subscriptionJWSProvider()
                    let request = try buildProxyRequest(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier,
                        stream: true,
                        vocabularyHints: vocabularyHints,
                        personalHints: personalHints,
                        requestID: requestID,
                        extractID: extractID,
                        subscriptionJWS: subscriptionJWS
                    )

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        VoiceTodoLog.network.error("proxy.stream.invalid_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) response=\(String(describing: response), privacy: .public)")
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        VoiceTodoLog.network.error("proxy.stream.http_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) rateLimitType=\(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Type") ?? "nil", privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        await pushQuotaHeaders(httpResponse)
                        if httpResponse.statusCode == 429 {
                            throw Self.classify429(httpResponse, body: nil)
                        }
                        if httpResponse.statusCode == 503 {
                            throw VoiceTodoError.serviceUnavailable
                        }
                        if (500...599).contains(httpResponse.statusCode) {
                            throw VoiceTodoError.apiServerError(statusCode: httpResponse.statusCode)
                        }
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    await pushQuotaHeaders(httpResponse)
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
                            event = try JSONCoding.makeResponseDecoder().decode(ProxyStreamEvent.self, from: jsonData)
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
        personalHints: String?,
        requestID: String,
        extractID: String,
        subscriptionJWS: String?
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
        // 设备时区本地日期：代理据此分桶配额，服务端做漂移校验后回退 UTC。
        request.setValue(QuotaUsage.currentLocalDate(), forHTTPHeaderField: "X-Local-Date")
        // 订阅凭证：Pro 档 JWS。nil 不发，代理按免费档处理。
        if let subscriptionJWS, !subscriptionJWS.isEmpty {
            request.setValue(subscriptionJWS, forHTTPHeaderField: "X-Subscription-JWS")
        }
        // 跨端链路追踪：requestID 标识单次请求，extractID 串联一次提取（含重试）
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        if extractID != "none" {
            request.setValue(extractID, forHTTPHeaderField: "X-Extract-ID")
        }
        request.timeoutInterval = NetworkConfig.apiTimeout

        do {
            request.httpBody = try JSONCoding.makeRequestEncoder().encode(
                ProxyExtractionRequest(
                    transcript: transcript,
                    locale: localeIdentifier,
                    stream: stream,
                    vocabularyHints: vocabularyHints.isEmpty ? nil : vocabularyHints,
                    personalHints: personalHints
                )
            )
            return request
        } catch {
            VoiceTodoLog.network.error("proxy.request.encode_failed stream=\(stream) locale=\(localeIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.jsonParsingFailed("请求序列化失败: \(error.localizedDescription)")
        }
    }

    /// 把代理 `X-Quota-*` 响应头推送给额度模型（权威数据源）。
    private func pushQuotaHeaders(_ response: HTTPURLResponse) async {
        guard let quotaProvider else { return }
        await quotaProvider.applyQuotaHeaders(from: response)
    }

    /// 区分配额耗尽（quota_exceeded → 离线兜底 + paywall）与限流（rate_limited → 稍后重试）。
    /// 非流式传完整 body；流式传 nil，仅凭 `X-RateLimit-Type` 头分类（429 响应体很小，头已足够）。
    private static func classify429(_ response: HTTPURLResponse, body data: Data?) -> VoiceTodoError {
        let parsed = parseRateLimitBody(data)
        let rateLimitType = response.value(forHTTPHeaderField: "X-RateLimit-Type")
        let errorCode = parsed.errorCode ?? (rateLimitType == "quota" ? "quota_exceeded" : "rate_limited")

        if errorCode == "quota_exceeded" {
            let tier = parsed.tier
                ?? response.value(forHTTPHeaderField: "X-Quota-Plan")
                ?? "free"
            let resetAt = parsed.resetAt
                ?? response.value(forHTTPHeaderField: "X-Quota-Reset-Date")
                ?? ""
            return .quotaExhausted(tier: tier, resetAt: resetAt)
        }
        let retryAfter = parsed.retryAfter ?? Self.parseRetryAfter(response)
        return .rateLimited(retryAfter: retryAfter)
    }

    private struct RateLimitBody: Decodable {
        let error: String?
        let tier: String?
        let resetAt: String?
        let retryAfter: Double?
    }

    private static func parseRateLimitBody(_ data: Data?) -> (errorCode: String?, tier: String?, resetAt: String?, retryAfter: TimeInterval?) {
        guard let data else { return (nil, nil, nil, nil) }
        guard let body = try? JSONCoding.makeResponseDecoder().decode(RateLimitBody.self, from: data) else {
            return (nil, nil, nil, nil)
        }
        return (body.error, body.tier, body.resetAt, body.retryAfter)
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
