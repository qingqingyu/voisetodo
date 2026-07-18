import XCTest
@testable import VoiceTodo

final class ExtractorTests: XCTestCase {
    // MARK: - Properties

    var sut: TodoExtractorService!
    private var mockNetworkClient: MockNetworkClient!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        mockNetworkClient = MockNetworkClient()
        sut = TodoExtractorService(
            networkClient: mockNetworkClient.networkClient,
            vocabularyProvider: StaticExtractorVocabularyProvider(hints: []),
            sleep: { _ in }  // 注入空退避，消除真实 sleep 耗时
        )
    }

    override func tearDown() {
        URLProtocolStub.reset()
        sut = nil
        mockNetworkClient = nil
        super.tearDown()
    }

    // MARK: - Test Normal JSON Parsing

    func testNormalJSONParsing() async throws {
        // Given: 正常的 JSON 响应
        let jsonResponse = """
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440000",
              "title": "去银行办卡",
              "detail": "明天去银行办卡",
              "due_hint": "明天",
              "priority": "normal",
              "category_hint": "finance"
            }
          ],
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        // When: 调用 extract
        let result = try await sut.extract(from: "明天去银行办卡", locale: Locale(identifier: "zh-Hans"))

        // Then: 正确解析
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[0].categoryHint, .finance)
        XCTAssertEqual(result.todos[0].priority, .normal)
        XCTAssertEqual(result.todos[0].dueHint, "明天")
    }

    func testNetworkClientRequestsProxyWithoutVendorAPIKey() async throws {
        setenv("ANTHROPIC_API_KEY", "must-not-be-used", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }

        let jsonResponse = """
        {
          "todos": [
            {
              "title": "去银行办卡",
              "detail": "明天去银行办卡",
              "due_hint": "明天",
              "priority": "normal",
              "category_hint": "finance"
            }
          ],
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        _ = try await sut.extract(from: "明天去银行办卡", locale: Locale(identifier: "zh-Hans"))

        let request = try XCTUnwrap(URLProtocolStub.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.test/v1/todo-extractions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Token"), "test-app-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-ID"), "test-device-id")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))

        let body = try XCTUnwrap(URLProtocolStub.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["transcript"] as? String, "明天去银行办卡")
        XCTAssertEqual(json["locale"] as? String, "zh-Hans")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["vocabularyHints"])
    }

    func testNetworkClientSendsVocabularyHintsToProxy() async throws {
        sut = TodoExtractorService(
            networkClient: mockNetworkClient.networkClient,
            vocabularyProvider: StaticExtractorVocabularyProvider(hints: ["Anki", "IELTS", "雅思"])
        )
        mockNetworkClient.enqueueSuccess(text: """
        {
          "todos": [],
          "ignored": ""
        }
        """)

        _ = try await sut.extract(from: "今天复习", locale: Locale(identifier: "zh-Hans"))

        let body = try XCTUnwrap(URLProtocolStub.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["vocabularyHints"] as? [String], ["Anki", "IELTS", "雅思"])
        XCTAssertNil(URLProtocolStub.requests.last?.value(forHTTPHeaderField: "x-api-key"))
    }

    /// P4: 请求应携带跨端追踪头 X-Request-ID。
    func testProxyRequestIncludesTraceHeader() async throws {
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")
        _ = try await sut.extract(from: "追踪", locale: Locale(identifier: "zh-Hans"))
        let request = try XCTUnwrap(URLProtocolStub.requests.last)
        XCTAssertFalse((request.value(forHTTPHeaderField: "X-Request-ID") ?? "").isEmpty, "应携带 X-Request-ID 追踪头")
    }

    func testProxyRequestIncludesQuotaDateAndSubscriptionHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let client = NetworkClient(
            session: session,
            proxyEndpoint: "https://proxy.test/v1/todo-extractions",
            appToken: "test-app-token",
            deviceIdentifier: "test-device-id",
            subscriptionJWSProvider: { "signed-jws" }
        )
        sut = TodoExtractorService(
            networkClient: client,
            vocabularyProvider: StaticExtractorVocabularyProvider(hints: []),
            sleep: { _ in }
        )
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")

        _ = try await sut.extract(from: "订阅请求头", locale: Locale(identifier: "zh-Hans"))

        let request = try XCTUnwrap(URLProtocolStub.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-JWS"), "signed-jws")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Local-Date"), QuotaUsage.currentLocalDate())
    }

    func testNetworkClientRejectsNonLocalHTTPProxyEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let client = NetworkClient(
            session: session,
            proxyEndpoint: "http://proxy.test/v1/todo-extractions",
            appToken: "test-app-token",
            deviceIdentifier: "test-device-id"
        )

        do {
            _ = try await client.callTodoExtractionProxy(
                transcript: "明天去银行办卡",
                localeIdentifier: "zh-Hans"
            )
            XCTFail("应该拒绝非本机 HTTP 代理地址")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .apiResponseInvalid("AI proxy URL 未配置"))
            XCTAssertEqual(URLProtocolStub.callCount, 0)
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }
    }

    func testParsingWithoutIdGeneratesUUID() async throws {
        let jsonResponse = """
        {
          "todos": [
            {
              "title": "去银行办卡",
              "detail": "明天去银行办卡",
              "due_hint": "明天",
              "priority": "normal",
              "category_hint": "finance"
            }
          ],
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        let result = try await sut.extract(from: "明天去银行办卡", locale: Locale(identifier: "zh-Hans"))

        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[0].categoryHint, .finance)
    }

    // MARK: - Test Malformed JSON (Markdown Wrapped)

    func testMalformedJSONWithMarkdownWrapper() async throws {
        // Given: markdown 包裹的 JSON
        let jsonResponse = """
        ```json
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440001",
              "title": "准备面试",
              "detail": "准备下周的面试",
              "due_hint": "下周",
              "priority": "high",
              "category_hint": "work"
            }
          ],
          "ignored": ""
        }
        ```
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        // When: 调用 extract
        let result = try await sut.extract(from: "准备下周的面试", locale: Locale(identifier: "zh-Hans"))

        // Then: 仍能正确解析
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "准备面试")
        XCTAssertEqual(result.todos[0].priority, .high)
    }

    func testMalformedJSONWithSimpleCodeBlock() async throws {
        // Given: 简单代码块包裹的 JSON
        let jsonResponse = """
        ```
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440002",
              "title": "买菜",
              "detail": "晚上买菜",
              "due_hint": "晚上",
              "priority": "normal",
              "category_hint": "life"
            }
          ],
          "ignored": ""
        }
        ```
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        // When: 调用 extract
        let result = try await sut.extract(from: "晚上买菜", locale: Locale(identifier: "zh-Hans"))

        // Then: 仍能正确解析
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "买菜")
    }

    // MARK: - Test Truncated JSON (max_tokens 截断 → transcriptTooLong)

    func testTruncatedJSONThrowsTranscriptTooLong() async {
        // Given: AI 输出被 max_tokens 强制截断 —— JSON 末尾不完整(没有闭合 `]` 和 `}`)
        // 错误结构:顶层 DecodingError.dataCorrupted(NSCocoaErrorDomain 4864),
        // 它的 underlyingError 是 NSCocoaErrorDomain 3840 + NSDebugDescription 含 "end of file"。
        // isJsonTruncationError 需要遍历 underlyingError 链才能命中。
        let truncatedJSON = """
        {
          "todos": [
            {"id": "A", "title": "买菜", "detail": "晚上买菜"},
            {"id": "B", "title": "做饭
        """

        mockNetworkClient.enqueueSuccess(text: truncatedJSON)

        // When & Then: 抛 transcriptTooLong(而非 jsonParsingFailed),提示用户分批输入
        do {
            _ = try await sut.extract(from: "测试截断", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出 transcriptTooLong")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .transcriptTooLong, "截断的 JSON 必须映射为 transcriptTooLong,实际: \(error)")
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }

        // 不重试 —— 用户可解决的错误重试无意义
        XCTAssertEqual(URLProtocolStub.callCount, 1)
    }

    func testSchemaMismatchThrowsJsonParsingFailed() async {
        // Given: 完整的 JSON 但 schema 不匹配(todos 字段类型错误,非数组)
        // JSON 解析会失败,但不是截断类(NSDebugDescription 不含 "end of file")
        let schemaMismatchJSON = """
        {
          "todos": "这不是数组",
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueSuccess(text: schemaMismatchJSON)

        // When & Then: 抛 jsonParsingFailed(而非 transcriptTooLong)—— 用户输入没问题,重试或上层兜底
        do {
            _ = try await sut.extract(from: "测试 schema 不匹配", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出 jsonParsingFailed")
        } catch let error as VoiceTodoError {
            // 期望是 .jsonParsingFailed(_),关联值 detail 是运行时拼的,只能断言 case kind
            guard case .jsonParsingFailed = error else {
                XCTFail("期望 jsonParsingFailed,实际: \(error)")
                return
            }
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }
    }

    // MARK: - Test Fallback Extract

    func testFallbackExtractTruncatesTo20Characters() {
        // Given: 超过 20 字的文本
        let longText = "这是一段很长的语音转写文本，内容超过了二十个字符，应该被截断"

        // When: 调用 fallbackExtract
        let result = sut.fallbackExtract(from: longText)

        // Then: 标题被截取为前 20 字
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, TextUtils.truncateTitle(from: longText))
        XCTAssertEqual(result.todos[0].detail, longText)
        XCTAssertEqual(result.todos[0].categoryHint, .other)
        XCTAssertEqual(result.todos[0].priority, .normal)
        XCTAssertNil(result.todos[0].dueHint)
    }

    func testFallbackExtractWithShortText() {
        // Given: 不足 20 字的文本
        let shortText = "买菜"

        // When: 调用 fallbackExtract
        let result = sut.fallbackExtract(from: shortText)

        // Then: 保持原样
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, shortText)
        XCTAssertEqual(result.todos[0].detail, shortText)
    }

    // MARK: - Test Retry Logic (v2)

    func testRetryLogicSuccessOnSecondAttempt() async throws {
        // Given: 第一次失败，第二次成功
        let successResponse = """
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440003",
              "title": "完成任务",
              "detail": "完成今天的工作",
              "due_hint": "今天",
              "priority": "normal",
              "category_hint": "work"
            }
          ],
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueFailure(VoiceTodoError.networkUnavailable)
        mockNetworkClient.enqueueSuccess(text: successResponse)

        // When: 调用 extract（会重试）
        let result = try await sut.extract(from: "完成今天的工作", locale: Locale(identifier: "zh-Hans"))

        // Then: 第二次成功
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "完成任务")
        XCTAssertEqual(URLProtocolStub.callCount, 2)
    }

    func testRetryLogicAllAttemptsFailed() async {
        // Given: 所有尝试都失败（1 次初始 + retryCount 次重试）
        mockNetworkClient.enqueueFailure(VoiceTodoError.networkUnavailable)
        mockNetworkClient.enqueueFailure(VoiceTodoError.networkUnavailable)
        mockNetworkClient.enqueueFailure(VoiceTodoError.networkUnavailable)

        // When & Then: 抛出正确错误
        do {
            _ = try await sut.extract(from: "测试文本", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }

        // 验证总尝试次数 = 1 次初始 + retryCount 次重试
        XCTAssertEqual(URLProtocolStub.callCount, NetworkConfig.retryCount + 1)
    }

    func testRetryLogicSkipsOnInvalidProxyResponse() async {
        // Given: 代理返回不可用响应（不应该重试，也不把内部响应体暴露给用户）
        mockNetworkClient.enqueueHTTPFailure(statusCode: 401, body: "API Key 未配置")

        // When & Then: 立即抛出错误，不重试
        do {
            _ = try await sut.extract(from: "测试文本", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail))
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }

        // 验证只调用 1 次（不重试）
        XCTAssertEqual(URLProtocolStub.callCount, 1)
    }

    // MARK: - Test Empty Results

    func testEmptyTodosResult() async throws {
        // Given: AI 判断为纯感受，返回空数组
        let jsonResponse = """
        {
          "todos": [],
          "ignored": "最近好累，什么都不想干（纯感受，无行动意图）"
        }
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        // When: 调用 extract
        let result = try await sut.extract(from: "最近好累，什么都不想干", locale: Locale(identifier: "zh-Hans"))

        // Then: 返回空数组
        XCTAssertTrue(result.todos.isEmpty)
        XCTAssertFalse(result.ignored.isEmpty)
    }

    // MARK: - Test Multiple Todos

    func testMultipleTodosExtraction() async throws {
        // Given: 一句话包含多个待办
        let jsonResponse = """
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440010",
              "title": "去银行办卡",
              "detail": "明天去银行办卡",
              "due_hint": "明天",
              "priority": "normal",
              "category_hint": "finance"
            },
            {
              "id": "550e8400-e29b-41d4-a716-446655440011",
              "title": "买菜",
              "detail": "顺便买菜",
              "due_hint": null,
              "priority": "normal",
              "category_hint": "life"
            },
            {
              "id": "550e8400-e29b-41d4-a716-446655440012",
              "title": "给老妈打电话",
              "detail": "晚上给老妈打电话",
              "due_hint": "晚上",
              "priority": "normal",
              "category_hint": "social"
            }
          ],
          "ignored": ""
        }
        """

        mockNetworkClient.enqueueSuccess(text: jsonResponse)

        // When: 调用 extract
        let result = try await sut.extract(from: "明天去银行办卡，顺便买菜，晚上给老妈打电话", locale: Locale(identifier: "zh-Hans"))

        // Then: 正确提取 3 条待办
        XCTAssertEqual(result.todos.count, 3)
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[1].title, "买菜")
        XCTAssertEqual(result.todos[2].title, "给老妈打电话")
    }

    func testStreamingPartialParserIgnoresClosingBraceInsideString() async throws {
        let jsonResponse = """
        {
          "todos": [
            {
              "id": "550e8400-e29b-41d4-a716-446655440020",
              "title": "整理符号说明",
              "detail": "记录右花括号 } 的含义",
              "due_hint": null,
              "priority": "normal",
              "category_hint": "study"
            }
          ],
          "ignored": ""
        }
        """
        let eventData = try JSONSerialization.data(withJSONObject: ["delta": jsonResponse])
        let eventText = try XCTUnwrap(String(data: eventData, encoding: .utf8))
        mockNetworkClient.enqueueSuccess(text: "data: \(eventText)\n\ndata: [DONE]\n\n")

        var results: [ExtractionResult] = []
        for try await result in sut.extractStreaming(from: "记录右花括号", locale: Locale(identifier: "zh-Hans")) {
            results.append(result)
        }

        XCTAssertEqual(results.count, 2, "应该先产出流式中间态，再产出最终完整解析结果")
        XCTAssertEqual(results.first?.todos.first?.detail, "记录右花括号 } 的含义")
        XCTAssertEqual(results.last?.todos.first?.categoryHint, .study)

        let body = try XCTUnwrap(URLProtocolStub.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testStreamingSendsVocabularyHintsToProxy() async throws {
        sut = TodoExtractorService(
            networkClient: mockNetworkClient.networkClient,
            vocabularyProvider: StaticExtractorVocabularyProvider(hints: ["Anki", "IELTS"])
        )
        mockNetworkClient.enqueueSuccess(text: "data: {\"delta\":\"{\\\"todos\\\":[],\\\"ignored\\\":\\\"\\\"}\"}\n\ndata: [DONE]\n\n")

        for try await _ in sut.extractStreaming(from: "今天复习", locale: Locale(identifier: "zh-Hans")) {}

        let body = try XCTUnwrap(URLProtocolStub.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["vocabularyHints"] as? [String], ["Anki", "IELTS"])
    }

    func testStreamingRequiresDoneSentinelEvenWhenJSONIsComplete() async throws {
        let jsonResponse = """
        {
          "todos": [
            {
              "title": "整理资料",
              "detail": "今天整理资料",
              "due_hint": "今天",
              "priority": "normal",
              "category_hint": "work"
            }
          ],
          "ignored": ""
        }
        """
        let eventData = try JSONSerialization.data(withJSONObject: ["delta": jsonResponse])
        let eventText = try XCTUnwrap(String(data: eventData, encoding: .utf8))
        mockNetworkClient.enqueueSuccess(text: "data: \(eventText)\n\n")

        var results: [ExtractionResult] = []
        do {
            for try await result in sut.extractStreaming(from: "今天整理资料", locale: Locale(identifier: "zh-Hans")) {
                results.append(result)
            }
            XCTFail("缺少 [DONE] 的流不应被当作成功")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .apiResponseInvalid(ErrorMessages.apiResponseInvalidDetail))
            XCTAssertFalse(results.isEmpty, "允许 UI 收到中间态，但最终必须收到失败")
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }
    }
}

// MARK: - P3: 熔断 / 退避 / 429

extension ExtractorTests {
    /// 限流但无 Retry-After 时不应盲目重试（只发一次请求）。
    func testRateLimitedWithoutRetryAfterIsNotRetried() async {
        mockNetworkClient.enqueueHTTPFailure(statusCode: 429, body: "rate limited")
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")
        do {
            _ = try await sut.extract(from: "限流", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应抛出限流错误")
        } catch {
            XCTAssertEqual(URLProtocolStub.callCount, 1, "无 Retry-After 不应重试")
        }
    }

    /// 限流且带 Retry-After 时按提示重试一次后成功。
    func testRateLimitedWithRetryAfterRetries() async throws {
        mockNetworkClient.enqueueHTTPFailure(statusCode: 429, body: "rate limited", headers: ["Retry-After": "0"])
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")
        let result = try await sut.extract(from: "限流重试", locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(URLProtocolStub.callCount, 2, "带 Retry-After 应重试一次")
        XCTAssertEqual(result.todos.count, 0)
    }

    func testQuotaExhaustedIsNotRetried() async {
        mockNetworkClient.enqueueHTTPFailure(
            statusCode: 429,
            body: #"{"error":"quota_exceeded","tier":"free","remaining":0,"resetAt":"2026-05-26"}"#,
            headers: [
                "X-RateLimit-Type": "quota",
                "X-Quota-Plan": "free",
                "X-Quota-Reset-Date": "2026-05-26"
            ]
        )
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")

        do {
            _ = try await sut.extract(from: "额度耗尽", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应抛出配额耗尽错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .quotaExhausted(tier: "free", resetAt: "2026-05-26"))
            XCTAssertEqual(URLProtocolStub.callCount, 1, "配额耗尽不应重试")
        } catch {
            XCTFail("错误类型: \(error)")
        }
    }

    /// 传输类失败应重试，随后成功。
    func testTransportFailureRetriesThenSucceeds() async throws {
        mockNetworkClient.enqueueFailure(URLError(.networkConnectionLost))
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")
        let result = try await sut.extract(from: "断网重试", locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(URLProtocolStub.callCount, 2, "传输失败后应重试一次")
        XCTAssertEqual(result.todos.count, 0)
    }

    /// 熔断器：达到阈值后短路，冷却到期转半开放行，成功后闭合。
    func testCircuitBreakerOpensAfterThresholdAndRecovers() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let breaker = ExtractorCircuitBreaker(failureThreshold: 2, cooldown: 30, now: { clock.now })

        var shorted = await breaker.shouldShortCircuit()
        XCTAssertFalse(shorted, "初始闭合不应短路")

        await breaker.recordFailure()
        await breaker.recordFailure()
        shorted = await breaker.shouldShortCircuit()
        XCTAssertTrue(shorted, "达到阈值应短路")

        clock.now = Date(timeIntervalSince1970: 20)
        shorted = await breaker.shouldShortCircuit()
        XCTAssertTrue(shorted, "冷却未到仍短路")

        clock.now = Date(timeIntervalSince1970: 31)
        shorted = await breaker.shouldShortCircuit()
        XCTAssertFalse(shorted, "冷却到期应转半开放行")

        await breaker.recordSuccess()
        shorted = await breaker.shouldShortCircuit()
        XCTAssertFalse(shorted, "成功后应闭合")
    }

    /// 5xx 应被重试（区别于不可重试的 4xx/解析错误）。
    func testServerErrorRetriesThenSucceeds() async throws {
        mockNetworkClient.enqueueHTTPFailure(statusCode: 500, body: "boom")
        mockNetworkClient.enqueueSuccess(text: "{\"todos\":[],\"ignored\":\"\"}")
        let result = try await sut.extract(from: "5xx 重试", locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(URLProtocolStub.callCount, 2, "5xx 应重试一次")
        XCTAssertEqual(result.todos.count, 0)
    }

    /// 5xx 重试耗尽后抛 apiServerError（且总尝试次数 = retryCount + 1）。
    /// 注：503 现已映射为 `.serviceUnavailable`，此处用 500 保留 apiServerError 语义。
    func testServerErrorExhaustedThrowsServerError() async {
        for _ in 0...NetworkConfig.retryCount {
            mockNetworkClient.enqueueHTTPFailure(statusCode: 500, body: "boom")
        }
        do {
            _ = try await sut.extract(from: "5xx 全失败", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应抛出错误")
        } catch let error as VoiceTodoError {
            if case .apiServerError = error {
                XCTAssertEqual(URLProtocolStub.callCount, NetworkConfig.retryCount + 1)
            } else {
                XCTFail("应为 apiServerError，实际 \(error)")
            }
        } catch {
            XCTFail("错误类型: \(error)")
        }
    }

    /// 熔断打开时，流式路径应直接失败、不发起网络请求（验证 #2 流式参与熔断）。
    func testStreamingShortCircuitsWhenBreakerOpen() async {
        let breaker = ExtractorCircuitBreaker(failureThreshold: 1, cooldown: 60)
        await breaker.recordFailure()  // 阈值 1 → 立即打开
        let service = TodoExtractorService(
            networkClient: mockNetworkClient.networkClient,
            vocabularyProvider: StaticExtractorVocabularyProvider(hints: []),
            circuitBreaker: breaker,
            sleep: { _ in }
        )
        do {
            for try await _ in service.extractStreaming(from: "x", locale: Locale(identifier: "zh-Hans")) {}
            XCTFail("熔断打开应直接抛错")
        } catch {
            XCTAssertEqual(URLProtocolStub.callCount, 0, "熔断打开不应发起网络请求")
        }
    }
}

// MARK: - Mock Network Client

private struct StaticExtractorVocabularyProvider: UserVocabularyProviding {
    let hints: [String]

    func vocabularyHints(localeIdentifier: String, limit: Int, now: Date) -> [String] {
        Array(hints.prefix(limit))
    }
}

private final class MockNetworkClient {
    let networkClient: NetworkClient

    init() {
        URLProtocolStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        networkClient = NetworkClient(
            session: session,
            proxyEndpoint: "https://proxy.test/v1/todo-extractions",
            appToken: "test-app-token",
            deviceIdentifier: "test-device-id"
        )
    }

    func enqueueSuccess(text: String) {
        URLProtocolStub.responses.append(.success(statusCode: 200, body: text, headers: [:]))
    }

    func enqueueFailure(_ error: Error) {
        URLProtocolStub.responses.append(.failure(error))
    }

    func enqueueHTTPFailure(statusCode: Int, body: String, headers: [String: String] = [:]) {
        URLProtocolStub.responses.append(.success(statusCode: statusCode, body: body, headers: headers))
    }
}

private final class URLProtocolStub: URLProtocol {
    enum StubResponse {
        case success(statusCode: Int, body: String, headers: [String: String])
        case failure(Error)
    }

    static var responses: [StubResponse] = []
    static var requests: [URLRequest] = []
    static var requestBodies: [Data] = []
    static var callCount = 0

    static func reset() {
        responses = []
        requests = []
        requestBodies = []
        callCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCount += 1
        Self.requests.append(request)
        Self.requestBodies.append(Self.bodyData(from: request))
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = Self.responses.removeFirst()

        switch response {
        case .success(let statusCode, let body, let headers):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
