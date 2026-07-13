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

    func testSelectingMonthDayChangesVisibleTodoList() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let todos = [
            UITestTodoPayload(
                title: "今天日历任务",
                dueDate: today,
                createdAt: today,
                sortOrder: -2
            ),
            UITestTodoPayload(
                title: "明天日历任务",
                dueDate: tomorrow,
                createdAt: today,
                sortOrder: -1
            )
        ]

        appHelper.launchWithPresetTodos(todos)
        appHelper.waitForAppReady()

        XCTAssertTrue(appHelper.app.staticTexts["今天日历任务"].waitForExistence(timeout: 2))
        XCTAssertFalse(appHelper.app.staticTexts["明天日历任务"].exists)

        let calendarTab = appHelper.app.buttons["CalendarTabButton"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 2), "应该能找到日历 tab")
        calendarTab.tap()

        let tomorrowButtonIdentifier = "MonthDay_\(tomorrow.formatted(.dateTime.year().month().day()))"
        let tomorrowButton = appHelper.app.buttons[tomorrowButtonIdentifier]
        XCTAssertTrue(tomorrowButton.waitForExistence(timeout: 2), "应该能找到明天的月历日期按钮")
        tomorrowButton.tap()

        XCTAssertTrue(appHelper.app.staticTexts["明天日历任务"].waitForExistence(timeout: 2))
        XCTAssertFalse(appHelper.app.staticTexts["今天日历任务"].exists)

        let todayButtonIdentifier = "MonthDay_\(today.formatted(.dateTime.year().month().day()))"
        let todayButton = appHelper.app.buttons[todayButtonIdentifier]
        XCTAssertTrue(todayButton.waitForExistence(timeout: 2), "应该能找到今天的月历日期按钮")
        todayButton.tap()

        XCTAssertTrue(appHelper.app.staticTexts["今天日历任务"].waitForExistence(timeout: 2))
        XCTAssertTrue(appHelper.app.buttons[tomorrowButtonIdentifier].waitForExistence(timeout: 2), "日历内选择今天后仍应保留月历")
    }

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
