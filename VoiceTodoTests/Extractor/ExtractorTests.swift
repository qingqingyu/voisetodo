import XCTest
@testable import VoiceTodo

final class ExtractorTests: XCTestCase {
    // MARK: - Properties

    var sut: TodoExtractorService!
    private var mockNetworkClient: MockNetworkClient!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        setenv("ANTHROPIC_API_KEY", "test-key", 1)
        mockNetworkClient = MockNetworkClient()
        sut = TodoExtractorService(networkClient: mockNetworkClient.networkClient)
    }

    override func tearDown() {
        URLProtocolStub.reset()
        unsetenv("ANTHROPIC_API_KEY")
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
        // Given: 所有尝试都失败
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

        // 验证重试次数（1次初始 + 1次重试 = 2次）
        XCTAssertEqual(URLProtocolStub.callCount, 2)
    }

    func testRetryLogicSkipsOnConfigurationError() async {
        // Given: 配置错误（不应该重试）
        mockNetworkClient.enqueueHTTPFailure(statusCode: 401, body: "API Key 未配置")

        // When & Then: 立即抛出错误，不重试
        do {
            _ = try await sut.extract(from: "测试文本", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .apiResponseInvalid("HTTP 401: API Key 未配置"))
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
}

// MARK: - Mock Network Client

private final class MockNetworkClient {
    let networkClient: NetworkClient

    init() {
        URLProtocolStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        networkClient = NetworkClient(session: session)
    }

    func enqueueSuccess(text: String) {
        let body = """
        {
          "content": [
            {
              "text": \(text.jsonEscaped)
            }
          ]
        }
        """
        URLProtocolStub.responses.append(.success(statusCode: 200, body: body))
    }

    func enqueueFailure(_ error: Error) {
        URLProtocolStub.responses.append(.failure(error))
    }

    func enqueueHTTPFailure(statusCode: Int, body: String) {
        URLProtocolStub.responses.append(.success(statusCode: statusCode, body: body))
    }
}

private final class URLProtocolStub: URLProtocol {
    enum StubResponse {
        case success(statusCode: Int, body: String)
        case failure(Error)
    }

    static var responses: [StubResponse] = []
    static var callCount = 0

    static func reset() {
        responses = []
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
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = Self.responses.removeFirst()

        switch response {
        case .success(let statusCode, let body):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension String {
    var jsonEscaped: String {
        let data = try! JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }
}
