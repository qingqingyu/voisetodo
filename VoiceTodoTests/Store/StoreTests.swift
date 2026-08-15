import XCTest
import SwiftData
@testable import VoiceTodo

@MainActor
final class StoreTests: XCTestCase {
    private final class SaveFailureGate {
        var shouldFail = false

        func save(_ context: ModelContext) throws {
            if shouldFail {
                throw VoiceTodoError.storageWriteFailed("forced failure")
            }
            try context.save()
        }
    }

    // MARK: - Properties

    var sut: TodoStore!
    var modelContainer: ModelContainer!
    var modelContext: ModelContext!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()

        // 创建内存数据库用于测试
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VoiceTodoSchema.schema, configurations: config)
        modelContext = modelContainer.mainContext
        // forceMigration: true 让门闩在测试里强制跑 migration(in-memory DB 每次都是新的,
        // 但 AppGroupConfig 的版本号是全局 UserDefaults,跨测试持久,会跳过 migration)。
        sut = TodoStore(modelContext: modelContext, forceMigration: true)
    }

    override func tearDown() {
        sut = nil
        modelContext = nil
        modelContainer = nil
        super.tearDown()
    }

    // MARK: - P6: 缓存失效契约

    func testRefreshIfStaleSkipsWhenVersionUnchanged() {
        // 强制刷新会同步到当前外部版本
        XCTAssertTrue(sut.refreshIfStale(force: true), "强制刷新应执行")
        // 版本未变化时应跳过，避免无谓全量 fetch
        XCTAssertFalse(sut.refreshIfStale(force: false), "版本未变化应跳过")
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

    func testAddTodoResolvesDueDateFromDueHint() throws {
        // Given: 一个带自然语言时间的待办
        let referenceWindowStart = Calendar.current.startOfDay(for: Date())
        let extractedTodo = ExtractedTodo(
            title: "买牛奶",
            detail: "明天上午买牛奶",
            dueHint: "明天",
            categoryHint: .life
        )

        // When: 添加到 store
        try sut.add(extractedTodo)

        // Then: dueHint 保留，同时解析出真实日期供周视图分组
        let dueDate = try XCTUnwrap(sut.todos[0].dueDate)
        assertDateIsTomorrowRelativeToTestWindow(dueDate, windowStart: referenceWindowStart)
        XCTAssertEqual(sut.todos[0].dueHint, "明天")
    }

    func testAddTodoWithoutDueHintKeepsDueDateNil() throws {
        // Given: 一个没有时间信息的待办
        let extractedTodo = ExtractedTodo(
            title: "买牙膏",
            detail: "买牙膏",
            categoryHint: .life
        )

        // When: 添加到 store
        try sut.add(extractedTodo)

        // Then: 保持未安排，周视图不强行放到今天
        XCTAssertNil(sut.todos[0].dueDate)
    }

    func testAddTodoPersistsExplicitTimeBucketWithoutInventingClockTime() throws {
        let extractedTodo = ExtractedTodo(
            title: "去健身",
            dueDate: Calendar.current.startOfDay(for: Date()),
            dueHint: "今天晚上",
            timeBucket: .evening,
            categoryHint: .health
        )

        try sut.add(extractedTodo)
        sut.refreshTodos()

        XCTAssertEqual(sut.todos.first?.timeBucket, .evening)
        XCTAssertFalse(sut.todos.first?.hasDueTime ?? true)
    }

    func testAddTodoWithFuzzyTimeButNoDateFallsBackToToday() throws {
        let extractedTodo = ExtractedTodo(
            title: "晚上去健身",
            detail: "晚上去健身",
            dueHint: "晚上",
            timeBucket: .evening,
            categoryHint: .health
        )

        try sut.add(extractedTodo)
        sut.refreshTodos()

        let saved = try XCTUnwrap(sut.todos.first)
        // "时段⇒今天"决策(commit 4cba205):只有 timeBucket 没日期时补今天 0 点,
        // 让任务落进「今日/时段」分区而非 Unscheduled——
        // 否则卡片显示 "Evening" 但任务在 Unscheduled,自相矛盾。
        let savedDueDate = try XCTUnwrap(saved.dueDate, "时段⇒今天决策应补今天")
        let calendar = Calendar.current
        XCTAssertEqual(
            calendar.startOfDay(for: savedDueDate),
            calendar.startOfDay(for: Date()),
            "补的 dueDate 应是今天 0 点"
        )
        XCTAssertFalse(saved.hasDueTime)
        XCTAssertEqual(saved.timeBucket, .evening)
    }

    func testAddRollbackDoesNotPersistFailedInsertOnLaterSave() throws {
        let gate = SaveFailureGate()
        sut = TodoStore(modelContext: modelContext, saveAction: gate.save)

        gate.shouldFail = true
        XCTAssertThrowsError(try sut.add(ExtractedTodo(title: "失败新增", categoryHint: .work)))
        XCTAssertTrue(sut.todos.isEmpty)

        gate.shouldFail = false
        try sut.add(ExtractedTodo(title: "成功新增", categoryHint: .life))
        sut.refreshTodos()

        XCTAssertEqual(sut.todos.map(\.title), ["成功新增"])
    }

    func testUpdateRollbackKeepsOriginalValueOnLaterSave() throws {
        let gate = SaveFailureGate()
        sut = TodoStore(modelContext: modelContext, saveAction: gate.save)
        try sut.add(ExtractedTodo(title: "原始标题", categoryHint: .work))
        let id = try XCTUnwrap(sut.todos.first?.id)

        gate.shouldFail = true
        let snapshotBeforeUpdate = try XCTUnwrap(sut.todos.first)
        XCTAssertThrowsError(try sut.updateFull(id, update: TodoDetailUpdate(from: snapshotBeforeUpdate, title: "失败标题")))
        XCTAssertEqual(sut.todos.first?.title, "原始标题")

        gate.shouldFail = false
        try sut.add(ExtractedTodo(title: "触发后续保存", categoryHint: .life))
        sut.refreshTodos()

        let original = try XCTUnwrap(sut.todos.first(where: { $0.id == id }))
        XCTAssertEqual(original.title, "原始标题")
    }

    func testDeleteRollbackKeepsOriginalTodoOnLaterSave() throws {
        let gate = SaveFailureGate()
        sut = TodoStore(modelContext: modelContext, saveAction: gate.save)
        try sut.add(ExtractedTodo(title: "不要丢失", categoryHint: .work))
        let id = try XCTUnwrap(sut.todos.first?.id)

        gate.shouldFail = true
        XCTAssertThrowsError(try sut.delete(id))
        XCTAssertTrue(sut.todos.contains { $0.id == id })

        gate.shouldFail = false
        try sut.add(ExtractedTodo(title: "后续保存", categoryHint: .life))
        sut.refreshTodos()

        XCTAssertTrue(sut.todos.contains { $0.id == id })
        XCTAssertTrue(sut.todos.contains { $0.title == "后续保存" })
    }

    func testUpdateSystemCalendarEventIdentifierPersistsOnTodo() throws {
        let extractedTodo = ExtractedTodo(
            title: "完成英语背诵",
            detail: "今天完成英语背诵",
            dueHint: "今天",
            categoryHint: .study
        )
        try sut.add(extractedTodo)

        try sut.updateSystemCalendarEventIdentifier("event-123", for: extractedTodo.id)

        XCTAssertEqual(sut.todos[0].systemCalendarEventIdentifier, "event-123")
        sut.refreshTodos()
        XCTAssertEqual(sut.todos[0].systemCalendarEventIdentifier, "event-123")
    }

    func testAddBatchResolvesWeekdayDueDate() throws {
        // Given: 一个带周几时间的待办
        let item = ExtractedTodo(
            title: "交周报",
            detail: "周五前交周报",
            dueHint: "周五前",
            categoryHint: .work
        )

        // When: 批量添加
        try sut.addBatch([item])

        // Then: 解析到接下来一个周五
        let dueDate = try XCTUnwrap(sut.todos[0].dueDate)
        XCTAssertEqual(Calendar.current.component(.weekday, from: dueDate), 6)
    }

    func testDueDateResolverRespectsNextWeekPrefix() throws {
        // Given: 下周五明确指向下一周，不是本周最近的周五
        let calendar = Calendar(identifier: .gregorian)
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))

        // When: 解析下周五
        let resolved = TodoDueDateResolver.resolve(
            dueHint: "下周五前",
            referenceDate: reference,
            calendar: calendar
        )

        // Then: 落到下一周周五
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15)))
        XCTAssertTrue(calendar.isDate(try XCTUnwrap(resolved), inSameDayAs: expected))
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

    func testAddBatchPreservesInputLocale() throws {
        let items = [
            ExtractedTodo(title: "Review notes", categoryHint: .work),
            ExtractedTodo(title: "Email Alex", categoryHint: .work)
        ]

        try sut.addBatch(items, localeIdentifier: "en-US")

        XCTAssertEqual(sut.todos.map(\.localeIdentifier), ["en-US", "en-US"])
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
        let original = sut.todos[0]

        // When: 更新标题
        try sut.updateFull(todoId, update: TodoDetailUpdate(from: original, title: "新标题"))

        // Then: 标题已更新
        XCTAssertEqual(sut.todos[0].title, "新标题")
    }

    func testUpdateInvalidId() {
        // Given: 无效的 ID
        let invalidId = UUID()

        // When & Then: 抛出错误
        XCTAssertThrowsError(try sut.updateFull(invalidId, update: TodoDetailUpdate(
            title: "新标题",
            detail: nil,
            category: nil,
            priority: nil,
            dueDate: nil,
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil
        ))) { error in
            XCTAssertTrue(error is VoiceTodoError)
        }
    }

    // MARK: - Test RecentUncompleted

    func testRecentUncompletedOnlyReturnsUncompleted() async throws {
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
        let uncompleted = try await sut.recentUncompleted(limit: 10)

        // Then: 只返回未完成的
        XCTAssertEqual(uncompleted.count, 2)
        XCTAssertTrue(uncompleted.allSatisfy { !$0.isCompleted })
    }

    func testRecentUncompletedRespectsLimit() async throws {
        // Given: 5 个待办
        let todos = (1...5).map { ExtractedTodo(title: "任务\($0)", categoryHint: .work) }
        try sut.addBatch(todos)

        // When: 限制返回 3 条
        let result = try await sut.recentUncompleted(limit: 3)

        // Then: 只返回 3 条
        XCTAssertEqual(result.count, 3)
    }

    func testRecentUncompletedFiltersRecurringCandidatesBeforeApplyingLimit() async throws {
        // Given: 排序靠前的是未来才会出现的规律任务，后面有一条今天应该显示的普通任务
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)

        let futureRecurring = TodoItemData(
            title: "未来周任务",
            dueDate: tomorrow,
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today,
            sortOrder: -3
        )
        let anotherFutureRecurring = TodoItemData(
            title: "另一个未来周任务",
            dueDate: tomorrow,
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today,
            sortOrder: -2
        )
        let visibleToday = TodoItemData(
            title: "今天应显示",
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([futureRecurring, anotherFutureRecurring, visibleToday])

        // When: 只取 1 条最近未完成
        let result = try await sut.recentUncompleted(limit: 1)

        // Then: 先过滤掉今天不发生的规律任务，再应用 limit
        XCTAssertEqual(result.map(\.title), ["今天应显示"])
    }

    func testRecentUncompletedOrderByCreatedAt() async throws {
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
        let result = try await sut.recentUncompleted(limit: 10)

        // Then: 按创建时间倒序
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].title, "任务3")  // 最新
        XCTAssertEqual(result[1].title, "任务2")
        XCTAssertEqual(result[2].title, "任务1")  // 最早
    }

    // MARK: - Test PendingItems

    func testPendingItemsOnlyReturnsNeedsProcessing() async throws {
        // Given: 混合待处理和已处理的待办
        try sut.add(ExtractedTodo(title: "已处理任务", categoryHint: .work))
        try sut.addRawTranscript("这是一段原始转写文本")
        try sut.addRawTranscript("另一段原始转写")

        // When: 获取待处理条目
        let pending = try await sut.pendingItems()

        // Then: 只返回 needsAIProcessing == true 的条目
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.needsAIProcessing })
    }

    func testPendingItemsReturnsStableSortOrder() async throws {
        // Given: 多个待处理条目
        try sut.addRawTranscript("第一段原始转写")
        try sut.addRawTranscript("第二段原始转写")
        try sut.addRawTranscript("第三段原始转写")

        // When: 获取待处理条目
        let pending = try await sut.pendingItems()

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
        let created = try sut.addRawTranscript(transcript)

        // Then: needsAIProcessing == true
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(created.id, sut.todos[0].id)
        XCTAssertTrue(sut.todos[0].needsAIProcessing)
        XCTAssertEqual(sut.todos[0].rawTranscript, transcript)
        // 标题使用当前的智能截断策略
        XCTAssertEqual(sut.todos[0].title, TextUtils.truncateTitle(from: transcript))
        XCTAssertEqual(sut.todos[0].detail, transcript)
        // 离线兜底条目标 .rawFallback,Today 页据此把它路由到「没能识别」组,
        // 不再混进正常任务(参见 HomeCalendarState.unparsedTodos)。
        XCTAssertEqual(sut.todos[0].extractionOutcome, .rawFallback)
    }

    // MARK: - Test AddManualUnparsedTranscript

    func testAddManualUnparsedTranscriptDoesNotEnterPendingQueue() async throws {
        // Given: 确定性解析失败的原文
        let transcript = "一口气说了二十几条待办导致 AI 输出被截断"

        // When: 存为手动卡片
        let created = try sut.addManualUnparsedTranscript(transcript, localeIdentifier: "zh-Hans")

        // Then: 不进 pending 自动恢复队列(needsAIProcessing=false),
        // 但原文完整保留,且路由到「没能识别」组(.unparsed)。
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(created.id, sut.todos[0].id)
        XCTAssertFalse(sut.todos[0].needsAIProcessing)
        XCTAssertEqual(sut.todos[0].rawTranscript, transcript)
        XCTAssertEqual(sut.todos[0].detail, transcript)
        XCTAssertEqual(sut.todos[0].extractionOutcome, .unparsed)
        XCTAssertEqual(sut.todos[0].localeIdentifier, "zh-Hans")
        let pending = try await sut.pendingItems()
        XCTAssertTrue(pending.isEmpty, "手动卡片不得被 PendingRecoveryFlow 自动认领")
    }

    // MARK: - Test HoldPendingAsUnparsed

    func testHoldPendingAsUnparsedStopsAutoRecoveryAndKeepsTranscript() async throws {
        // Given: 一条 pending(如 AddTodoIntent 离线写入的超长转写)
        try sut.addRawTranscript("会被确定性截断的超长转写")
        let pendingId = sut.todos[0].id
        let pendingBefore = try await sut.pendingItems()
        XCTAssertEqual(pendingBefore.count, 1)

        // When: 转持为手动卡片
        try sut.holdPendingAsUnparsed(id: pendingId)

        // Then: 退出 pending 队列但条目仍在,原文保留、路由到「没能识别」组
        let pendingAfter = try await sut.pendingItems()
        XCTAssertTrue(pendingAfter.isEmpty)
        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(sut.todos[0].id, pendingId)
        XCTAssertEqual(sut.todos[0].extractionOutcome, .unparsed)
        XCTAssertEqual(sut.todos[0].rawTranscript, "会被确定性截断的超长转写")
    }

    func testHoldPendingAsUnparsedThrowsForMissingTodo() throws {
        let missingId = UUID()

        XCTAssertThrowsError(try sut.holdPendingAsUnparsed(id: missingId)) { error in
            XCTAssertEqual(error as? VoiceTodoError, .todoNotFound(missingId))
        }
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

    func testReplacePendingWithExtractedPreservesPendingLocale() throws {
        let transcript = "review the English notes"
        let pending = try sut.addRawTranscript(transcript, localeIdentifier: "en-US")

        let extractedItems = [
            ExtractedTodo(title: "Review English notes", categoryHint: .study)
        ]
        try sut.replacePendingWithExtracted(pending.id, extractedItems)

        XCTAssertEqual(sut.todos.count, 1)
        XCTAssertEqual(sut.todos[0].localeIdentifier, "en-US")
    }

    func testReplacePendingBatchPreservesPerExtractedTodoLocale() throws {
        let englishPending = try sut.addRawTranscript("english pending", localeIdentifier: "en-US")
        let chinesePending = try sut.addRawTranscript("中文 pending", localeIdentifier: "zh-Hans")
        let englishTodoID = UUID()
        let chineseTodoID = UUID()
        let extractedItems = [
            ExtractedTodo(id: englishTodoID, title: "Review English notes", localeIdentifier: "en-US"),
            ExtractedTodo(id: chineseTodoID, title: "整理中文笔记", localeIdentifier: "zh-Hans")
        ]

        try sut.replacePendingBatchWithExtracted(
            [englishPending.id, chinesePending.id],
            extractedItems,
            rawTranscript: nil
        )

        let savedLocales = Dictionary(uniqueKeysWithValues: sut.todos.map { ($0.id, $0.localeIdentifier) })
        XCTAssertEqual(savedLocales[englishTodoID] ?? nil, "en-US")
        XCTAssertEqual(savedLocales[chineseTodoID] ?? nil, "zh-Hans")
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

    // MARK: - Test Recurrence

    func testCalendarOccurrencesExpandsDailyRecurringTodo() async throws {
        // Given: 一个每天重复的待办
        let today = Calendar.current.startOfDay(for: Date())
        let item = TodoItemData(
            title: "喝水",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])

        // When: 查询三天日历 occurrence
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: today))
        let occurrences = try await sut.calendarOccurrences(from: today, to: end)

        // Then: 三天都出现
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences.map(\.todo.title), ["喝水", "喝水", "喝水"])
        XCTAssertTrue(occurrences.allSatisfy { !$0.isCompleted })
    }

    func testCalendarOccurrencesStopsAtRecurrenceEndDate() async throws {
        // Given: 一个只持续 7 天的每天重复待办
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))
        let rangeEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 11)))
        let item = TodoItemData(
            title: "小单元测试",
            recurrenceRule: RecurrenceRule(frequency: .daily, endDate: end),
            createdAt: start,
            sortOrder: -1
        )
        try sut.seedForUITests([item])

        // When: 查询包含第 8 天的区间
        let occurrences = try await sut.calendarOccurrences(from: start, to: rangeEnd)

        // Then: 只展开 7 次，第 8 天不再出现
        XCTAssertEqual(occurrences.count, 7)
        XCTAssertEqual(occurrences.map { calendar.component(.day, from: $0.occurrenceDate) }, [4, 5, 6, 7, 8, 9, 10])
    }

    func testCalendarOccurrencesExpandsBoundedDailyAcrossMonthBoundary() async throws {
        // Given: 一个从 5 月 28 日开始、持续 7 天的每天重复待办
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 28)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3)))
        let rangeEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 4)))
        let item = TodoItemData(
            title: "小单元测试",
            recurrenceRule: RecurrenceRule(frequency: .daily, endDate: end),
            createdAt: start,
            sortOrder: -1
        )
        try sut.seedForUITests([item])

        // When: 查询跨月且包含第 8 天的区间
        let occurrences = try await sut.calendarOccurrences(from: start, to: rangeEnd)

        // Then: 5 月 28 日到 6 月 3 日出现，第 8 天 6 月 4 日不出现
        XCTAssertEqual(occurrences.count, 7)
        XCTAssertEqual(
            occurrences.map {
                "\(calendar.component(.month, from: $0.occurrenceDate))-\(calendar.component(.day, from: $0.occurrenceDate))"
            },
            ["5-28", "5-29", "5-30", "5-31", "6-1", "6-2", "6-3"]
        )
    }

    func testToggleRecurringOccurrenceOnlyCompletesSelectedDay() async throws {
        // Given: 一个每天重复的待办
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        let item = TodoItemData(
            title: "站立休息",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])
        let todoId = try XCTUnwrap(sut.todos.first?.id)

        // When: 只完成今天
        try sut.toggleOccurrenceComplete(todoId, on: today)

        // Then: 今天完成，明天仍未完成
        let todayOccurrences = try await sut.calendarOccurrences(from: today, to: today)
        let todayOccurrence = try XCTUnwrap(todayOccurrences.first)
        let tomorrowOccurrences = try await sut.calendarOccurrences(from: tomorrow, to: tomorrow)
        let tomorrowOccurrence = try XCTUnwrap(tomorrowOccurrences.first)
        XCTAssertTrue(todayOccurrence.isCompleted)
        XCTAssertFalse(tomorrowOccurrence.isCompleted)

        // When: 再次切换今天
        try sut.toggleOccurrenceComplete(todoId, on: today)

        // Then: 今天恢复未完成
        let restoredOccurrences = try await sut.calendarOccurrences(from: today, to: today)
        XCTAssertFalse(try XCTUnwrap(restoredOccurrences.first).isCompleted)
    }

    func testToggleOccurrenceCompleteIgnoresNonOccurringDate() async throws {
        // Given: 一个明天才出现的每周待办
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        let tomorrowWeekday = Calendar.current.component(.weekday, from: tomorrow)
        let item = TodoItemData(
            title: "每周复盘",
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [tomorrowWeekday]),
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])
        let todoId = try XCTUnwrap(sut.todos.first?.id)

        // When: 尝试完成今天这个并不存在的 occurrence
        try sut.toggleOccurrenceComplete(todoId, on: today)

        // Then: 不写入无效 completion，明天仍保持未完成
        let completions = try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>())
        XCTAssertTrue(completions.isEmpty)
        let tomorrowOccurrences = try await sut.calendarOccurrences(from: tomorrow, to: tomorrow)
        let tomorrowOccurrence = try XCTUnwrap(tomorrowOccurrences.first)
        XCTAssertFalse(tomorrowOccurrence.isCompleted)
    }

    func testUpdateRecurrenceResetsCompletedBaseState() async throws {
        // Given: 一条已经完成的普通待办
        let today = Calendar.current.startOfDay(for: Date())
        let item = TodoItemData(
            title: "完成后改成规律任务",
            dueDate: today,
            isCompleted: true,
            completedAt: today,
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])
        let todoId = try XCTUnwrap(sut.todos.first?.id)

        // When: 开启每天重复
        try sut.updateRecurrence(todoId, recurrenceRule: RecurrenceRule(frequency: .daily))

        // Then: base 完成态被清掉，首页和最近未完成/Widget 入口语义一致
        XCTAssertFalse(try XCTUnwrap(sut.todos.first).isCompleted)
        let occurrenceList = try await sut.calendarOccurrences(from: today, to: today)
        let occurrence = try XCTUnwrap(occurrenceList.first)
        XCTAssertFalse(occurrence.isCompleted)
        let recentTitles = try await sut.recentUncompleted(limit: 1).map(\.title)
        XCTAssertEqual(recentTitles, ["完成后改成规律任务"])
    }

    func testUpdateFullDisablesRecurrenceAndDeletesOccurrenceCompletions() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let item = TodoItemData(
            title: "停止重复的任务",
            dueDate: today,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])
        let todo = try XCTUnwrap(sut.todos.first)
        try sut.toggleOccurrenceComplete(todo.id, on: today)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>()).count, 1)

        try sut.updateFull(
            todo.id,
            update: TodoDetailUpdate(
                title: todo.title,
                detail: todo.detail,
                category: nil,
                priority: nil,
                dueDate: todo.dueDate,
                hasDueTime: todo.hasDueTime,
                timeBucket: todo.timeBucket,
                dueHint: nil,
                recurrenceRule: nil
            )
        )

        XCTAssertNil(sut.todos.first?.recurrenceRule)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>()).isEmpty)
    }

    /// 详情页加的「重复结束日期编辑器」(s15) 写入 endDate 后,store.updateFull 能正确持久化。
    /// 验证 RecurrenceRule.init 的 startOfDay normalize 也生效。
    func testUpdateFullPersistsRecurrenceEndDate() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let item = TodoItemData(
            title: "带结束日的重复",
            dueDate: today,
            recurrenceRule: RecurrenceRule(frequency: .daily),
            createdAt: today,
            sortOrder: -1
        )
        try sut.seedForUITests([item])
        let todo = try XCTUnwrap(sut.todos.first)

        // +1 个月,带些非零时分量(模拟 DatePicker 任选时刻) —— init 应 startOfDay normalize。
        let endDateRaw = Calendar.current.date(byAdding: .month, value: 1, to: today)!
            .addingTimeInterval(3600 * 13 + 60 * 37)
        let expectedNormalized = Calendar.current.startOfDay(for: endDateRaw)

        try sut.updateFull(
            todo.id,
            update: TodoDetailUpdate(
                title: todo.title,
                detail: todo.detail,
                category: nil,
                priority: nil,
                dueDate: todo.dueDate,
                hasDueTime: todo.hasDueTime,
                timeBucket: todo.timeBucket,
                dueHint: nil,
                recurrenceRule: RecurrenceRule(frequency: .daily, endDate: endDateRaw)
            )
        )

        let saved = try XCTUnwrap(sut.todos.first)
        XCTAssertEqual(saved.recurrenceRule?.endDate, expectedNormalized, "endDate 应被持久化并 startOfDay normalize")
    }

    func testUpdateFullClearsDetailWhenCommandDetailIsNil() throws {
        let item = TodoItemData(title: "清空备注", detail: "旧备注", sortOrder: -1)
        try sut.seedForUITests([item])

        try sut.updateFull(
            item.id,
            update: TodoDetailUpdate(
                title: item.title,
                detail: nil,
                category: nil,
                priority: nil,
                dueDate: nil,
                hasDueTime: false,
                timeBucket: nil,
                dueHint: nil,
                recurrenceRule: nil
            )
        )

        XCTAssertNil(sut.todos.first?.detail)
    }

    func testUpdateFullClearsDueHintWhenCommandDueHintIsEmpty() throws {
        let item = TodoItemData(title: "清空旧时间提示", dueHint: "明天", sortOrder: -1)
        try sut.seedForUITests([item])

        try sut.updateFull(
            item.id,
            update: TodoDetailUpdate(
                title: item.title,
                detail: item.detail,
                category: nil,
                priority: nil,
                dueDate: nil,
                hasDueTime: false,
                timeBucket: nil,
                dueHint: "",
                recurrenceRule: nil
            )
        )

        XCTAssertNil(sut.todos.first?.dueHint)
    }

    func testWeeklyAndMonthlyRecurrenceExpansion() async throws {
        // Given: 固定日期区间内的每周和每月规则
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let rangeStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let rangeEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10)))

        let weekly = TodoItemData(
            title: "周会",
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [2, 4]),
            createdAt: start,
            sortOrder: -2
        )
        let monthly = TodoItemData(
            title: "交房租",
            recurrenceRule: RecurrenceRule(frequency: .monthly, dayOfMonth: 5),
            createdAt: start,
            sortOrder: -1
        )
        try sut.seedForUITests([weekly, monthly])

        // When: 查询 2026-05-04 到 2026-05-10
        let occurrences = try await sut.calendarOccurrences(from: rangeStart, to: rangeEnd)

        // Then: 周一、周三出现周会，5 号出现月任务
        XCTAssertEqual(occurrences.map(\.todo.title), ["周会", "交房租", "周会"])
        XCTAssertEqual(occurrences.map { calendar.component(.day, from: $0.occurrenceDate) }, [4, 5, 6])
    }

    func testMonthlyRecurrenceSkipsMissingDayAcrossMonthBoundary() async throws {
        // Given: 每月 31 号重复的待办，从 2026-01-31 开始
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31)))
        let rangeStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let rangeEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))

        let monthly = TodoItemData(
            title: "月末复盘",
            recurrenceRule: RecurrenceRule(frequency: .monthly, dayOfMonth: 31),
            createdAt: start,
            sortOrder: -1
        )
        try sut.seedForUITests([monthly])

        // When: 查询 2 月到 3 月底
        let occurrences = try await sut.calendarOccurrences(from: rangeStart, to: rangeEnd)

        // Then: 2 月没有 31 号所以不出现，3 月 31 日出现一次
        XCTAssertEqual(occurrences.map(\.todo.title), ["月末复盘"])
        let occurrenceDate = try XCTUnwrap(occurrences.first?.occurrenceDate)
        XCTAssertEqual(calendar.component(.month, from: occurrenceDate), 3)
        XCTAssertEqual(calendar.component(.day, from: occurrenceDate), 31)
    }

    func testLegacyTodoWithoutRecurrenceFieldsReadsAsNormalTodo() async throws {
        // Given: 模拟旧版本普通待办，没有任何 recurrence 字段
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let legacyItem = TodoItem(
            title: "旧待办",
            dueDate: today,
            createdAt: today,
            sortOrder: -1
        )
        modelContext.insert(legacyItem)
        try modelContext.save()

        // When: 重新刷新并按今天查询 occurrence
        sut.refreshTodos()
        let occurrences = try await sut.calendarOccurrences(from: today, to: today)

        // Then: 按普通单次待办读取，不带重复规则
        XCTAssertNil(sut.todos.first?.recurrenceRule)
        XCTAssertEqual(occurrences.map(\.todo.title), ["旧待办"])
        XCTAssertFalse(try XCTUnwrap(occurrences.first).isCompleted)
    }

    func testLegacyTodoWithDueHintMigratesDueDateFromCreatedAt() async throws {
        // Given: 旧版本数据只有 dueHint，没有 dueDate
        let calendar = Calendar(identifier: .gregorian)
        let createdAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
        let expectedDueDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5)))
        let legacyItem = TodoItem(
            title: "旧明天待办",
            dueHint: "明天",
            dueDate: nil,
            createdAt: createdAt,
            sortOrder: -1
        )
        modelContext.insert(legacyItem)
        try modelContext.save()

        // When: 重新初始化 Store 触发迁移
        // forceMigration: true 绕过门闩,因为这个测试就是要验证 migration 跑过后 dueDate 被填上
        sut = TodoStore(modelContext: modelContext, forceMigration: true)

        // Then: dueDate 按旧待办创建日解析，不会落入每天的未安排区
        let migrated = try XCTUnwrap(sut.todos.first)
        let dueDate = try XCTUnwrap(migrated.dueDate)
        XCTAssertTrue(calendar.isDate(dueDate, inSameDayAs: expectedDueDate))
        let occurrenceTitles = try await sut.calendarOccurrences(from: expectedDueDate, to: expectedDueDate).map(\.todo.title)
        XCTAssertEqual(occurrenceTitles, ["旧明天待办"])
    }

    func testLegacyVoiceCaptureRecordsArePurgedWhenStoreInitializes() throws {
        let legacyRecord = VoiceCaptureRecord(
            transcript: "旧语音历史",
            localeIdentifier: "zh-Hans"
        )
        modelContext.insert(legacyRecord)
        try modelContext.save()
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<VoiceCaptureRecord>()).count, 1)

        sut = TodoStore(modelContext: modelContext, forceMigration: true)

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<VoiceCaptureRecord>()).isEmpty)
    }

    func testResetForUITestsDeletesLegacyVoiceCaptureRecords() throws {
        let legacyRecord = VoiceCaptureRecord(
            transcript: "UI 测试前应清理的旧语音历史",
            localeIdentifier: "zh-Hans"
        )
        modelContext.insert(legacyRecord)
        try modelContext.save()

        try sut.resetForUITests()

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<VoiceCaptureRecord>()).isEmpty)
    }

    private func assertDateIsTomorrowRelativeToTestWindow(
        _ date: Date,
        windowStart: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let calendar = Calendar.current
        let windowEnd = calendar.startOfDay(for: Date())
        let expectedDates = [
            calendar.date(byAdding: .day, value: 1, to: windowStart),
            calendar.date(byAdding: .day, value: 1, to: windowEnd)
        ].compactMap { $0 }

        XCTAssertTrue(
            expectedDates.contains { calendar.isDate(date, inSameDayAs: $0) },
            "Expected \(date) to be tomorrow relative to the test execution window.",
            file: file,
            line: line
        )
    }

    // MARK: - Read-only enforcement for TodoQueryActor

    /// 防御测试：`TodoQueryActor` 标注为 @ModelActor 编译期有完整写权限，
    /// 文档约定"只读"靠人工把关。此测试调三个读方法，断言主上下文的 `todos` 不被修改 ——
    /// 一旦有人误在 actor 内 `modelContext.save()` 写库，主上下文会 autosave 同步，本测试会失败。
    ///
    /// 覆盖盲区：本测试只能检测「写 + save」，不能检测「写但不 save」。
    /// 后者在 actor 内无实际意义（独立 ModelContext 不 save 就随 actor 退出而丢），
    /// 因此不构成真实威胁。如未来 SwiftData 提供 readonly ModelContext，可替换为编译期强制。
    func testQueryActorReadMethodsDoNotMutateStore() async throws {
        try sut.addBatch([
            ExtractedTodo(title: "未完成", categoryHint: .work),
            ExtractedTodo(title: "已完成", categoryHint: .life),
        ])
        try sut.toggleComplete(sut.todos[1].id)

        let snapshotBefore = sut.todos.map { $0.id }
        let snapshotCompletedBefore = sut.todos.map(\.isCompleted)

        // 三个读方法都走 queryActor
        _ = try await sut.recentUncompleted(limit: 10)
        _ = try await sut.pendingItems()
        let today = Calendar.current.startOfDay(for: Date())
        _ = try await sut.calendarOccurrences(from: today, to: today)

        // 比对：id 顺序 + 完成状态都应不变
        XCTAssertEqual(sut.todos.map { $0.id }, snapshotBefore, "读方法不应改变 todos 的顺序或数量")
        XCTAssertEqual(sut.todos.map(\.isCompleted), snapshotCompletedBefore, "读方法不应改变 todos 的完成状态")
    }

    // MARK: - 拖拽排序（局部重排）

    /// 工具:添加一个未完成 todo 并返回其 id。
    private func addReorderTarget(_ title: String) throws -> UUID {
        try sut.add(ExtractedTodo(title: title, categoryHint: .work))
        return try XCTUnwrap(sut.todos.last { $0.title == title }?.id)
    }

    /// 全量重排:行为是"按 ids 顺序赋值 base+0, base+1, ..., base+N-1"。
    /// base = 子集当前最小 sortOrder(nextSortOrderForNewItem 用 min-1 策略,通常是负数)。
    func testReorderFullSetAppliesBasePlusIndex() throws {
        let a = try addReorderTarget("A")
        let b = try addReorderTarget("B")
        let c = try addReorderTarget("C")

        let before = Dictionary(uniqueKeysWithValues: sut.todos.map { ($0.id, $0.sortOrder) })

        try sut.reorder(ids: [c, b, a])

        let expectedBase = min(before[a]!, before[b]!, before[c]!)
        let byId = Dictionary(uniqueKeysWithValues: sut.todos.map { ($0.id, $0.sortOrder) })
        XCTAssertEqual(byId[c], expectedBase + 0)
        XCTAssertEqual(byId[b], expectedBase + 1)
        XCTAssertEqual(byId[a], expectedBase + 2)
    }

    /// 局部重排:只动传入 ids 的 sortOrder(按 base+index),其他 todo 不变。
    /// 对应「稍后」section 拖拽——子集重排不能污染其他 section 的相对顺序。
    func testReorderSubsetKeepsOthersUnchanged() throws {
        let a = try addReorderTarget("A")
        let b = try addReorderTarget("B")
        let c = try addReorderTarget("C")

        let before = Dictionary(uniqueKeysWithValues: sut.todos.map { ($0.id, $0.sortOrder) })

        // 只重排 A 和 C,反序
        try sut.reorder(ids: [c, a])

        let expectedBase = min(before[a]!, before[c]!)
        let byId = Dictionary(uniqueKeysWithValues: sut.todos.map { ($0.id, $0.sortOrder) })
        XCTAssertEqual(byId[c], expectedBase + 0)
        XCTAssertEqual(byId[a], expectedBase + 1)
        XCTAssertEqual(byId[b], before[b]!, "B 的 sortOrder 不应被改")
    }

    /// 不存在的 id 必须显式抛错,不静默吞掉(遵循 CLAUDE.md 错误显式传播规则)。
    /// 条目缺失按 .todoNotFound 精准断言(VoiceTodoError 文档:取代字符串式 storageReadFailed)。
    func testReorderThrowsOnUnknownId() throws {
        _ = try addReorderTarget("A")
        XCTAssertThrowsError(try sut.reorder(ids: [UUID()])) { error in
            guard case VoiceTodoError.todoNotFound = error else {
                return XCTFail("期望 todoNotFound,实际 \(error)")
            }
        }
    }

    /// 已完成 todo 不参与 reorder —— fetch 已过滤,传入其 id 应抛错。
    func testReorderThrowsOnCompletedId() throws {
        let a = try addReorderTarget("A")
        try sut.toggleComplete(a)

        XCTAssertThrowsError(try sut.reorder(ids: [a])) { error in
            guard case VoiceTodoError.todoNotFound = error else {
                return XCTFail("期望 todoNotFound,实际 \(error)")
            }
        }
    }

    /// 空数组是合法 no-op,不抛错也不改任何 sortOrder。
    func testReorderEmptyIdsIsNoOp() throws {
        let a = try addReorderTarget("A")
        let before = sut.todos.first { $0.id == a }!.sortOrder

        try sut.reorder(ids: [])

        let after = sut.todos.first { $0.id == a }!.sortOrder
        XCTAssertEqual(before, after)
    }

    // MARK: - 跨天事件(Multi-day span,详见 docs/multi-day-span-events.md)
    // 时区口径:occurrence 查询走 TodoQueryActor(用 Calendar.current,见 TodoQueryActor.swift:88),
    // 这里测试也用 Calendar(identifier: .gregorian)(继承 .current 时区)对齐。
    // 与 TodoDetailUpdateTests(锁 UTC,测纯归一化逻辑)的区别:那边测的是 TodoSpan.normalized
    // 的纯函数行为,这边测的是 Store 端到端 occurrence 展开,必须跟实现同口径。

    func testCalendarOccurrences_multiDayEvent_producesOnePerDayWithSpanMetadata() async throws {
        // 跨 3 天的事件(8/14 → 8/16),应产生 3 个 occurrence,每个带正确的 spanIndex/spanCount
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 14)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
        let item = TodoItemData(title: "周末出游", dueDate: start, eventEndDate: end)
        try sut.seedForUITests([item])

        let occurrences = try await sut.calendarOccurrences(from: start, to: end)

        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences[0].occurrenceDate, start)
        XCTAssertTrue(occurrences[0].isSpanStart)
        XCTAssertFalse(occurrences[0].isSpanEnd)
        XCTAssertEqual(occurrences[0].spanCount, 3)
        XCTAssertEqual(occurrences[0].spanIndex, 0)
        XCTAssertEqual(occurrences[1].spanIndex, 1)
        XCTAssertEqual(occurrences[1].spanCount, 3)
        XCTAssertFalse(occurrences[1].isSpanStart)
        XCTAssertFalse(occurrences[1].isSpanEnd)
        XCTAssertEqual(occurrences[2].spanIndex, 2)
        XCTAssertTrue(occurrences[2].isSpanEnd)
    }

    func testCalendarOccurrences_multiDayEvent_crossMonth_spanCountStaysTotal() async throws {
        // 跨月事件 8/30 → 9/2(共 4 天),查 8 月只覆盖 8/30 + 8/31,但 spanCount 仍是 4
        let calendar = Calendar(identifier: .gregorian)
        let aug30 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let sep2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
        let augStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let augEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31)))

        let item = TodoItemData(title: "跨月会议", dueDate: aug30, eventEndDate: sep2)
        try sut.seedForUITests([item])

        let occurrences = try await sut.calendarOccurrences(from: augStart, to: augEnd)

        XCTAssertEqual(occurrences.count, 2)
        // 关键断言:窗口内只看到 2 天,但事件总天数仍是 4
        XCTAssertEqual(occurrences[0].spanCount, 4)
        XCTAssertEqual(occurrences[0].spanIndex, 0)
        XCTAssertEqual(occurrences[1].spanIndex, 1)
    }

    func testToggleOccurrence_onMultiDayEvent_marksWholeItemCompletedAndNoOccurrenceRecord() async throws {
        // 跨天事件在中间日打勾 → 整体标记完成(recurrenceRule == nil 走 toggleComplete 短路),
        // 不产生 TodoOccurrenceCompletion 记录。跨天事件无"逐日完成"概念,完成是整体标记。
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 14)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
        let item = TodoItemData(title: "周末出游", dueDate: start, eventEndDate: end)
        try sut.seedForUITests([item])
        let todoId = try XCTUnwrap(sut.todos.first?.id)

        let midDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        try sut.toggleOccurrenceComplete(todoId, on: midDay)

        let updated = try XCTUnwrap(sut.todos.first)
        XCTAssertTrue(updated.isCompleted)

        let completions = try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>())
        XCTAssertTrue(completions.isEmpty, "跨天事件(recurrenceRule == nil)走 toggleComplete 短路,不应产生 occurrence completion 记录")
    }
}

/// 测试辅助：从已有 todo 构造 TodoDetailUpdate，避免每个测试都写一长串字段。
private extension TodoDetailUpdate {
    init(from todo: TodoItemData, title: String? = nil) {
        self.init(
            title: title ?? todo.title,
            detail: todo.detail,
            category: todo.category,
            priority: todo.priority,
            dueDate: todo.dueDate,
            hasDueTime: todo.hasDueTime,
            timeBucket: todo.timeBucket,
            dueHint: todo.dueHint,
            recurrenceRule: todo.recurrenceRule
        )
    }
}
