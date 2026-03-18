import XCTest
@testable import VoiceTodo

final class ExtractorTests: XCTestCase {
    // MARK: - Properties

    var sut: TodoExtractorService!
    var mockNetworkClient: MockNetworkClient!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        mockNetworkClient = MockNetworkClient()
        sut = TodoExtractorService(networkClient: mockNetworkClient)
    }

    override func tearDown() {
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

        mockNetworkClient.mockResponse = jsonResponse

        // When: 调用 extract
        let result = try await sut.extract(from: "明天去银行办卡")

        // Then: 正确解析
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[0].categoryHint, .finance)
        XCTAssertEqual(result.todos[0].priority, .normal)
        XCTAssertEqual(result.todos[0].dueHint, "明天")
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

        mockNetworkClient.mockResponse = jsonResponse

        // When: 调用 extract
        let result = try await sut.extract(from: "准备下周的面试")

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

        mockNetworkClient.mockResponse = jsonResponse

        // When: 调用 extract
        let result = try await sut.extract(from: "晚上买菜")

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
        XCTAssertEqual(result.todos[0].title, String(longText.prefix(20)))
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

        mockNetworkClient.mockError = VoiceTodoError.networkUnavailable
        mockNetworkClient.mockResponse = successResponse
        mockNetworkClient.failFirstAttempt = true

        // When: 调用 extract（会重试）
        let result = try await sut.extract(from: "完成今天的工作")

        // Then: 第二次成功
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "完成任务")
        XCTAssertEqual(mockNetworkClient.callCount, 2)
    }

    func testRetryLogicAllAttemptsFailed() async {
        // Given: 所有尝试都失败
        mockNetworkClient.mockError = VoiceTodoError.networkUnavailable
        mockNetworkClient.alwaysFail = true

        // When & Then: 抛出正确错误
        do {
            _ = try await sut.extract(from: "测试文本")
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }

        // 验证重试次数（1次初始 + 1次重试 = 2次）
        XCTAssertEqual(mockNetworkClient.callCount, 2)
    }

    func testRetryLogicSkipsOnConfigurationError() async {
        // Given: 配置错误（不应该重试）
        mockNetworkClient.mockError = VoiceTodoError.apiResponseInvalid("API Key 未配置")
        mockNetworkClient.alwaysFail = true

        // When & Then: 立即抛出错误，不重试
        do {
            _ = try await sut.extract(from: "测试文本")
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .apiResponseInvalid("API Key 未配置"))
        } catch {
            XCTFail("错误的错误类型: \(error)")
        }

        // 验证只调用 1 次（不重试）
        XCTAssertEqual(mockNetworkClient.callCount, 1)
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

        mockNetworkClient.mockResponse = jsonResponse

        // When: 调用 extract
        let result = try await sut.extract(from: "最近好累，什么都不想干")

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

        mockNetworkClient.mockResponse = jsonResponse

        // When: 调用 extract
        let result = try await sut.extract(from: "明天去银行办卡，顺便买菜，晚上给老妈打电话")

        // Then: 正确提取 3 条待办
        XCTAssertEqual(result.todos.count, 3)
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[1].title, "买菜")
        XCTAssertEqual(result.todos[2].title, "给老妈打电话")
    }
}

// MARK: - Mock Network Client

/// Mock 网络客户端，用于测试
class MockNetworkClient: NetworkClient {
    var mockResponse: String = ""
    var mockError: Error?
    var alwaysFail = false
    var failFirstAttempt = false
    var callCount = 0

    override func callClaudeAPI(
        systemPrompt: String,
        messages: [[String: String]],
        model: String,
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        callCount += 1

        // 如果设置了总是失败
        if alwaysFail {
            throw mockError ?? VoiceTodoError.networkUnavailable
        }

        // 如果设置了第一次失败
        if failFirstAttempt && callCount == 1 {
            throw mockError ?? VoiceTodoError.networkUnavailable
        }

        // 返回 mock 响应
        if let error = mockError {
            throw error
        }

        return mockResponse
    }
}
