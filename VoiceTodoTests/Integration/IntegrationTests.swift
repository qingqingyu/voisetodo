import XCTest
import SwiftData
@testable import VoiceTodo

/// 集成测试：验证模块之间的接口调用
final class IntegrationTests: XCTestCase {
    // MARK: - Properties

    var modelContainer: ModelContainer!
    var modelContext: ModelContext!
    var todoStore: TodoStore!
    var mockExtractor: MockExtractor!
    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()

        // 创建内存数据库
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: TodoItem.self, TodoOccurrenceCompletion.self, configurations: config)
        modelContext = await MainActor.run { modelContainer.mainContext }

        // 初始化依赖
        todoStore = await MainActor.run { TodoStore(modelContext: modelContext) }
        mockExtractor = MockExtractor()
    }

    override func tearDown() {
        todoStore = nil
        mockExtractor = nil
        modelContext = nil
        modelContainer = nil
        super.tearDown()
    }

    // MARK: - Test Case 1: Voice → Extractor Pipeline

    /// 测试从固定 transcript 传入 extractor，验证返回 ExtractionResult
    func test_voiceToExtractor_pipeline() async throws {
        // Given: 一个固定的语音转写文本
        let transcript = "明天去银行办卡，顺便买菜，晚上给老妈打电话"

        // When: 调用 extractor
        let result = try await mockExtractor.extract(from: transcript, locale: Locale(identifier: "zh-Hans"))

        // Then: 验证返回的 ExtractionResult
        XCTAssertEqual(result.todos.count, 3, "应该提取出 3 条待办")
        XCTAssertEqual(result.todos[0].title, "去银行办卡")
        XCTAssertEqual(result.todos[1].title, "买菜")
        XCTAssertEqual(result.todos[2].title, "给老妈打电话")
        XCTAssertTrue(result.ignored.isEmpty)
    }

    // MARK: - Test Case 2: Extractor → Store Pipeline

    /// 测试将 ExtractionResult 传入 store.addBatch，验证 todos 数量
    func test_extractorToStore_pipeline() async throws {
        // Given: 一个提取结果
        let extractedItems = [
            ExtractedTodo(title: "任务1", categoryHint: .work),
            ExtractedTodo(title: "任务2", categoryHint: .life),
            ExtractedTodo(title: "任务3", categoryHint: .study)
        ]

        let initialCount = await MainActor.run { todoStore.todos.count }
        XCTAssertEqual(initialCount, 0, "初始应该没有待办")

        // When: 批量添加到 store
        try await MainActor.run {
            try todoStore.addBatch(extractedItems)
        }

        // Then: 验证 todos 数量
        let todos = await MainActor.run { todoStore.todos }
        XCTAssertEqual(todos.count, 3, "应该有 3 条待办")

        // 验证数据内容
        let titles = todos.map(\.title)
        XCTAssertTrue(titles.contains("任务1"))
        XCTAssertTrue(titles.contains("任务2"))
        XCTAssertTrue(titles.contains("任务3"))
    }

    // MARK: - Test Case 3: Store → Widget Data Access

    /// 测试写入数据后通过 App Group 读取，验证一致性
    func test_storeToWidget_dataAccess() async throws {
        // Given: 添加一些待办
        let items = [
            ExtractedTodo(title: "Widget 任务1", priority: .high, categoryHint: .work),
            ExtractedTodo(title: "Widget 任务2", priority: .normal, categoryHint: .life)
        ]
        try await MainActor.run {
            try todoStore.addBatch(items)
        }

        // When: 获取用于 Widget 的数据
        let widgetData = await MainActor.run {
            todoStore.recentUncompleted(limit: 10)
        }

        // Then: 验证一致性
        XCTAssertEqual(widgetData.count, 2)
        XCTAssertEqual(widgetData[0].title, "Widget 任务2")  // 按 sortOrder 升序
        XCTAssertEqual(widgetData[1].title, "Widget 任务1")
        XCTAssertEqual(widgetData[1].priority, .high)
        XCTAssertFalse(widgetData[0].isCompleted)
    }

    // MARK: - Test Case 4: Offline Raw Transcript Full Path

    /// 测试原始转写文本存入 store，验证 needsAIProcessing==true
    func test_offlineRawTranscript_fullPath() async throws {
        // Given: 一个原始转写文本
        let transcript = "这是一段很长很长的原始语音转写文本，需要进行后续 AI 处理"

        // When: 使用 addRawTranscript 保存原始文本
        try await MainActor.run {
            try todoStore.addRawTranscript(transcript)
        }

        // Then: 验证存储结果
        let todos = await MainActor.run { todoStore.todos }
        XCTAssertEqual(todos.count, 1)
        XCTAssertTrue(todos[0].needsAIProcessing)
        XCTAssertEqual(todos[0].title, TextUtils.truncateTitle(from: transcript))
    }

    // MARK: - Test Case 5: Pending Recovery Full Path

    /// 测试待处理条目经 AI 提取后替换，验证正确
    func test_pendingRecovery_fullPath() async throws {
        // Given: 预置一个待处理条目
        let rawTranscript = "明天去银行办卡，顺便买菜"
        try await MainActor.run {
            try todoStore.addRawTranscript(rawTranscript)
        }

        let initialTodos = await MainActor.run { todoStore.todos }
        XCTAssertEqual(initialTodos.count, 1)
        XCTAssertTrue(initialTodos[0].needsAIProcessing)

        let pendingId = initialTodos[0].id

        // When: AI 提取并替换
        let extractedItems = try await mockExtractor.extract(from: rawTranscript, locale: Locale(identifier: "zh-Hans"))
        try await MainActor.run {
            try todoStore.replacePendingWithExtracted(pendingId, extractedItems.todos)
        }

        // Then: 验证替换结果
        let replacedTodos = await MainActor.run { todoStore.todos }
        XCTAssertEqual(replacedTodos.count, extractedItems.todos.count, "应该与提取结果数量一致")
        XCTAssertFalse(replacedTodos.contains { $0.id == pendingId }, "原待处理条目应被删除")
        XCTAssertTrue(replacedTodos.allSatisfy { !$0.needsAIProcessing }, "新条目不应标记为待处理")
    }

    // MARK: - Test Case 6: Error Propagation

    /// 测试每种 VoiceTodoError 都能正确传递
    func test_errorPropagation() async throws {
        // Test 1: Network Error
        mockExtractor.shouldThrowError = true
        mockExtractor.errorToThrow = VoiceTodoError.networkUnavailable

        do {
            _ = try await mockExtractor.extract(from: "测试", locale: Locale(identifier: "zh-Hans"))
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        // Test 2: Storage Error
        let invalidId = UUID()
        do {
            try await MainActor.run {
                try todoStore.delete(invalidId)
            }
            XCTFail("应该抛出错误")
        } catch let error as VoiceTodoError {
            XCTAssertTrue(error is VoiceTodoError)
        }

        // Test 3: API Error
        mockExtractor.errorToThrow = VoiceTodoError.apiResponseInvalid("测试错误")
        do {
            _ = try await mockExtractor.extract(from: "测试", locale: Locale(identifier: "zh-Hans"))
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
    func test_fullWorkflow_addCompleteFilter() async throws {
        // Given: 添加 3 条待办
        let items = [
            ExtractedTodo(title: "任务A", categoryHint: .work),
            ExtractedTodo(title: "任务B", categoryHint: .life),
            ExtractedTodo(title: "任务C", categoryHint: .study)
        ]
        try await MainActor.run {
            try todoStore.addBatch(items)
        }

        let addedTodos = await MainActor.run { todoStore.todos }
        XCTAssertEqual(addedTodos.count, 3)

        // When: 标记第一条为完成
        let firstTodoId = addedTodos[0].id
        try await MainActor.run {
            try todoStore.toggleComplete(firstTodoId)
        }

        // Then: 验证未完成列表
        let uncompleted = await MainActor.run {
            todoStore.recentUncompleted(limit: 10)
        }
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
                    try await MainActor.run {
                        try self.todoStore.add(task)
                    }
                }
            }
            try await group.waitForAll()
        }

        // Then: 验证所有任务都被添加
        let count = await MainActor.run { todoStore.todos.count }
        XCTAssertEqual(count, 10, "应该有 10 条待办")
    }
}

// MARK: - Mock Extractor

/// Mock 提取器，用于集成测试
class MockExtractor: TodoExtractorProtocol {
    var shouldThrowError = false
    var errorToThrow: Error?

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
        if shouldThrowError {
            throw errorToThrow ?? VoiceTodoError.networkUnavailable
        }

        // 模拟 AI 提取逻辑
        if transcript.contains("去银行") && transcript.contains("买菜") && transcript.contains("老妈") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "去银行办卡", detail: "明天去银行办卡", dueHint: "明天", categoryHint: .finance),
                    ExtractedTodo(title: "买菜", detail: "顺便买菜", categoryHint: .life),
                    ExtractedTodo(title: "给老妈打电话", detail: "晚上给老妈打电话", dueHint: "晚上", categoryHint: .social)
                ],
                ignored: ""
            )
        }

        if transcript.contains("去银行") && transcript.contains("买菜") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "去银行办卡", detail: "明天去银行办卡", dueHint: "明天", categoryHint: .finance),
                    ExtractedTodo(title: "买菜", detail: "顺便买菜", categoryHint: .life)
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
