import XCTest

final class CalendarHomeUITests: XCTestCase {
    private var appHelper: AppLaunchHelper!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        appHelper = AppLaunchHelper()
    }

    override func tearDownWithError() throws {
        appHelper = nil
        try super.tearDownWithError()
    }

    // MARK: - 已删除:testSelectingMonthDayChangesVisibleTodoList
    //
    // 原测试断言"在 Calendar tab 点月历日期格 → 下方列表显示当天任务"。
    // 已废:Calendar tab + month 模式下网格占满 95% 高度,下方空间不足以显示任务列表
    // (isGridMonthWithoutList 屏蔽 list 区域)。新设计下 month 点日期格只是高亮选中,
    // 不打开当天任务列表(用户决策 D4:只选中不打开详情)。需要看当天任务切到 Today tab。
    //
    // 详见 plan: calendar-tab-simplification.md

    func testTodayListGroupsTodosByTimeBucket() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: today))
        let todos = [
            UITestTodoPayload(title: "随时任务", dueDate: today, createdAt: today, sortOrder: -4),
            UITestTodoPayload(title: "上午任务", dueDate: morning, hasDueTime: true, createdAt: today, sortOrder: -3),
            UITestTodoPayload(title: "下午任务", dueDate: afternoon, hasDueTime: true, createdAt: today, sortOrder: -2),
            UITestTodoPayload(title: "晚上健身", dueDate: today, timeBucket: "evening", createdAt: today, sortOrder: -1)
        ]

        appHelper.launchWithPresetTodos(todos)
        appHelper.waitForAppReady()

        for identifier in ["anytime", "morning", "afternoon", "evening"] {
            XCTAssertTrue(
                appHelper.app.staticTexts["TimeBucketHeader_\(identifier)"].waitForExistence(timeout: 2),
                "应该显示 \(identifier) 时段分组"
            )
        }
    }
}
