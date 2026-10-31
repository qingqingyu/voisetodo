import XCTest
import SwiftData
@testable import VoiceTodo

// MARK: - 新旧取数路径的数字对照护栏
//
// 任务书 docs/task-metrics-quota-and-review-query.md §2.4-1:「页面上显示的
// 所有数字一个都不能变」——用同一份构造数据分别跑旧的全量算法与新的按窗
// 查询 + 计算,断言 ReviewSummary **每一个字段**相等。
//
// - 旧算法(基准,不随生产代码演进):`legacyFixedSummary`(= 改前 ReviewView
//   调 monthSummary 的原样调用)、`legacyPeriodSummary`(改前 ReviewView
//   .periodSummary 计算属性的逐字复刻)、`legacyRecapSummary`(= 改前
//   ReviewStepRecap 调 weekSummary 的原样调用)。三者的输入是**全量**数组
//   (全部待办 / 全部已完成 / 全部完成记录),模拟旧 @Query 的产物。
// - 新算法(生产主路):`TodoStore.reviewWindowInputs`(按窗谓词查询)+
//   `RecapSummaryBuilder.summary`(按窗聚合入口)+ `dueTodoCount` +
//   `pendingOneOffCount(store.todos)`(工作集内存过滤)。
//
// 覆盖清单(任务书 §2.4-1):
// - 跨周、跨月边界的完成记录;
// - 重复任务的完成记录(分类来自父任务)、父任务已被删除的完成记录(fallback「其他」)、
//   父任务已转成一次性的完成记录(分类仍查得到);
// - 已划掉(abandonedAt)的待办(含带未来到期日的划掉条目——旧口径照计到期数);
// - 连续天数:今天未完成、昨天断开、连续 70 天以上(跨「批次」——旧算法本就
//   按窗口封顶,新算法只查窗口,两侧一致;见 testParityStreakScenarios);
// - 7 天内到期:边界上的第 0 天和第 7 天;
// - 入口卡 N /「还挂着」:全量表 vs store.todos 工作集等价。

@MainActor
final class ReviewWindowQueryParityTests: XCTestCase {
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!
    private var sut: TodoStore!
    /// 固定「今天」:所有种子偏移与窗口推导共用同一时刻,测试可复现。
    private let today = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar.current
    /// DayClock 原始 startHour(setUp 存、tearDown 还,别污染其他测试)。
    private var savedStartHour = 0

    override func setUp() async throws {
        try await super.setUp()
        savedStartHour = DayClock.startHour
        // 用户日起点钉在 0:00,消除跨测试污染。today 固定在 1 月 15 日:
        // 「−1 月」恒为 12 月同日(31 天窗),且任何时区偏移 ±1 天都不改变
        // 月窗宽度 ≥ 31 天(3 月这类会缩到 28 天的月份特意避开)。
        DayClock.setStartHour(0)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VoiceTodoSchema.schema, configurations: config)
        modelContext = modelContainer.mainContext
        sut = TodoStore(modelContext: modelContext, forceMigration: true)
    }

    override func tearDown() {
        DayClock.setStartHour(savedStartHour)
        sut = nil
        modelContext = nil
        modelContainer = nil
        super.tearDown()
    }

    // MARK: - 种子构造

    /// today 所属用户日的起点。
    private var todayStart: Date { DayClock.startOfUserDay(for: today, calendar: calendar) }

    /// N 天前的正午(daysAgo 可为负 = 未来;远离日界,窗口判定只看天数)。
    private func noon(_ daysAgo: Double) -> Date {
        let day = calendar.date(byAdding: .day, value: -Int(daysAgo), to: todayStart) ?? todayStart
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    @discardableResult
    private func insertTodo(
        title: String,
        category: TodoCategory = .work,
        createdDaysAgo: Double,
        completedDaysAgo: Double? = nil,
        dueDaysAgo: Double? = nil,
        abandonedDaysAgo: Double? = nil,
        recurrence: RecurrenceRule? = nil
    ) -> UUID {
        let item = TodoItem(
            title: title,
            dueDate: dueDaysAgo.map { noon($0) },
            recurrenceRule: recurrence,
            category: category,
            isCompleted: completedDaysAgo != nil,
            completedAt: completedDaysAgo.map { noon($0) },
            createdAt: noon(createdDaysAgo),
            abandonedAt: abandonedDaysAgo.map { noon($0) }
        )
        modelContext.insert(item)
        return item.id
    }

    /// 规律任务某天的完成记录(直接落库,不经 toggle 链路)。
    private func insertCompletion(todoId: UUID, daysAgo: Double) {
        modelContext.insert(TodoOccurrenceCompletion(
            todoId: todoId,
            occurrenceDate: noon(daysAgo),
            completedAt: noon(daysAgo),
            calendar: calendar
        ))
    }

    /// 旧 @Query 的全量产物(旧算法的输入形状)。
    private struct LegacyInputs {
        let allTodos: [TodoItemData]
        let completedTodos: [TodoItemData]
        let recurringCompletions: [(id: UUID, todoId: UUID, completedAt: Date)]
    }

    private func legacyInputs() throws -> LegacyInputs {
        let allTodos = try modelContext.fetch(FetchDescriptor<TodoItem>()).map { $0.toData() }
        let completedTodos = allTodos
            .filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let recurring = try modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>(
            sortBy: [SortDescriptor(\TodoOccurrenceCompletion.completedAt, order: .reverse)]
        )).map { (id: $0.id, todoId: $0.todoId, completedAt: $0.completedAt) }
        return LegacyInputs(allTodos: allTodos, completedTodos: completedTodos, recurringCompletions: recurring)
    }

    // MARK: - 周期标签 / 窗口推导(改前 ReviewPeriod 的复刻,新旧两侧共用)

    private func periodTestLabel(weekPeriod: Bool) -> String {
        if weekPeriod {
            let weekOfYear = calendar.component(.weekOfYear, from: today)
            let year = calendar.component(.yearForWeekOfYear, from: today)
            return "第\(year)年第\(weekOfYear)周(测试标签)"
        }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        return monthStart.formatted(.dateTime.year().month(.abbreviated))
    }

    private func periodTestWindow(weekPeriod: Bool) -> (start: Date, end: Date) {
        let start = weekPeriod
            ? calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
            : calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        return (start, end)
    }

    // MARK: - 旧算法基准(改前代码的逐字保留)

    /// 改前 ReviewView.fixedWindowSummary:全量输入 + monthSummary。
    private func legacyFixedSummary(_ inputs: LegacyInputs) -> ReviewSummary {
        RecapSummaryBuilder.monthSummary(
            today: today,
            calendar: calendar,
            periodLabel: fixedTestLabel,
            allTodos: inputs.allTodos,
            completedTodos: inputs.completedTodos,
            recurringCompletions: inputs.recurringCompletions
        )
    }

    private let fixedTestLabel = "近30天(测试标签)"

    /// 改前 ReviewView.periodSummary 的逐字复刻(窗口 + ReviewAggregator 直调 +
    /// 全量内存过滤的到期数)。
    private func legacyPeriodSummary(_ inputs: LegacyInputs, weekPeriod: Bool) -> ReviewSummary {
        let window = periodTestWindow(weekPeriod: weekPeriod)
        let label = periodTestLabel(weekPeriod: weekPeriod)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart

        let upcomingDueIn7DaysCount = inputs.allTodos.filter { item in
            guard let due = item.dueDate else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay > todayStart && dueDay <= weekEnd
        }.count

        var events = inputs.completedTodos.compactMap { item -> CompletionEvent? in
            guard let completedAt = item.completedAt else { return nil }
            return CompletionEvent(id: item.id, completedAt: completedAt, category: item.category)
        }
        let categoryById = Dictionary(inputs.allTodos.map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        for completion in inputs.recurringCompletions {
            events.append(CompletionEvent(
                id: completion.id,
                completedAt: completion.completedAt,
                category: categoryById[completion.todoId] ?? .other
            ))
        }

        let result = ReviewAggregator.summarize(
            events: events,
            from: window.start,
            to: window.end,
            calendar: calendar,
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount
        )
        let sameDayCount = ReviewAggregator.sameDayCompletions(
            inputs.completedTodos, from: window.start, to: window.end, calendar: calendar
        )
        let createdCount = ReviewAggregator.createdInWindow(
            inputs.allTodos, from: window.start, to: window.end, calendar: calendar
        )
        let pendingOneOffCount = ReviewAggregator.pendingOneOffCount(inputs.allTodos)
        let oneOffCompletionCount = ReviewAggregator.oneOffCompletions(
            inputs.completedTodos, from: window.start, to: window.end, calendar: calendar
        )
        return ReviewSummary(
            periodLabel: label,
            total: result.total,
            byCategory: result.byCategory,
            byDay: result.byDay,
            streakDays: result.streakDays,
            busiestDay: result.busiestDay,
            busiestDayCount: result.busiestDayCount,
            upcomingDueIn7DaysCount: result.upcomingDueIn7DaysCount,
            daysWithCompletion: result.daysWithCompletion,
            sameDayCount: sameDayCount,
            createdCount: createdCount,
            pendingOneOffCount: pendingOneOffCount,
            oneOffCompletionCount: oneOffCompletionCount
        )
    }

    /// 改前 ReviewStepRecap.summary:全量输入 + weekSummary(since: 上次复盘时刻)。
    private func legacyRecapSummary(_ inputs: LegacyInputs, since: Date?) -> ReviewSummary {
        RecapSummaryBuilder.weekSummary(
            since: since,
            today: today,
            calendar: calendar,
            allTodos: inputs.allTodos,
            completedTodos: inputs.completedTodos,
            recurringCompletions: inputs.recurringCompletions
        )
    }

    // MARK: - 新算法(生产主路的同构复刻)

    private func buildNewSummary(label: String, start: Date, end: Date) async throws -> ReviewSummary {
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let dueUpper = calendar.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd
        async let inputs = sut.reviewWindowInputs(from: start, to: end)
        async let dueCount = sut.dueTodoCount(dueOnOrAfter: tomorrowStart, dueBefore: dueUpper)
        let pendingCount = ReviewAggregator.pendingOneOffCount(sut.todos)
        let (windowInputs, upcoming) = try await (inputs, dueCount)
        return RecapSummaryBuilder.summary(
            calendar: calendar,
            periodLabel: label,
            start: start,
            end: end,
            inputs: windowInputs,
            pendingOneOffCount: pendingCount,
            upcomingDueIn7DaysCount: upcoming
        )
    }

    // MARK: - 断言

    /// ReviewSummary 逐字段相等(分开断言,失败信息能定位到具体数字)。
    private func assertSummariesEqual(
        _ legacy: ReviewSummary,
        _ new: ReviewSummary,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(legacy.periodLabel, new.periodLabel, "\(message) · periodLabel", file: file, line: line)
        XCTAssertEqual(legacy.total, new.total, "\(message) · total(完成总数)", file: file, line: line)
        XCTAssertEqual(legacy.byCategory, new.byCategory, "\(message) · byCategory(分类分布)", file: file, line: line)
        XCTAssertEqual(legacy.byDay, new.byDay, "\(message) · byDay(每日趋势)", file: file, line: line)
        XCTAssertEqual(legacy.streakDays, new.streakDays, "\(message) · streakDays(连续天数)", file: file, line: line)
        XCTAssertEqual(legacy.busiestDay, new.busiestDay, "\(message) · busiestDay(最忙一天)", file: file, line: line)
        XCTAssertEqual(legacy.busiestDayCount, new.busiestDayCount, "\(message) · busiestDayCount", file: file, line: line)
        XCTAssertEqual(legacy.upcomingDueIn7DaysCount, new.upcomingDueIn7DaysCount, "\(message) · upcomingDueIn7DaysCount(7 天内到期)", file: file, line: line)
        XCTAssertEqual(legacy.daysWithCompletion, new.daysWithCompletion, "\(message) · daysWithCompletion", file: file, line: line)
        XCTAssertEqual(legacy.sameDayCount, new.sameDayCount, "\(message) · sameDayCount(当天记当天做完)", file: file, line: line)
        XCTAssertEqual(legacy.createdCount, new.createdCount, "\(message) · createdCount(新增)", file: file, line: line)
        XCTAssertEqual(legacy.pendingOneOffCount, new.pendingOneOffCount, "\(message) · pendingOneOffCount(还挂着)", file: file, line: line)
        XCTAssertEqual(legacy.oneOffCompletionCount, new.oneOffCompletionCount, "\(message) · oneOffCompletionCount", file: file, line: line)
        XCTAssertEqual(legacy, new, "\(message) · 整体相等", file: file, line: line)
    }

    /// 三份摘要(30 天 + 周/月 + 复盘窗)新旧全对照 + 入口卡 N / 还挂着等价。
    private func assertFullParity(
        recapSince: Date?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        // 测试直接往 context 插的种子不经 store 写路径——先同步工作集,
        // `store.todos`(新算法的「还挂着」/入口卡 N 数据源)才是满的。
        sut.refreshTodos()

        let inputs = try legacyInputs()

        // 近 30 天(Hero/Stats)
        let fixedWindow = periodTestWindow(weekPeriod: false)
        assertSummariesEqual(
            legacyFixedSummary(inputs),
            try await buildNewSummary(
                label: fixedTestLabel, start: fixedWindow.start, end: fixedWindow.end
            ),
            "固定 30 天窗", file: file, line: line
        )
        // 周 / 月 picker 窗
        for weekPeriod in [true, false] {
            let window = periodTestWindow(weekPeriod: weekPeriod)
            assertSummariesEqual(
                legacyPeriodSummary(inputs, weekPeriod: weekPeriod),
                try await buildNewSummary(
                    label: periodTestLabel(weekPeriod: weekPeriod),
                    start: window.start,
                    end: window.end
                ),
                weekPeriod ? "周窗" : "月窗", file: file, line: line
            )
        }
        // 复盘第 1 步窗(上次复盘时刻起点 / 首次回落近 7 天)
        let recapWindow = RecapSummaryBuilder.weekWindow(since: recapSince, today: today, calendar: calendar)
        assertSummariesEqual(
            legacyRecapSummary(inputs, since: recapSince),
            try await buildNewSummary(
                label: RecapSummaryBuilder.weekWindowLabel(
                    windowStart: recapWindow.start, today: today, calendar: calendar
                ),
                start: recapWindow.start,
                end: recapWindow.end
            ),
            "复盘窗(since=\(String(describing: recapSince)))", file: file, line: line
        )

        // 入口卡 N:全量表 vs store.todos 工作集,同一过滤函数。
        let legacyN = ReviewFlowState.triageInput(from: inputs.allTodos, now: today, calendar: calendar).count
        let workingSetN = ReviewFlowState.triageInput(from: sut.todos, now: today, calendar: calendar).count
        XCTAssertEqual(legacyN, workingSetN, "入口卡 N(等你决定)全量表与工作集等价", file: file, line: line)
    }

    // MARK: - 测试

    /// 综合场景:跨周跨月边界 + 重复任务(父在/父删/父转一次性)+ 划掉 +
    /// 完成态带未来到期 + 各种开放态;复盘窗取「上次复盘在 10 天前正午」。
    func testParityMixedDataset() async throws {
        seedMixedDataset()
        try modelContext.save()

        try await assertFullParity(recapSince: noon(10))
    }

    /// 首次复盘(since == nil,窗口回落近 7 天)的综合对照。
    func testParityFirstReviewFallbackWindow() async throws {
        seedMixedDataset()
        try modelContext.save()

        try await assertFullParity(recapSince: nil)
    }

    private func seedMixedDataset() {
        // 一次性完成:跨周(7/8 天前)、跨月(31/32 天前)、远历史(400 天前);
        // createdAt 有当天(同日完成)、窗口内、窗口外三种。
        insertTodo(title: "今天完成·当天记", category: .work, createdDaysAgo: 0, completedDaysAgo: 0)
        insertTodo(title: "今天完成·三天前记", category: .study, createdDaysAgo: 3, completedDaysAgo: 0)
        insertTodo(title: "昨天完成", category: .life, createdDaysAgo: 9, completedDaysAgo: 1)
        insertTodo(title: "3 天前完成·同日", category: .health, createdDaysAgo: 3, completedDaysAgo: 3)
        insertTodo(title: "7 天前完成(周界外)", category: .other, createdDaysAgo: 20, completedDaysAgo: 7)
        insertTodo(title: "8 天前完成(周界外)", category: .work, createdDaysAgo: 30, completedDaysAgo: 8)
        insertTodo(title: "20 天前完成", category: .work, createdDaysAgo: 25, completedDaysAgo: 20)
        insertTodo(title: "31 天前完成(月界)", category: .study, createdDaysAgo: 40, completedDaysAgo: 31)
        insertTodo(title: "32 天前完成(月界外)", category: .life, createdDaysAgo: 60, completedDaysAgo: 32)
        insertTodo(title: "45 天前完成", category: .health, createdDaysAgo: 50, completedDaysAgo: 45)
        insertTodo(title: "400 天前完成(远历史)", category: .other, createdDaysAgo: 400, completedDaysAgo: 400)

        // 完成态但到期日在未来:旧口径照计「未来 7 天到期」(不过滤状态)。
        insertTodo(title: "已完成但排在 3 天后", category: .work, createdDaysAgo: 5, completedDaysAgo: 1, dueDaysAgo: -3)

        // 开放一次性:各种到期形态(第 0 天不计、第 1/7 天计、第 8 天不计、无日期)。
        insertTodo(title: "今天到期(不计)", category: .work, createdDaysAgo: 2, dueDaysAgo: 0)
        insertTodo(title: "明天到期(计)", category: .work, createdDaysAgo: 2, dueDaysAgo: -1)
        insertTodo(title: "第 7 天到期(计,边界)", category: .study, createdDaysAgo: 2, dueDaysAgo: -7)
        insertTodo(title: "第 8 天到期(不计)", category: .study, createdDaysAgo: 2, dueDaysAgo: -8)
        insertTodo(title: "无日期开放", category: .life, createdDaysAgo: 15)
        insertTodo(title: "过期未做", category: .health, createdDaysAgo: 12, dueDaysAgo: 4)

        // 划掉:不进「还挂着」/入口卡 N,但带未来到期的仍计「7 天内到期」。
        insertTodo(title: "已划掉", category: .work, createdDaysAgo: 6, abandonedDaysAgo: 1)
        insertTodo(title: "已划掉·排在 2 天后", category: .work, createdDaysAgo: 6, dueDaysAgo: -2, abandonedDaysAgo: 1)

        // 规律任务:父任务在(分类 .study)。
        let recurringParent = insertTodo(
            title: "每周健身", category: .study, createdDaysAgo: 90,
            recurrence: RecurrenceRule(frequency: .weekly)
        )
        insertCompletion(todoId: recurringParent, daysAgo: 1)
        insertCompletion(todoId: recurringParent, daysAgo: 15)

        // 规律完成记录的父任务已删:分类 fallback「其他」。
        insertCompletion(todoId: UUID(), daysAgo: 2)

        // 父任务已转成一次性(且已完成):分类仍按现存行查得到(work)。
        let convertedParent = insertTodo(
            title: "曾是规律的已完成任务", category: .work, createdDaysAgo: 30, completedDaysAgo: 5
        )
        insertCompletion(todoId: convertedParent, daysAgo: 5)

        // 开放规律任务:不进「还挂着」(一次性口径)。
        insertTodo(title: "每日喝水", category: .life, createdDaysAgo: 60, recurrence: RecurrenceRule(frequency: .daily))
    }

    /// 连续天数三场景 + 连续 70 天以上(任务书 §2.4-1 streak 清单)。
    ///
    /// busiestDay 口径注:多天并列最大时,`summarize` 按 byDay 字典遍历序取
    /// 第一个最大值——**旧算法本身就是非确定的**(同数据同进程内才稳定),
    /// 新算法同一逻辑。为让对照可断言,种子在固定的一天(2 天前)多放一条,
    /// 保证最忙一天唯一;计数类数字(streak/total/byDay…)与并列无关。
    func testParityStreakScenarios() async throws {
        // 场景 A:今天已完成 + 往前连续 5 天。
        try seedConsecutiveDays(count: 5, includeToday: true)
        try modelContext.save()
        try await assertFullParity(recapSince: noon(3))

        try resetStore()

        // 场景 B:今天未完成,昨天起往前连续 5 天(今天没完成不算断)。
        try seedConsecutiveDays(count: 5, includeToday: false)
        try modelContext.save()
        try await assertFullParity(recapSince: noon(3))

        try resetStore()

        // 场景 C:昨天断开(今天 + 2/3 天前有完成,streak 归 1)。
        insertTodo(title: "今天", category: .work, createdDaysAgo: 1, completedDaysAgo: 0)
        insertTodo(title: "前天 a", category: .work, createdDaysAgo: 3, completedDaysAgo: 2)
        insertTodo(title: "前天 b", category: .life, createdDaysAgo: 3, completedDaysAgo: 2)
        insertTodo(title: "大前天", category: .work, createdDaysAgo: 4, completedDaysAgo: 3)
        try modelContext.save()
        try await assertFullParity(recapSince: nil)

        try resetStore()

        // 场景 D:连续 70 天以上(今天 + 1…70 天前)。旧算法的 streak 按**窗口**
        // 封顶(summarize 的游标停在窗口起点),新算法只查窗口,两侧一致——
        // 这就是「往前数」的对照:任何一侧多读/少读窗口外的天,数字立刻不相等。
        try seedConsecutiveDays(count: 70, includeToday: true)
        try modelContext.save()
        try await assertFullParity(recapSince: noon(10))
    }

    /// 连续 count 天的完成记录(includeToday=false 时从昨天起);2 天前那天
    /// 多放一条,让 busiestDay 唯一(见上「busiestDay 口径注」)。
    private func seedConsecutiveDays(count: Int, includeToday: Bool) throws {
        let firstOffset: Double = includeToday ? 0 : 1
        for day in stride(from: firstOffset, through: firstOffset + Double(count - 1), by: 1) {
            insertTodo(
                title: "连续第\(Int(day))天前",
                category: .work,
                createdDaysAgo: day + 30,
                completedDaysAgo: day
            )
        }
        insertTodo(title: "连续第2天前·第二件", category: .life, createdDaysAgo: 32, completedDaysAgo: 2)
    }

    /// 7 天内到期的边界(第 0 天与第 7 天)——只喂到期数据,数量可直接口算。
    func testUpcomingDueBoundaries() async throws {
        insertTodo(title: "今天到期(不计,第 0 天)", category: .work, createdDaysAgo: 2, dueDaysAgo: 0)
        insertTodo(title: "第 7 天到期(计,闭端)", category: .work, createdDaysAgo: 2, dueDaysAgo: -7)
        insertTodo(title: "第 8 天到期(不计)", category: .work, createdDaysAgo: 2, dueDaysAgo: -8)
        try modelContext.save()

        // 新算法:按用户日边界换算的范围计数。
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart
        let newCount = try await sut.dueTodoCount(
            dueOnOrAfter: calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart,
            dueBefore: calendar.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd
        )
        XCTAssertEqual(newCount, 1, "只有第 7 天那条计入(今天不计、第 8 天不计)")

        // 旧算法:全量内存过滤,同数据。
        let inputs = try legacyInputs()
        let legacyCount = inputs.allTodos.filter { item in
            guard let due = item.dueDate else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay > todayStart && dueDay <= weekEnd
        }.count
        XCTAssertEqual(legacyCount, 1, "旧口径同样只计第 7 天那条")
    }

    /// 数据量:2 万条历史(2 年内)+ 本月 50 条——按窗查询的返回行数只和
    /// 本月数据有关;打印查询/聚合耗时(不设硬阈值,记录进结果文档)。
    func testWindowQueryRowCountWithLargeHistory() async throws {
        let seedStarted = Date()
        // 2 万条历史:分布在过去两年(32…731 天前,窗口起点是 31 天前的用户日,
        // 闭端含 31 天前——历史从 32 天前起,一条都不落进窗口)。
        for i in 0..<20_000 {
            let daysAgo = Double(32 + (i % 700))
            insertTodo(
                title: "历史 #\(i)",
                category: .work,
                createdDaysAgo: daysAgo,
                completedDaysAgo: daysAgo
            )
            if i % 2_000 == 1_999 {
                try modelContext.save() // 分批落库,免得单事务过大
            }
        }
        // 本月 50 条(0…29 天前,当天记当天做完)。
        for i in 0..<50 {
            let daysAgo = Double(i % 30)
            insertTodo(
                title: "本月 #\(i)",
                category: .life,
                createdDaysAgo: daysAgo,
                completedDaysAgo: daysAgo
            )
        }
        try modelContext.save()
        let seedDuration = Date().timeIntervalSince(seedStarted)

        let window = periodTestWindow(weekPeriod: false) // 与生产 fixed 窗同式(−1 月)

        let fetchStarted = Date()
        let inputs = try await sut.reviewWindowInputs(from: window.start, to: window.end)
        let fetchDuration = Date().timeIntervalSince(fetchStarted)

        let aggregateStarted = Date()
        let summary = RecapSummaryBuilder.summary(
            calendar: calendar,
            periodLabel: "月(测试)",
            start: window.start,
            end: window.end,
            inputs: inputs,
            pendingOneOffCount: 0,
            upcomingDueIn7DaysCount: 0
        )
        let aggregateDuration = Date().timeIntervalSince(aggregateStarted)

        // 期望值从种子数据按窗口推得(today 固定在 1 月 15 日,−1 月 = 12 月 15 日
        // 恒 31 天窗,必含 0…29 天前的全部本月条目;历史条目全部 ≥32 天前,一条不进)。
        XCTAssertEqual(inputs.completedTodos.count, 50, "窗口内完成行数 = 本月 50 条,历史 2 万条一条不进")
        XCTAssertEqual(inputs.recurringCompletions.count, 0, "无规律完成记录")
        XCTAssertEqual(inputs.createdCount, 50, "窗口内新增 = 本月 50 条(历史 2 万条的 createdAt 全在窗口外)")
        XCTAssertEqual(summary.total, 50, "聚合完成总数 = 50,与历史总量无关")
        XCTAssertEqual(summary.byDay.count, 30, "30 个用户日各一条")
        XCTAssertEqual(summary.sameDayCount, 50, "全部当天记当天做完")

        print("[ReviewWindowQueryParityTests] seed 20050 rows: \(String(format: "%.2f", seedDuration))s; "
            + "windowed fetch: \(String(format: "%.0f", fetchDuration * 1000))ms; "
            + "aggregate: \(String(format: "%.0f", aggregateDuration * 1000))ms")
    }

    /// 重建 in-memory 库(streak 场景在同一测试方法内串行复用多套数据)。
    private func resetStore() throws {
        sut = nil
        modelContext = nil
        modelContainer = nil
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VoiceTodoSchema.schema, configurations: config)
        modelContext = modelContainer.mainContext
        sut = TodoStore(modelContext: modelContext, forceMigration: true)
    }
}
