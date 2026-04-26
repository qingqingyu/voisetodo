import XCTest
import SwiftData
@testable import VoiceTodo

@MainActor
final class StoreTests: XCTestCase {
    // MARK: - Properties

    var sut: TodoStore!
    var modelContainer: ModelContainer!
    var modelContext: ModelContext!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()

        // 创建内存数据库用于测试
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: TodoItem.self, configurations: config)
        modelContext = modelContainer.mainContext
        sut = TodoStore(modelContext: modelContext)
    }

    override func tearDown() {
        sut = nil
        modelContext = nil
        modelContainer = nil
        super.tearDown()
    }

    // MARK: - Test Add

    func testAddTodo() throws {
        // Given: 一个提取的待办
        let extractedTodo = ExtractedTodo(
            id: UUID(),
            title: "完成报告",
            detail: "下周五前完成季度报告",
            dueHint: "下周五前",
            priority: .high,
            categoryHint: .work
        )

        // When: 添加到 store
        try sut.add(extractedTodo)

        // Then: todos 数组包含该条目
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(sut.todos[0].title, "完成报告")
        XCTAssertEqual(sut.todos[0].priority, .high)
        XCTAssertEqual(sut.todos[0].category, .work)
        XCTAssertEqual(sut.todos[0].dueHint, "下周五前")
        XCTAssertFalse(sut.todos[0].isCompleted)
        XCTAssertFalse(sut.todos[0].needsAIProcessing)
    }

    // MARK: - Test AddBatch

    func testAddBatchTodos() throws {
        // Given: 多个提取的待办
        let items = [
            ExtractedTodo(title: "任务1", categoryHint: .work),
            ExtractedTodo(title: "任务2", categoryHint: .life),
            ExtractedTodo(title: "任务3", categoryHint: .study)
        ]

        // When: 批量添加
        try sut.addBatch(items)

        // Then: todos 数组包含所有条目
        XCTAssertEqual(sut.todos.count, 3)
        XCTAssertEqual(sut.todos[0].title, "任务3")  // 按时间倒序
        XCTAssertEqual(sut.todos[1].title, "任务2")
        XCTAssertEqual(sut.todos[2].title, "任务1")
    }

    // MARK: - Test ToggleComplete

    func testToggleComplete() throws {
        // Given: 一个待办
        let todo = ExtractedTodo(title: "测试任务", categoryHint: .work)
        try sut.add(todo)

        let todoId = sut.todos[0].id

        // When: 切换完成状态
        try sut.toggleComplete(todoId)

        // Then: 状态已切换
        XCTAssertTrue(sut.todos[0].isCompleted)

        // When: 再次切换
        try sut.toggleComplete(todoId)

        // Then: 状态恢复
        XCTAssertFalse(sut.todos[0].isCompleted)
    }

    func testToggleCompleteInvalidId() {
        // Given: 无效的 ID
        let invalidId = UUID()

        // When & Then: 抛出错误
        XCTAssertThrowsError(try sut.toggleComplete(invalidId)) { error in
            XCTAssertTrue(error is VoiceTodoError)
        }
    }

    // MARK: - Test Delete

    func testDeleteTodo() throws {
        // Given: 一个待办
        let todo = ExtractedTodo(title: "待删除任务", categoryHint: .work)
        try sut.add(todo)

        let todoId = sut.todos[0].id
        XCTAssertEqual(sut.todos.count, 1)

        // When: 删除
        try sut.delete(todoId)

        // Then: todos 为空
        XCTAssertTrue(sut.todos.isEmpty)
    }

    func testDeleteInvalidId() {
        // Given: 无效的 ID
        let invalidId = UUID()

        // When & Then: 抛出错误
        XCTAssertThrowsError(try sut.delete(invalidId)) { error in
            XCTAssertTrue(error is VoiceTodoError)
        }
    }

    // MARK: - Test Update

    func testUpdateTitle() throws {
        // Given: 一个待办
        let todo = ExtractedTodo(title: "原标题", categoryHint: .work)
        try sut.add(todo)

        let todoId = sut.todos[0].id

        // When: 更新标题
        try sut.update(todoId, title: "新标题")

        // Then: 标题已更新
        XCTAssertEqual(sut.todos[0].title, "新标题")
    }

    func testUpdateInvalidId() {
        // Given: 无效的 ID
        let invalidId = UUID()

        // When & Then: 抛出错误
        XCTAssertThrowsError(try sut.update(invalidId, title: "新标题")) { error in
            XCTAssertTrue(error is VoiceTodoError)
        }
    }

    // MARK: - Test RecentUncompleted

    func testRecentUncompletedOnlyReturnsUncompleted() throws {
        // Given: 混合完成和未完成的待办
        let todos = [
            ExtractedTodo(title: "任务1", categoryHint: .work),
            ExtractedTodo(title: "任务2", categoryHint: .work),
            ExtractedTodo(title: "任务3", categoryHint: .work)
        ]
        try sut.addBatch(todos)

        // 将第一个标记为完成
        try sut.toggleComplete(sut.todos[0].id)

        // When: 获取未完成待办
        let uncompleted = sut.recentUncompleted(limit: 10)

        // Then: 只返回未完成的
        XCTAssertEqual(uncompleted.count, 2)
        XCTAssertTrue(uncompleted.allSatisfy { !$0.isCompleted })
    }

    func testRecentUncompletedRespectsLimit() throws {
        // Given: 5 个待办
        let todos = (1...5).map { ExtractedTodo(title: "任务\($0)", categoryHint: .work) }
        try sut.addBatch(todos)

        // When: 限制返回 3 条
        let result = sut.recentUncompleted(limit: 3)

        // Then: 只返回 3 条
        XCTAssertEqual(result.count, 3)
    }

    func testRecentUncompletedOrderByCreatedAt() throws {
        // Given: 多个待办（不同创建时间）
        let todo1 = ExtractedTodo(title: "任务1", categoryHint: .work)
        try sut.add(todo1)
        Thread.sleep(forTimeInterval: 0.01)  // 确保时间不同

        let todo2 = ExtractedTodo(title: "任务2", categoryHint: .work)
        try sut.add(todo2)
        Thread.sleep(forTimeInterval: 0.01)

        let todo3 = ExtractedTodo(title: "任务3", categoryHint: .work)
        try sut.add(todo3)

        // When: 获取未完成待办
        let result = sut.recentUncompleted(limit: 10)

        // Then: 按创建时间倒序
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].title, "任务3")  // 最新
        XCTAssertEqual(result[1].title, "任务2")
        XCTAssertEqual(result[2].title, "任务1")  // 最早
    }

    // MARK: - Test PendingItems

    func testPendingItemsOnlyReturnsNeedsProcessing() throws {
        // Given: 混合待处理和已处理的待办
        try sut.add(ExtractedTodo(title: "已处理任务", categoryHint: .work))
        try sut.addRawTranscript("这是一段原始转写文本")
        try sut.addRawTranscript("另一段原始转写")

        // When: 获取待处理条目
        let pending = sut.pendingItems()

        // Then: 只返回 needsAIProcessing == true 的条目
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.needsAIProcessing })
    }

    func testPendingItemsReturnsStableSortOrder() throws {
        // Given: 多个待处理条目
        try sut.addRawTranscript("第一段原始转写")
        try sut.addRawTranscript("第二段原始转写")
        try sut.addRawTranscript("第三段原始转写")

        // When: 获取待处理条目
        let pending = sut.pendingItems()

        // Then: 与主列表排序语义一致，按 sortOrder 升序稳定返回
        XCTAssertEqual(pending.map(\.rawTranscript), [
            "第三段原始转写",
            "第二段原始转写",
            "第一段原始转写"
        ])
        XCTAssertEqual(pending.map(\.sortOrder), pending.map(\.sortOrder).sorted())
    }

    // MARK: - Test AddRawTranscript [v2]

    func testAddRawTranscriptSetsNeedsAIProcessing() throws {
        // Given: 原始转写文本
        let transcript = "这是一段需要后续 AI 处理的原始语音转写文本，很长很长"

        // When: 添加原始转写
        try sut.addRawTranscript(transcript)

        // Then: needsAIProcessing == true
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertTrue(sut.todos[0].needsAIProcessing)
        XCTAssertEqual(sut.todos[0].rawTranscript, transcript)
        // 标题使用当前的智能截断策略
        XCTAssertEqual(sut.todos[0].title, TextUtils.truncateTitle(from: transcript))
        XCTAssertEqual(sut.todos[0].detail, transcript)
    }

    // MARK: - Test ReplacePendingWithExtracted [v2]

    func testReplacePendingWithExtracted() throws {
        // Given: 一个待处理条目
        let transcript = "明天去银行办卡，顺便买菜"
        try sut.addRawTranscript(transcript)

        let pendingId = sut.todos[0].id
        XCTAssertTrue(sut.todos[0].needsAIProcessing)

        // When: 用提取结果替换
        let extractedItems = [
            ExtractedTodo(title: "去银行办卡", detail: "明天去银行办卡", dueHint: "明天", categoryHint: .finance),
            ExtractedTodo(title: "买菜", detail: "顺便买菜", categoryHint: .life)
        ]
        try sut.replacePendingWithExtracted(pendingId, extractedItems)

        // Then: 原条目被删除，新条目插入
        XCTAssertEqual(sut.todos.count, 2)
        XCTAssertFalse(sut.todos.contains { $0.id == pendingId })
        XCTAssertTrue(sut.todos.allSatisfy { !$0.needsAIProcessing })

        // 验证新条目内容
        let titles = sut.todos.map { $0.title }
        XCTAssertTrue(titles.contains("去银行办卡"))
        XCTAssertTrue(titles.contains("买菜"))
    }

    func testReplacePendingWithExtractedPreservesRawTranscript() throws {
        // Given: 一个待处理条目
        let transcript = "原始语音转写"
        try sut.addRawTranscript(transcript)

        let pendingId = sut.todos[0].id

        // When: 用提取结果替换
        let extractedItem = ExtractedTodo(title: "提取的任务", categoryHint: .work)
        try sut.replacePendingWithExtracted(pendingId, [extractedItem])

        // Then: rawTranscript 被保留
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(sut.todos[0].rawTranscript, transcript)
    }

    // MARK: - Test toData() Conversion [v2]

    func testToDataConversion() throws {
        // Given: 添加一个待办
        let extracted = ExtractedTodo(
            title: "测试任务",
            detail: "任务详情",
            dueHint: "明天",
            priority: .high,
            categoryHint: .work
        )
        try sut.add(extracted)

        // When: 获取 todos
        let result = sut.todos

        // Then: toData() 转换正确
        XCTAssertEqual(result.count, 1)
        let todoData = result[0]

        XCTAssertEqual(todoData.title, "测试任务")
        XCTAssertEqual(todoData.detail, "任务详情")
        XCTAssertEqual(todoData.dueHint, "明天")
        XCTAssertEqual(todoData.priority, .high)
        XCTAssertEqual(todoData.category, .work)
        XCTAssertFalse(todoData.isCompleted)
        XCTAssertFalse(todoData.needsAIProcessing)
        XCTAssertNotNil(todoData.id)
        XCTAssertNotNil(todoData.createdAt)
    }

    func testToDataConversionWithNilDetail() throws {
        // Given: 添加一个没有详情的待办
        let extracted = ExtractedTodo(
            title: "无详情任务",
            detail: "",  // 空字符串
            categoryHint: .life
        )
        try sut.add(extracted)

        // When: 获取 todos
        let result = sut.todos

        // Then: detail 被转换为 nil
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].detail)
    }
}
