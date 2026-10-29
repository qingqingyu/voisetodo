import XCTest

/// 回顾 sheet 收起可发现性(2026-10-24):拖动指示条 + 右上角关闭按钮。
///
/// 横条是系统 presentationDragIndicator 纯视觉件,a11y 树不可寻址,无法在
/// XCUITest 断言;下滑收起手势由系统 sheet 提供,swipeDown() 模拟的是滚动
/// 而非 sheet 拖拽,同样不可自动断言——两者走真机走查(计划验证清单)。
/// 本用例覆盖可自动断言的部分:× 存在 + 点击后 sheet 收起。
final class ReviewSheetDismissUITests: XCTestCase {
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

    /// 统计入口语径与 ScreenshotUITests.statsBadgeButton 相同:label 形如
    /// "2 / 4"(数字 / 数字),与语言无关(identifier 被子元素污染)。
    private func statsBadgeButton() -> XCUIElement {
        appHelper.app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$")
        ).firstMatch
    }

    /// 今日有种子的完成 + 未完成 → 统计条可见;点开回顾 sheet,断言右上角 ×
    /// (ReviewSheetClose)存在,点击后 sheet 收起、统计条重新可点。
    func testCloseButtonDismissesReviewSheet() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let todos = [
            UITestTodoPayload(title: "未完成一", dueDate: today, createdAt: today, sortOrder: -2),
            UITestTodoPayload(title: "未完成二", dueDate: today, createdAt: today, sortOrder: -1),
            UITestTodoPayload(title: "已完成一", dueDate: today, isCompleted: true,
                              createdAt: today, sortOrder: 0),
            UITestTodoPayload(title: "已完成二", dueDate: today, isCompleted: true,
                              createdAt: today, sortOrder: 1),
        ]
        appHelper.launchWithPresetTodos(todos)

        // 统计条在今日 tab 标题行下方;先切过去再等就绪(与截图套件同序)。
        let todayTab = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["今日", "Today"])
        ).firstMatch
        XCTAssertTrue(todayTab.waitForExistence(timeout: 5.0), "今日 tab 应存在")
        todayTab.tap()

        let statsBadge = statsBadgeButton()
        XCTAssertTrue(statsBadge.waitForExistence(timeout: 5.0),
                      "有种子的完成+未完成,统计条应可见")
        statsBadge.tap()

        // sheet 打开的就绪标志:入口卡。不用 ReviewPeriodPicker / ReviewHeroCount
        // ——preset 种子无 completedAt 字段(payload 结构如此,截图套件靠手工 JSON
        // 才带上),完成事件算不出数 → 回顾页走空态路径,picker/hero 均不渲染;
        // 入口卡在空态与数据态两条路径都置顶,是稳定信号。
        let entryCard = appHelper.app.descendants(matching: .any)
            .matching(identifier: "ReviewFlowEntryCard").firstMatch
        XCTAssertTrue(entryCard.waitForExistence(timeout: 5.0), "回顾 sheet 应出现")

        // 本次改动的核心断言:右上角关闭按钮存在,点击后 sheet 收起。
        let close = appHelper.app.buttons["ReviewSheetClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 3.0), "右上角关闭按钮应存在")
        close.tap()

        // 等收起动画完成再断言:sheet 遮盖下底层统计条通常仍在 a11y 树,
        // 直接 waitForExistence 不构成收起证明;close 是否离树才是硬信号
        // (模式同 AppLaunchHelper.deleteTodoInSheet 的 exists == false 等待)。
        let closeGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        XCTAssertEqual(XCTWaiter().wait(for: [closeGone], timeout: 5.0), .completed,
                       "点击 × 后 sheet 应收起(关闭按钮应离开 a11y 树)")

        XCTAssertTrue(statsBadge.waitForExistence(timeout: 5.0),
                      "sheet 收起后统计条应重新可见")
    }
}
