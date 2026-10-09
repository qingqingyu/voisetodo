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

    /// Today tab 列表用扁平时间标签替代旧的 TimeBucket 分组标题。
    /// 有钟点的任务行显示 "HH:mm"(分类色),无钟点的不显示时间标签。
    /// 本测试验证:9:00 / 15:00 任务的行内时间标签存在,无钟点任务无时间标签。
    func testTodayListShowsInlineTimeLabels() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: today))
        let todos = [
            UITestTodoPayload(title: "随时任务", dueDate: today, createdAt: today, sortOrder: -4),
            UITestTodoPayload(title: "上午任务", dueDate: morning, hasDueTime: true, createdAt: today, sortOrder: -3),
            UITestTodoPayload(title: "下午任务", dueDate: afternoon, hasDueTime: true, createdAt: today, sortOrder: -2),
        ]

        appHelper.launchWithPresetTodos(todos)
        appHelper.waitForAppReady()

        // 有钟点的任务应显示行内时间标签
        XCTAssertTrue(
            appHelper.app.staticTexts["09:00"].waitForExistence(timeout: 2),
            "上午任务应显示 09:00 时间标签"
        )
        XCTAssertTrue(
            appHelper.app.staticTexts["15:00"].waitForExistence(timeout: 2),
            "下午任务应显示 15:00 时间标签"
        )
    }

    /// 「稍后」抽屉回归(2026-07-23 54502fb 重构把 UnscheduledDrawer 从 Calendar tab
    /// 摘除后,月历展开态「稍后」待办零可见入口;本用例锁住恢复后的行为):
    /// 1. Calendar tab 展开态:dueDate=nil 且无时间信号的待办 → 抽屉常驻可见,可展开看卡片;
    /// 2. 上滑折叠月历:抽屉让位卸载,列表「稍后」分区接管。
    /// seed 里同时放一条有日期任务,保证月历与列表都有对照内容。
    func testUnscheduledDrawerVisibleInExpandedMonthAndYieldsToCollapsedList() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let todos = [
            UITestTodoPayload(title: "稍后任务甲", createdAt: today, sortOrder: -1),
            UITestTodoPayload(title: "今日已排任务", dueDate: today, createdAt: today, sortOrder: -2),
        ]
        appHelper.launchWithPresetTodos(todos)
        appHelper.waitForAppReady()

        // tab identifier 在本测试环境被 a11y 污染(ScreenshotUITests 同款坑),label 直查。
        let calendarTab = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["日历", "Calendar"])
        ).firstMatch
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 3), "Calendar tab 按钮应存在")
        calendarTab.tap()

        // drawer 的 identifier 被容器 'HomeRootView' 污染(诊断 dump 确认,同 tab button
        // 的坑),改用 a11y label 查询:折叠态 toggle label=「展开稍后」,展开态翻转为
        // 「收起稍后」(a11y.drawer.expand / collapse)。grabber 与 header 两个 button
        // 共用 label,firstMatch 任取其一皆可触发 toggleExpanded。
        // label 查询做双语兼容,与上方 tab 查询同口径(en: Expand Later / Collapse Later)。
        let expandToggle = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["展开稍后", "Expand Later"])
        ).firstMatch
        XCTAssertTrue(
            expandToggle.waitForExistence(timeout: 5),
            "月历展开态应显示「稍后」抽屉(回归修复)"
        )

        // 点开抽屉:稍后待办卡片可见。
        expandToggle.tap()
        XCTAssertTrue(
            appHelper.app.staticTexts["稍后任务甲"].waitForExistence(timeout: 2),
            "抽屉展开后应显示稍后待办卡片"
        )

        // 收起:toggle label 翻转为「收起稍后」(en: Collapse Later)。
        let collapseToggle = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["收起稍后", "Collapse Later"])
        ).firstMatch
        XCTAssertTrue(collapseToggle.waitForExistence(timeout: 2), "展开后 toggle 应翻转为「收起稍后」")
        collapseToggle.tap()

        // 上滑折叠月历:拖拽发生在网格上部(dy 0.35→0.2,位移 > collapseTravelDistance),
        // 避开抽屉占用的下半屏。折叠后抽屉卸载,列表「稍后」分区出现。
        let window = appHelper.app.windows.firstMatch
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        XCTAssertTrue(
            expandToggle.waitForNonExistence(timeout: 3),
            "折叠态列表接管后抽屉应卸载(「稍后」由列表分区承担,双处显示会重复)"
        )
        XCTAssertTrue(
            appHelper.app.staticTexts.matching(
                NSPredicate(format: "label IN %@", ["稍后", "Later"])
            ).firstMatch.waitForExistence(timeout: 3),
            "折叠列表应显示「稍后」分区 header"
        )
    }
}
