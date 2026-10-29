import XCTest

/// 入口卡手动关闭(2026-10-27):右上角 × 收卡 + 7 天冷却持久。
///
/// 覆盖可自动断言的部分:× 存在、点击后卡滑出、关掉 sheet 重新进入后卡仍
/// 隐藏(新 ReviewView 实例从 store 读回关闭时刻——等价于重启后冷却生效的
/// 路径)。7 天窗口到期恢复走单元测试(ReviewEntryDismissStoreTests),模拟器
/// 无法推进时钟;滑出动画的真机观感走真机走查。
final class ReviewEntryCardDismissUITests: XCTestCase {
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

    /// 统计入口语径与 ReviewSheetDismissUITests 相同:label 形如 "2 / 4"。
    private func statsBadgeButton() -> XCUIElement {
        appHelper.app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$")
        ).firstMatch
    }

    private func entryCard() -> XCUIElement {
        appHelper.app.descendants(matching: .any)
            .matching(identifier: "ReviewFlowEntryCard").firstMatch
    }

    /// 今日有种子的完成 + 未完成 → 统计条可见;点开回顾 sheet,断言入口卡
    /// 右上角 × 存在,点击后卡滑出;关掉 sheet 重新进入,卡仍隐藏(冷却读回)。
    func testDismissButtonHidesEntryCardAndPersistsAcrossReentry() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let todos = [
            UITestTodoPayload(title: "未完成一", dueDate: today, createdAt: today, sortOrder: -2),
            UITestTodoPayload(title: "已完成一", dueDate: today, isCompleted: true,
                              createdAt: today, sortOrder: 0),
        ]
        appHelper.launchWithPresetTodos(todos)

        let todayTab = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["今日", "Today"])
        ).firstMatch
        XCTAssertTrue(todayTab.waitForExistence(timeout: 5.0), "今日 tab 应存在")
        todayTab.tap()

        let statsBadge = statsBadgeButton()
        XCTAssertTrue(statsBadge.waitForExistence(timeout: 5.0), "统计条应可见")
        statsBadge.tap()

        // sheet 就绪标志 + 本次改动核心断言:入口卡与其右上角 × 都存在。
        let card = entryCard()
        XCTAssertTrue(card.waitForExistence(timeout: 5.0), "回顾 sheet 应出现且入口卡可见")

        let dismiss = appHelper.app.buttons["ReviewEntryCardDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3.0), "入口卡右上角 × 应存在")
        dismiss.tap()

        // 等滑出动画完成:卡离 a11y 树才是硬信号(模式同 ReviewSheetDismissUITests)。
        let cardGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: card
        )
        XCTAssertEqual(XCTWaiter().wait(for: [cardGone], timeout: 5.0), .completed,
                       "点击 × 后入口卡应滑出 a11y 树")

        // 关掉 sheet 重新进入:新 ReviewView 实例从 store 读回关闭时刻,
        // 冷却持续——重开后卡不得复活。
        let sheetClose = appHelper.app.buttons["ReviewSheetClose"]
        XCTAssertTrue(sheetClose.waitForExistence(timeout: 3.0), "sheet 右上角关闭按钮应存在")
        sheetClose.tap()

        XCTAssertTrue(statsBadge.waitForExistence(timeout: 5.0), "sheet 收起后统计条应重新可见")
        statsBadge.tap()

        let cardAfterReentry = entryCard()
        XCTAssertTrue(appHelper.app.descendants(matching: .any)
            .matching(identifier: "ReviewSheetClose").firstMatch.waitForExistence(timeout: 5.0),
                      "回顾 sheet 应重新打开")
        XCTAssertFalse(cardAfterReentry.exists, "冷却期内重新进入回顾页,入口卡不得复活")
    }
}
