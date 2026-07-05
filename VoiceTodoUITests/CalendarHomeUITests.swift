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
}
