import XCTest
import SwiftData
@testable import VoiceTodo

/// 阶段 1 数据地基的 store 层测试:
/// - abandon → unabandon 字段往返 + abandoned 事件
/// - updateFull 的 deferred 埋点(origin 穿线)
/// - abandonedAt == nil 过滤(工作集 / widget / 首页分组),划掉仍留在分母的口径由
///   ReviewView @Query 直读保证(此处测原料查询 insightContext)
/// - insightContext 的推迟计数排除 origin == .review
@MainActor
final class TaskEventStoreTests: XCTestCase {
    var sut: TodoStore!
    var modelContainer: ModelContainer!
    var modelContext: ModelContext!
    let calendar = Calendar.current

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VoiceTodoSchema.schema, configurations: config)
        modelContext = modelContainer.mainContext
        sut = TodoStore(modelContext: modelContext, forceMigration: true)
    }

    override func tearDown() {
        sut = nil
        modelContext = nil
        modelContainer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func day(offset: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
            .addingTimeInterval(Double(hour) * 3600)
    }

    /// 建一条带 dueDate 的一次性任务,返回 id。
    /// dueDateBasis 必须传 .userExplicit:`TodoItem.from` 的 basisFilter 对无 transcript
    /// 的非 userExplicit dueDate 会清空(保守过滤),不标会被吞成 nil。
    private func seedOneOff(dueDate: Date?) throws -> UUID {
        let id = UUID()
        try sut.add(ExtractedTodo(id: id, title: "复盘任务", detail: "", dueDate: dueDate, categoryHint: .work, dueDateBasis: dueDate == nil ? nil : .userExplicit))
        return id
    }

    private func fetchTaskEvents(type: TaskEventType? = nil, todoId: UUID? = nil) throws -> [TaskEvent] {
        let all = try modelContext.fetch(FetchDescriptor<TaskEvent>())
        return all.filter { event in
            (type == nil || event.typeRaw == type!.rawValue)
                && (todoId == nil || event.todoId == todoId)
        }
    }

    private func updateDueDate(_ id: UUID, to dueDate: Date?, origin: TaskEventOrigin = .app) throws {
        let todo = try XCTUnwrap(sut.findTodo(by: id))
        try sut.updateFull(id, update: TodoDetailUpdate(
            title: todo.title,
            detail: todo.detail,
            category: nil,
            priority: nil,
            dueDate: dueDate,
            hasDueTime: false,
            timeBucket: nil,
            dueHint: nil,
            recurrenceRule: nil
        ), origin: origin)
    }

    // MARK: - abandon / unabandon

    func testAbandonUnabandonRoundTrip() throws {
        let id = try seedOneOff(dueDate: day(offset: 0))
        XCTAssertNil(try XCTUnwrap(sut.findTodo(by: id)).abandonedAt)

        try sut.abandon(id)
        XCTAssertNotNil(try XCTUnwrap(sut.findTodo(by: id)).abandonedAt, "划掉应写 abandonedAt")
        XCTAssertEqual(try fetchTaskEvents(type: .abandoned).count, 1, "abandon 应记一条事件")
        // isCompleted 保持 false——划掉与完成正交
        XCTAssertFalse(try XCTUnwrap(sut.findTodo(by: id)).isCompleted)

        try sut.unabandon(id)
        XCTAssertNil(try XCTUnwrap(sut.findTodo(by: id)).abandonedAt, "撤销应清 abandonedAt")
        XCTAssertEqual(try fetchTaskEvents(type: .abandoned).count, 1, "unabandon 不记事件(事件集无 un-abandoned 类型)")
    }

    func testAbandonNotFoundThrows() {
        XCTAssertThrowsError(try sut.abandon(UUID()))
        XCTAssertThrowsError(try sut.unabandon(UUID()))
    }

    // MARK: - deferred 埋点

    func testUpdateFullDeferForward_recordsDeferredEvent() throws {
        let id = try seedOneOff(dueDate: day(offset: 1))
        let newDue = day(offset: 3)
        try updateDueDate(id, to: newDue, origin: .detail)

        let events = try fetchTaskEvents(type: .deferred)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].todoId, id)
        XCTAssertEqual(events[0].originRaw, TaskEventOrigin.detail.rawValue)
        XCTAssertEqual(events[0].toDate, newDue)
    }

    func testUpdateFullSameDayOrBackward_noEvent() throws {
        let id = try seedOneOff(dueDate: day(offset: 1, hour: 10))
        try updateDueDate(id, to: day(offset: 1, hour: 22)) // 同日改钟点
        try updateDueDate(id, to: day(offset: 0))            // 往前改
        XCTAssertEqual(try fetchTaskEvents(type: .deferred).count, 0)
    }

    func testUpdateFullNilOldDueDate_noEvent() throws {
        let id = try seedOneOff(dueDate: nil) // 首次排期
        try updateDueDate(id, to: day(offset: 2))
        XCTAssertEqual(try fetchTaskEvents(type: .deferred).count, 0)
    }

    // MARK: - abandonedAt == nil 过滤(可见性)

    func testAbandonedTodoExcludedFromUncompletedVisibility() throws {
        let id = try seedOneOff(dueDate: nil)
        try sut.abandon(id)

        // 1. 工作集(refreshTodos 谓词)
        sut.refreshTodos()
        XCTAssertFalse(sut.todos.contains { $0.id == id }, "划掉的任务应出工作集(首页不可见)")

        // 2. Widget 可见性(WidgetTodoFilter,产物供 widget/最近未完成)
        let abandonedData = try XCTUnwrap(modelContext.fetch(FetchDescriptor<TodoItem>()).first { $0.id == id }?.toData())
        let visible = WidgetTodoFilter.visibleTodos(
            from: [abandonedData],
            completionKeys: [],
            today: Date(),
            limit: 10
        )
        XCTAssertTrue(visible.isEmpty, "划掉的任务 widget 不可见")

        // 3. 首页未完成分组(HomeCalendarState,喂原始数组验证防御过滤)
        let state = HomeCalendarState.makeForTests(
            todos: [abandonedData],
            selectedDate: Date()
        )
        XCTAssertTrue(state.unscheduledTodos.isEmpty)
        XCTAssertTrue(state.pendingDateTodos.isEmpty)
        XCTAssertTrue(state.unparsedTodos.isEmpty)

        // 4. 撤销后恢复可见
        try sut.unabandon(id)
        sut.refreshTodos()
        XCTAssertTrue(sut.todos.contains { $0.id == id })
    }

    // MARK: - insightContext

    func testInsightContextDeferCountsExcludeReviewOrigin() async throws {
        let idA = try seedOneOff(dueDate: day(offset: -10))
        let idB = try seedOneOff(dueDate: day(offset: -10))
        // idA:一次 app 推迟 + 两次 review 排期 → 有效计数 1
        try updateDueDate(idA, to: day(offset: -8), origin: .app)
        try updateDueDate(idA, to: day(offset: -6), origin: .review)
        try updateDueDate(idA, to: day(offset: -4), origin: .review)
        // idB:两次 app 推迟 → 有效计数 2
        try updateDueDate(idB, to: day(offset: -8), origin: .app)
        try updateDueDate(idB, to: day(offset: -5), origin: .app)

        let context = try await insightContext(from: day(offset: -30), to: day(offset: 1))
        XCTAssertEqual(context.deferCounts[idA], 1, "origin == .review 的排期不计入推迟")
        XCTAssertEqual(context.deferCounts[idB], 2)
    }

    func testInsightContextOpenTasksExcludeAbandonedAndRecurring() async throws {
        let openId = try seedOneOff(dueDate: nil)
        let abandonedId = try seedOneOff(dueDate: nil)
        try sut.abandon(abandonedId)
        let recurringId = UUID()
        try sut.add(ExtractedTodo(
            id: recurringId,
            title: "规律任务",
            detail: "",
            dueDate: day(offset: 0),
            recurrenceRule: RecurrenceRule(frequency: .daily),
            categoryHint: .life
        ))

        let context = try await insightContext(from: day(offset: -1), to: day(offset: 1))
        XCTAssertEqual(context.openTasks.map(\.todoId), [openId], "未完成任务应排除已划掉与规律任务")
    }

    // MARK: - 失败传播

    func testAbandonSaveFailure_eventRolledBackTogether() throws {
        final class FailingSave {
            var armed = false
            func save(_ context: ModelContext) throws {
                if armed { throw VoiceTodoError.storageWriteFailed("forced") }
                try context.save()
            }
        }
        let gate = FailingSave()
        let failingStore = TodoStore(
            modelContext: modelContext,
            saveAction: { try gate.save($0) },
            forceMigration: true
        )
        let id = try seedOneOffIn(failingStore)
        gate.armed = true
        XCTAssertThrowsError(try failingStore.abandon(id))
        gate.armed = false
        // 回滚后既无字段也无事件
        XCTAssertNil(try XCTUnwrap(failingStore.findTodo(by: id)).abandonedAt)
        XCTAssertEqual(try fetchTaskEvents().count, 0, "事件应与主操作同事务一起回滚")
    }

    private func seedOneOffIn(_ store: TodoStore) throws -> UUID {
        let id = UUID()
        try store.add(ExtractedTodo(id: id, title: "失败路径任务", detail: "", categoryHint: .other))
        return id
    }

    /// 走 queryActor 的 insightContext(sut 持有的 actor 与主上下文共享同一 container)。
    private func insightContext(from: Date, to: Date) async throws -> InsightContext {
        try await TodoQueryActor(modelContainer: modelContainer).insightContext(from: from, to: to)
    }
}
