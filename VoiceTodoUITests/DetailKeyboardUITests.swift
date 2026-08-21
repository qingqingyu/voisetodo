import XCTest

/// 详情页键盘收起交互回归测试。
///
/// 语义契约(UI/Detail/TodoDetailView.swift):
/// - **点非功能空白区**(卡片留白/分区标题/背景)→ 只收键盘,页面保持打开(收键盘主通道);
/// - **下滑手势**两段式:键盘弹起 → 只收键盘;键盘已收 → 关闭页面;
/// - **chevron.down 按钮**恒为单一职责:无论键盘是否弹起,点击即关闭页面。
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

    /// 点非功能空白区收键盘:键盘收起,页面保持打开(收键盘主通道)。
    func testTapBlankAreaDismissesKeyboardWithoutClosingPage() {
        launchAndOpenDetail()

        let app = appHelper.app
        focusTitleAndType()

        // 点「备注」分区标题 —— 静态文本属非交互区域,不落在任何功能控件上
        let notesLabel = app.staticTexts["备注"].firstMatch
        XCTAssertTrue(notesLabel.waitForExistence(timeout: 3), "备注分区标题应可见")
        notesLabel.tap()

        XCTAssertFalse(waitForKeyboard(timeout: 3), "点空白区应收起键盘")
        XCTAssertTrue(app.buttons["TodoDetailCloseButton"].waitForExistence(timeout: 2),
                      "点空白区不应关闭详情页")
    }

    /// chevron.down 单一职责:键盘弹起时点击也直接关闭页面(不做两段式收键盘)。
    func testChevronClosesPageEvenWithKeyboardVisible() {
        launchAndOpenDetail()

        let app = appHelper.app
        focusTitleAndType()

        app.buttons["TodoDetailCloseButton"].tap()
        XCTAssertTrue(waitForHome(timeout: 5), "键盘弹起时点 chevron.down 也应直接关闭详情页回到主页")
    }

    /// 下滑手势两段式:键盘弹起 → 下滑只收键盘(不误关整个编辑页);键盘收起 → 下滑关闭。
    func testDragDownDismissesKeyboardBeforeClosingPage() {
        launchAndOpenDetail()

        let app = appHelper.app
        focusTitleAndType()

        // 第一段:下滑 → 只收键盘,页面仍在(若直接关页:键盘连同编辑页一起消失)
        dragDownSlowly()
        XCTAssertFalse(waitForKeyboard(timeout: 3), "下滑应收起键盘")
        XCTAssertTrue(app.buttons["TodoDetailCloseButton"].waitForExistence(timeout: 2),
                      "键盘弹起时的下滑不应关闭详情页")

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
