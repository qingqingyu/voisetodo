import XCTest

/// 详情页键盘两段式收起(iOS 26 惯例)回归测试。
///
/// 语义契约(UI/Detail/TodoDetailView.swift 的 isKeyboardVisible 两段式):
/// - 键盘弹起时:chevron.down 按钮 / 下滑手势**只收键盘**,页面保持打开;
/// - 键盘收起后:二者恢复「关闭页面」语义。
///
/// 键盘存在性用 `app.keyboards` 断言,前提是模拟器显示软件键盘
/// (Simulator 的 I/O → Keyboard → Connect Hardware Keyboard 需为关闭状态)。
///
/// 注意:不使用 AppLaunchHelper.launchWithPresetTodos —— 它的 UITestTodoPayload
/// 与 App 端 [TodoItemData] 解码 schema 已漂移(app 启动即 fatalError),
/// 这里手工构造 App 端可解码的 JSON。
final class DetailKeyboardUITests: XCTestCase {
    private var appHelper: AppLaunchHelper!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        appHelper = AppLaunchHelper()
    }

    override func tearDown() {
        appHelper = nil
        super.tearDown()
    }

    /// chevron.down 两段式:键盘弹起 → 只收键盘;键盘收起 → 关闭页面。
    func testChevronDismissesKeyboardBeforeClosingPage() {
        launchAndOpenDetail()

        let app = appHelper.app
        focusTitleAndType()

        // 键盘弹起期间按钮 a11y label 应切换为「收起键盘」(两段式语义的可达性契约)
        XCTAssertTrue(app.buttons["收起键盘"].exists, "键盘弹起时 chevron.down 的 a11y label 应为「收起键盘」")

        // 第一段:点 chevron.down → 只收键盘,页面仍在
        app.buttons["TodoDetailCloseButton"].tap()
        XCTAssertFalse(waitForKeyboard(timeout: 3), "点 chevron.down 应收起键盘")
        XCTAssertTrue(app.buttons["TodoDetailCloseButton"].exists, "键盘收起后详情页不应被关闭")

        // 等 a11y label 翻回「关闭」—— 即 isKeyboardVisible 已翻转,消除键盘动画期竞态
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 3), "键盘收起后 a11y label 应回到「关闭」")

        // 第二段:键盘已收,再点 → 关闭页面回到主页
        app.buttons["TodoDetailCloseButton"].tap()
        XCTAssertTrue(waitForHome(timeout: 5), "键盘收起后再点 chevron.down 应关闭详情页回到主页")
    }

    /// 下滑手势两段式:键盘弹起 → 下滑只收键盘(不误关整个编辑页);键盘收起 → 下滑关闭。
    func testDragDownDismissesKeyboardBeforeClosingPage() {
        launchAndOpenDetail()

        let app = appHelper.app
        focusTitleAndType()

        // 第一段:下滑 → 只收键盘,页面仍在(修复前:整个详情页被关闭)
        dragDownSlowly()
        XCTAssertFalse(waitForKeyboard(timeout: 3), "下滑应收起键盘")
        XCTAssertTrue(app.buttons["TodoDetailCloseButton"].waitForExistence(timeout: 2),
                      "键盘弹起时的下滑不应关闭详情页")

        // 等键盘状态翻转完成再进行第二段,避免动画期竞态
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 3), "键盘收起后 a11y label 应回到「关闭」")

        // 第二段:键盘已收,再下滑 → 关闭页面
        dragDownSlowly()
        XCTAssertTrue(waitForHome(timeout: 5), "键盘收起后再下滑应关闭详情页回到主页")
    }

    // MARK: - Helpers

    /// 启动 App(预置 1 条今日待办)并打开其详情页。
    private func launchAndOpenDetail() {
        // Date 用 JSONEncoder 默认的 timeIntervalSinceReferenceDate 双精度;
        // 必填键对齐 App 端 TodoItemData 的 Codable 合成解码。
        let now = Date().timeIntervalSinceReferenceDate
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","title":"键盘测试任务","detail":"备注内容","dueDate":\(now),"hasDueTime":false,"priority":"normal","category":"other","isCompleted":false,"createdAt":\(now),"needsAIProcessing":false,"sortOrder":0,"extractionOutcome":"parsed","source":"voice"}]
        """

        appHelper.app.launchArguments += [
            "--skip-onboarding",
            "--reset-user-data",
            "--preset-todos",
            "--todos-data=\(json)"
        ]
        appHelper.app.launch()
        appHelper.waitForAppReady()

        // 点卡片标题打开详情(TodoCell_0 在月历/列表多处出现,标题文本唯一)
        let cardTitle = appHelper.app.staticTexts["键盘测试任务"].firstMatch
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 5), "预置待办卡片应出现")
        cardTitle.tap()

        XCTAssertTrue(
            appHelper.app.buttons["TodoDetailCloseButton"].waitForExistence(timeout: 5),
            "详情页应出现"
        )
    }

    /// 聚焦标题输入框、键入文字、确认软件键盘弹起。
    private func focusTitleAndType() {
        let titleField = appHelper.app.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "标题输入框应存在")
        titleField.tap()
        titleField.typeText("改")
        XCTAssertTrue(waitForKeyboard(timeout: 3), "聚焦标题后软件键盘应弹起")
    }

    /// 从屏幕中部缓慢下滑到 90% 高度(缓慢 + 足够位移,确保命中下滑关闭手势阈值 80pt)。
    private func dragDownSlowly() {
        let window = appHelper.app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// 等软件键盘出现(供断言「已弹起」用;返回是否存在)。
    @discardableResult
    private func waitForKeyboard(timeout: TimeInterval) -> Bool {
        let keyboard = appHelper.app.keyboards.firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: keyboard)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 等待回到主页:预置待办卡片标题重新可见。
    /// (标题会被测试键入的「改」前缀污染,故用 CONTAINS 匹配。)
    @discardableResult
    private func waitForHome(timeout: TimeInterval) -> Bool {
        let cardTitle = appHelper.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "键盘测试任务")
        ).firstMatch
        return cardTitle.waitForExistence(timeout: timeout)
    }
}
