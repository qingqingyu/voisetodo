import Foundation

// MARK: - Codable Request/Response Models

/// VoiceTodo AI 代理请求体。iOS 端只发送转写文本和语言，不携带供应商密钥或供应商请求格式。
/// `mode`:nil / "extract" = 待办提取(默认);"split" = 任务拆小(2026-08-23 拆小改版,
/// 代理侧不计费、不缓存、不支持流式)。
private struct ProxyExtractionRequest: Encodable {
    let transcript: String
    let locale: String
    let stream: Bool
    let vocabularyHints: [String]?
    let personalHints: String?
    let mode: String?
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
    ///   - transcript: 语音转写文本(split 模式下为任务标题或口述段落)
    ///   - localeIdentifier: 语言标识
    ///   - mode: nil = 提取(默认);"split" = 任务拆小;"reflect" = 复盘笔记关注点提取
    ///     (split/reflect 代理侧均不计费/不缓存,stream 恒为 false)
    /// - Returns: 代理返回的 JSON 文本(提取模式为 ExtractionResult,split 模式为 {"steps":[...]},reflect 模式为 {"topics":[...]})
    func callTodoExtractionProxy(
        transcript: String,
        localeIdentifier: String,
        vocabularyHints: [String] = [],
        personalHints: String? = nil,
        mode: String? = nil
    ) async throws -> String {
        let requestID = VoiceTodoLog.makeID("proxy")
        let extractID = VoiceTodoLog.extractID ?? "none"
        let startedAt = Date()
        VoiceTodoLog.network.info("proxy.request.start id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) stream=false mode=\(mode ?? "extract", privacy: .public) locale=\(localeIdentifier, privacy: .public) vocabularyHints=\(vocabularyHints.count) personalHints=\(personalHints != nil, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public) endpoint=\(self.endpointSummary(), privacy: .public)")

        let subscriptionJWS = await subscriptionJWSProvider()
        // 与 buildProxyRequest 的发送条件同口径：只有非空 JWS 才真的发出凭证头。
        // 供额度模型区分「订阅前的旧 free 快照」与「带了凭证仍被代理按 free 计」
        // （后者 = 代理拒了这份订阅，展示层不得再过渡到 Pro 档）。
        let carriedSubscriptionJWS = !(subscriptionJWS?.isEmpty ?? true)
        let request: URLRequest
        do {
            request = try buildProxyRequest(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                stream: false,
                vocabularyHints: vocabularyHints,
                personalHints: personalHints,
                mode: mode,
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
        // 阶段 0 埋点:DNS/TCP/TLS/TTFB 拆解(只记日志,不改行为)
        let metricsCollector = Self.makeMetricsCollector(requestID: requestID, extractID: extractID, event: "proxy.request.metrics")
        do {
            // T1(任务书 §5.1):解析请求发出时刻。重试只记第一次(时间点由
            // tracker 的 first-write-wins 保证)。
            VoiceTodoLog.extractTiming?.markRequestSent(ContinuousClock().now)
            (data, response) = try await session.data(for: request, delegate: metricsCollector)
        } catch let urlError as URLError {
            VoiceTodoLog.network.error("proxy.request.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) path=\(VoiceTodoLog.requestPath, privacy: .public) stage=\(Self.stageForURLError(urlError), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) urlError=\(String(describing: urlError), privacy: .public) code=\(urlError.code.rawValue)")
            throw mapURLError(urlError)
        } catch {
            VoiceTodoLog.network.error("proxy.request.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) path=\(VoiceTodoLog.requestPath, privacy: .public) stage=unknown_class durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
            await pushQuotaHeaders(httpResponse, carriedSubscriptionJWS: carriedSubscriptionJWS)
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

        await pushQuotaHeaders(httpResponse, carriedSubscriptionJWS: carriedSubscriptionJWS)

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
                    // 同非流式路径：凭证是否真的随请求发出，喂给额度模型做拒绝判定。
                    let carriedSubscriptionJWS = !(subscriptionJWS?.isEmpty ?? true)
                    let request = try buildProxyRequest(
                        transcript: transcript,
                        localeIdentifier: localeIdentifier,
                        stream: true,
                        vocabularyHints: vocabularyHints,
                        personalHints: personalHints,
                        mode: nil, // split 不支持流式,流式路径恒为提取模式
                        requestID: requestID,
                        extractID: extractID,
                        subscriptionJWS: subscriptionJWS
                    )

                    // T1(任务书 §5.1):流式请求发出时刻(first-write-wins)。
                    VoiceTodoLog.extractTiming?.markRequestSent(ContinuousClock().now)
                    // 阶段 0 埋点:DNS/TCP/TLS/TTFB 拆解(只记日志,不改行为)
                    let metricsCollector = Self.makeMetricsCollector(requestID: requestID, extractID: extractID, event: "proxy.stream.metrics")
                    let (bytes, response) = try await session.bytes(for: request, delegate: metricsCollector)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        VoiceTodoLog.network.error("proxy.stream.invalid_response id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) response=\(String(describing: response), privacy: .public)")
                        throw VoiceTodoError.apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail)
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        VoiceTodoLog.network.error("proxy.stream.http_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) status=\(httpResponse.statusCode) rateLimitType=\(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Type") ?? "nil", privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                        await pushQuotaHeaders(httpResponse, carriedSubscriptionJWS: carriedSubscriptionJWS)
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
                    await pushQuotaHeaders(httpResponse, carriedSubscriptionJWS: carriedSubscriptionJWS)
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
                    VoiceTodoLog.network.error("proxy.stream.transport_failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) path=\(VoiceTodoLog.requestPath, privacy: .public) stage=\(Self.stageForURLError(urlError), privacy: .public) deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) urlError=\(String(describing: urlError), privacy: .public) code=\(urlError.code.rawValue)")
                    continuation.finish(throwing: mapURLError(urlError))
                } catch {
                    VoiceTodoLog.network.error("proxy.stream.failed id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) path=\(VoiceTodoLog.requestPath, privacy: .public) stage=unknown_class deltas=\(deltaCount) totalChars=\(totalChars) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                VoiceTodoLog.network.debug("proxy.stream.terminated id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) reason=\(String(describing: termination), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                task.cancel()
            }
        }
    }

    // MARK: - Connection Warm-Up

    /// 连接预热：对代理 origin 发 `HEAD /v1/health`，让 DNS + TCP + TLS 握手
    /// 在用户说话期间完成（同一 `session` 实例共享连接池，解析请求直接复用）。
    ///
    /// 尽力而为：失败只记日志、绝不抛——预热失败不代表解析会失败（离线、
    /// 代理冷启动慢都是正常场景），不能让它干扰录音流程；解析请求自身有
    /// 完整的错误分类与熔断，预热失败不进任何失败统计。
    func warmUpConnection() async {
        let trimmedEndpoint = proxyEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedEndpoint) else {
            VoiceTodoLog.network.debug("proxy.warmup.skipped reason=invalid_endpoint")
            return
        }
        components.path = "/v1/health"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            VoiceTodoLog.network.debug("proxy.warmup.skipped reason=invalid_health_url")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = NetworkConfig.connectionWarmUpTimeout
        let startedAt = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            VoiceTodoLog.network.info("proxy.warmup.success status=\(status) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } catch {
            VoiceTodoLog.network.debug("proxy.warmup.failed durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error))")
        }
    }

    // MARK: - Private Methods

    private func buildProxyRequest(
        transcript: String,
        localeIdentifier: String,
        stream: Bool,
        vocabularyHints: [String],
        personalHints: String?,
        mode: String?,
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
                    personalHints: personalHints,
                    mode: mode
                )
            )
            return request
        } catch {
            VoiceTodoLog.network.error("proxy.request.encode_failed stream=\(stream) locale=\(localeIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.jsonParsingFailed("请求序列化失败: \(error.localizedDescription)")
        }
    }

    /// 把代理 `X-Quota-*` 响应头推送给额度模型（权威数据源）。
    /// `carriedSubscriptionJWS`：本次请求是否实际携带了订阅凭证，额度模型据此
    /// 区分「订阅前的旧 free 快照」与「带了凭证仍被代理按 free 计」（后者是被拒）。
    private func pushQuotaHeaders(_ response: HTTPURLResponse, carriedSubscriptionJWS: Bool) async {
        guard let quotaProvider else { return }
        await quotaProvider.applyQuotaHeaders(from: response, carriedSubscriptionJWS: carriedSubscriptionJWS)
    }

    /// 区分配额耗尽（quota_exceeded → paywall）、出口 IP 当日配额（ip_daily → 离线兜底 + 明日再试）、
    /// 与短时限流（velocity → 稍后重试）。
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
        // ip_daily 当天不可恢复 → 专属 case，调用方据此跳过重试 + 显示"明天再试"文案
        if rateLimitType == "ip_daily" {
            return .ipRateLimited(retryAfter: retryAfter)
        }
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

    /// 将 URLError 映射为调用方能分类的 Error。
    ///
    /// `.cancelled` 单独抽出来映射成 Swift 原生 `CancellationError`，**不是** VoiceTodoError：
    /// 取消由用户发起（关掉确认弹层 / 开始新一次录音 / 确认成功后主动收流），不是服务故障。
    /// 旧代码让它落进 `default:` → `.networkUnavailable` → `countsAsServiceFailure` 为 true
    /// → 喂进熔断器。三次划走弹层就能把远端 AI 静默熔断掉，这是「远端服务间歇性不生效」
    /// 的客户端主因。
    ///
    /// 用 `CancellationError` 而不是新增 VoiceTodoError case，是为了让所有
    /// `error as? VoiceTodoError` 的分支自然不匹配——不需要新增本地化文案
    /// （一条永远不该展示给用户的文案），也不会漏改某个 switch。
    /// 注意 `stageForURLError` 早就把 `.cancelled` 记成 `stage=cancelled`，日志和错误分类现在一致了。
    private func mapURLError(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost:
            return VoiceTodoError.networkUnavailable
        case .timedOut:
            return VoiceTodoError.apiTimeout
        default:
            return VoiceTodoError.networkUnavailable
        }
    }

    /// 把 URLError.code 映射成人类可读的 stage 字符串,用于 transport_failed 日志。
    /// 没 URLSessionTaskMetrics 时,这是唯一能区分"超时发生在哪一段"的线索。
    /// 命名约定:`<阶段>_<表现>`,如 `timeout_total`(总超时,无法细分)、`offline`、`mid_stream`。
    /// `_total` 后缀表示 URLSession 没拆细的整段超时;有 metrics 后会被 dns/tcp/tls/ttfb 取代。
    private static func stageForURLError(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "timeout_total"
        case .notConnectedToInternet: return "offline"
        case .networkConnectionLost: return "mid_stream"
        case .dnsLookupFailed, .cannotFindHost: return "dns"
        case .cannotConnectToHost: return "tcp_connect"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "tls"
        case .cancelled: return "cancelled"
        default: return "unknown"
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

    // MARK: - Task Metrics(阶段 0 埋点)

    /// 造一个 TaskMetrics 采集器:任务收尾时把 DNS/TCP/TLS/TTFB 拆解记进网络日志。
    /// didFinishCollecting 由 URLSession 在任务收尾后回调(可能晚于流结束),
    /// 因此日志在回调内直接打,不依赖调用方时序。
    private static func makeMetricsCollector(requestID: String, extractID: String, event: String) -> ProxyTaskMetricsCollector {
        ProxyTaskMetricsCollector { metrics in
            VoiceTodoLog.network.info("\(event, privacy: .public) id=\(requestID, privacy: .public) extractID=\(extractID, privacy: .public) \(Self.summarizeTaskMetrics(metrics), privacy: .public)")
        }
    }

    /// 把 TaskMetrics 首个网络事务拆成 DNS/TCP/TLS/TTFB 毫秒数。复用连接时
    /// DNS/TCP/TLS 均省略(只有 ttfb);阶段缺失或时钟倒挂时对应段不输出。
    /// 命名与 `stageForURLError` 的 dns/tcp_connect/tls 对齐,便于日志联动排查。
    private static func summarizeTaskMetrics(_ metrics: URLSessionTaskMetrics) -> String {
        guard let m = metrics.transactionMetrics.first(where: { $0.resourceFetchType == .networkLoad })
            ?? metrics.transactionMetrics.first else {
            return "fetchType=none"
        }
        func ms(_ from: Date?, _ to: Date?) -> Int? {
            guard let from, let to, to >= from else { return nil }
            return Int(to.timeIntervalSince(from) * 1000)
        }
        var parts: [String] = []
        if let dns = ms(m.domainLookupStartDate, m.domainLookupEndDate) { parts.append("dns=\(dns)ms") }
        if let connect = ms(m.connectStartDate, m.connectEndDate) { parts.append("connect=\(connect)ms") }
        if let tls = ms(m.secureConnectionStartDate, m.secureConnectionEndDate) { parts.append("tls=\(tls)ms") }
        if let ttfb = ms(m.requestStartDate, m.responseStartDate) { parts.append("ttfb=\(ttfb)ms") }
        // 连接复用判定不用已废弃的 isReusedConnection:复用连接没有
        // DNS/connect 阶段,networkLoad 且无 connect 即视为复用
        let reused = m.resourceFetchType == .networkLoad && m.connectStartDate == nil
        parts.append("protocol=\(m.networkProtocolName ?? "unknown")")
        parts.append("reused=\(reused ? 1 : 0)")
        return parts.joined(separator: " ")
    }

    /// 单次任务的 metrics 采集 delegate。只实现 didFinishCollecting;
    /// @unchecked Sendable:可变状态(logged)全部经 lock 访问。
    private final class ProxyTaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let log: (URLSessionTaskMetrics) -> Void
        private let lock = NSLock()
        private var logged = false

        init(log: @escaping (URLSessionTaskMetrics) -> Void) {
            self.log = log
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock()
            defer { lock.unlock() }
            guard !logged else { return }
            logged = true
            log(metrics)
        }
    }
}
