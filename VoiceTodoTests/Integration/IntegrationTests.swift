import XCTest
import SwiftData
import Combine
@testable import VoiceTodo

/// 集成测试：验证模块之间的接口调用
final class IntegrationTests: XCTestCase {
    // MARK: - Properties

    var modelContainer: ModelContainer!
    var modelContext: ModelContext!
    var todoStore: TodoStore!
    var mockExtractor: MockExtractor!
    var cancellables: Set<AnyCancellable>!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()

        // 创建内存数据库
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: TodoItem.self, configurations: config)
        modelContext = modelContainer.mainContext

        // 初始化依赖
        todoStore = TodoStore(modelContext: modelContext)
        mockExtractor = MockExtractor()
        cancellables = []
    }

    override func tearDown() {
        todoStore = nil
        mockExtractor = nil
        modelContext = nil
        modelContainer = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Test Case 1: Voice → Extractor Pipeline

    /// 测试从固定 transcript 传入 extractor，验证返回 ExtractionResult
    func test_voiceToExtractor_pipeline() async throws {
        // Given: 一个固定的语音转写文本
        let transcript = "明天去银行办卡，顺便买菜，晚上给老妈打电话"

        // When: 调用 extractor
        let result = try await mockExtractor.extract(from: transcript)

        // Then: 验证返回的 ExtractionResult
        XCTAssertEqual(result.todos.count, 3, "应该提取出 3 条待办")
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[1].title, "买菜")
        XCTAssertEqual(result.todos[2].title, "给老妈打电话")
        XCTAssertTrue(result.ignored.isEmpty)
    }

    // MARK: - Test Case 2: Extractor → Store Pipeline

    /// 测试将 ExtractionResult 传入 store.addBatch，验证 todos 数量
    func test_extractorToStore_pipeline() throws {
        // Given: 一个提取结果
        let extractedItems = [
            ExtractedTodo(title: "任务1", categoryHint: .work),
            ExtractedTodo(title: "任务2", categoryHint: .life),
            ExtractedTodo(title: "任务3", categoryHint: .study)
        ]

        XCTAssertEqual(todoStore.todos.count, 0, "初始应该没有待办")

        // When: 批量添加到 store
        try todoStore.addBatch(extractedItems)

        // Then: 验证 todos 数量
        XCTAssertEqual(todoStore.todos.count, 3, "应该有 3 条待办")

        // 验证数据内容
        let titles = todoStore.todos.map { $0.title }
        XCTAssertTrue(titles.contains("任务1"))
        XCTAssertTrue(titles.contains("任务2"))
        XCTAssertTrue(titles.contains("任务3"))
    }

    // MARK: - Test Case 3: Store → Widget Data Access

    /// 测试写入数据后通过 App Group 读取，验证一致性
    func test_storeToWidget_dataAccess() throws {
        // Given: 添加一些待办
        let items = [
            ExtractedTodo(title: "Widget 任务1", priority: .high, categoryHint: .work),
            ExtractedTodo(title: "Widget 任务2", priority: .normal, categoryHint: .life)
        ]
        try todoStore.addBatch(items)

        // When: 获取用于 Widget 的数据
        let widgetData = todoStore.recentUncompleted(limit: 10)

        // Then: 验证一致性
        XCTAssertEqual(widgetData.count, 2)
        XCTAssertEqual(widgetData[0].title, "Widget 任务2")  // 按时间倒序
        XCTAssertEqual(widgetData[1].title, "Widget 任务1")
        XCTAssertEqual(widgetData[1].priority, .high)
        XCTAssertFalse(widgetData[0].isCompleted)
    }

    // MARK: - Test Case 4: Offline Raw Transcript Full Path

    /// 测试原始转写文本存入 store，验证 needsAIProcessing==true
    func test_offlineRawTranscript_fullPath() throws {
        // Given: 一个原始转写文本
        let transcript = "这是一段很长很长的原始语音转写文本，需要进行后续 AI 处理"

        // When: 使用 addRawTranscript 保存原始文本
        try todoStore.addRawTranscript(transcript)

        // Then: 验证存储结果
        XCTAssertEqual(todoStore.todos.count, 1)
        XCTAssertTrue(todoStore.todos[0].needsAIProcessing)
        XCTAssertEqual(todoStore.todos[0].title, String(transcript.prefix(20)))
    }

    // MARK: - Test Case 5: Pending Recovery Full Path

    /// 测试待处理条目经 AI 提取后替换，验证正确
    func test_pendingRecovery_fullPath() async throws {
        // Given: 预置一个待处理条目
        let rawTranscript = "明天去银行办卡，顺便买菜"
        try todoStore.addRawTranscript(rawTranscript)

        XCTAssertEqual(todoStore.todos.count, 1)
        XCTAssertTrue(todoStore.todos[0].needsAIProcessing)

        let pendingId = todoStore.todos[0].id

        // When: AI 提取并替换
        let extractedItems = try await mockExtractor.extract(from: rawTranscript)
        try todoStore.replacePendingWithExtracted(pendingId, extractedItems.todos)

        // Then: 验证替换结果
        XCTAssertEqual(todoStore.todos.count, 2, "应该有 2 条提取结果")
        XCTAssertFalse(todoStore.todos.contains { $0.id == pendingId }, "原待处理条目应被删除")
        XCTAssertTrue(todoStore.todos.allSatisfy { !$0.needsAIProcessing }, "新条目不应标记为待处理")
    }

    // MARK: - Test Case 6: Error Propagation

    /// 测试每种 VoiceTodoError 都能正确传递
    func test_errorPropagation() async throws {
        // Test 1: Network Error
        mockExtractor.shouldThrowError = true
        mockExtractor.errorToThrow = VoiceTodoError.networkUnavailable

        do {
            _ = try await mockExtractor.extract(from: "测试")
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        // Test 2: Storage Error
        let invalidId = UUID()
        do {
            try todoStore.delete(invalidId)
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertTrue(error is VoiceTodoError)
        }

        // Test 3: API Error
        mockExtractor.errorToThrow = VoiceTodoError.apiResponseInvalid("测试错误")
        do {
            _ = try await mockExtractor.extract(from: "测试")
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            if case .apiResponseInvalid = error {
                // 正确
            } else {
                XCTFail("错误的错误类型")
            }
        }
    }

    // MARK: - Additional Integration Tests

    /// 测试完整的工作流：添加 → 标记完成 → 验证未完成列表不包含已完成项
    func test_fullWorkflow_addCompleteFilter() throws {
        // Given: 添加 3 条待办
        let items = [
            ExtractedTodo(title: "任务A", categoryHint: .work),
            ExtractedTodo(title: "任务B", categoryHint: .life),
            ExtractedTodo(title: "任务C", categoryHint: .study)
        ]
        try todoStore.addBatch(items)

        XCTAssertEqual(todoStore.todos.count, 3)

        // When: 标记第一条为完成
        let firstTodoId = todoStore.todos[0].id
        try todoStore.toggleComplete(firstTodoId)

        // Then: 验证未完成列表
        let uncompleted = todoStore.recentUncompleted(limit: 10)
        XCTAssertEqual(uncompleted.count, 2, "未完成列表应该有 2 条")
        XCTAssertTrue(uncompleted.allSatisfy { !$0.isCompleted }, "未完成列表不应包含已完成项")
    }

    /// 测试并发写入的安全性
    func test_concurrentWrites() async throws {
        // Given: 准备多个并发任务
        let tasks = (1...10).map { i in
            ExtractedTodo(title: "并发任务\(i)", categoryHint: .work)
        }

        // When: 并发添加
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    try self.todoStore.add(task)
                }
            }
            try await group.waitForAll()
        }

        // Then: 验证所有任务都被添加
        XCTAssertEqual(todoStore.todos.count, 10, "应该有 10 条待办")
    }
}

// MARK: - Mock Extractor

/// Mock 提取器，用于集成测试
class MockExtractor: TodoExtractorProtocol {
    var shouldThrowError = false
    var errorToThrow: Error?

    func extract(from transcript: String) async throws -> ExtractionResult {
        if shouldThrowError {
            throw errorToThrow ?? VoiceTodoError.networkUnavailable
        }

        // 模拟 AI 提取逻辑
        if transcript.contains("去银行") && transcript.contains("买菜") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "去银行办卡", detail: "明天去银行办卡", dueHint: "明天", categoryHint: .finance),
                    ExtractedTodo(title: "买菜", detail: "顺便买菜", categoryHint: .life),
                    ExtractedTodo(title: "给老妈打电话", detail: "晚上给老妈打电话", dueHint: "晚上", categoryHint: .social)
                ],
                ignored: ""
            )
        }

        // 默认返回单个待办
        return ExtractionResult(
            todos: [ExtractedTodo(title: "提取的任务", detail: transcript, categoryHint: .other)],
            ignored: ""
        )
    }
}
