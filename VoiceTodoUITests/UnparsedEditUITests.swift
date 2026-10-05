import XCTest

/// 「没能识别」卡片「编辑原文」sheet 的交互回归测试。
///
/// 语义契约(UI/Home/UnparsedTodoCard + UnparsedTranscriptEditSheet,2026-10 决策):
/// - 编辑按钮打开 sheet,编辑器预填当前原文;
/// - 取消不写库,卡片文本不变;
/// - trim 后空文本禁用保存;
/// - 保存 = 新文本**先落库**再自动重解析——即使解析必败(断网),
///   编辑后文本也已持久化,卡片立即显示新文本(永不丢话)。
///
/// 查询方式注意:UnparsedTodoCard 根上的 `UnparsedCard_` 容器 identifier 会
/// 污染整个子树的元素 identifier(UnparsedBody_/UnparsedEdit_ 均不可查),
/// 卡片内元素一律用 label 查询;编辑 sheet 内部无容器级 identifier,可用 identifier。
///
/// 预置数据不用 AppLaunchHelper.launchWithPresetTodos(与 App 端解码 schema 已漂移),
/// 手工构造 App 端可解码的 JSON(同 DetailKeyboardUITests 模式)。
/// 成功重解析路径依赖真实网络,由 AppCoordinatorTests 集成测试覆盖,不进 UI 测试。
final class UnparsedEditUITests: XCTestCase {
    private var appHelper: AppLaunchHelper!

    /// 预置原文(与 launchWithUnparsedTodo 的 payload 一致)。
    private let originalTranscript = "明天上午去买菜"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        appHelper = AppLaunchHelper()
    }

    override func tearDown() {
        appHelper = nil
        super.tearDown()
    }

    /// 编辑按钮打开 sheet,编辑器预填原文。
    func testEditButtonOpensSheetWithOriginalText() {
        launchWithUnparsedTodo()

        let app = appHelper.app
        tapEditButton()

        let editor = app.textViews["UnparsedEditEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "编辑 sheet 应弹出")
        XCTAssertEqual(editor.value as? String, originalTranscript, "编辑器应预填当前原文")
        XCTAssertTrue(app.buttons["UnparsedEditSave"].exists, "保存按钮应存在")
        XCTAssertTrue(app.buttons["UnparsedEditCancel"].exists, "取消按钮应存在")
    }

    /// 取消不写库:改了文本再取消,卡片原文不变。
    func testCancelKeepsOriginalText() {
        launchWithUnparsedTodo()

        let app = appHelper.app
        tapEditButton()

        let editor = app.textViews["UnparsedEditEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "编辑 sheet 应弹出")
        editor.tap()
        editor.clearText()
        editor.typeText("被改过的文本")

        app.buttons["UnparsedEditCancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "取消应关闭编辑 sheet")

        let body = app.staticTexts[originalTranscript]
        XCTAssertTrue(body.waitForExistence(timeout: 5), "卡片应仍存在")
        XCTAssertEqual(body.label, originalTranscript, "取消不得写库,卡片文本应保持原文")
    }

    /// 清空文本后保存禁用(空文本无法落库)。
    func testSaveDisabledWhenTextEmpty() {
        launchWithUnparsedTodo()

        let app = appHelper.app
        tapEditButton()

        let editor = app.textViews["UnparsedEditEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "编辑 sheet 应弹出")
        let saveButton = app.buttons["UnparsedEditSave"]
        XCTAssertTrue(saveButton.waitUntilEnabled(timeout: 3), "预填非空文本时保存应可用")

        editor.tap()
        editor.clearText()

        let disabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: saveButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [disabled], timeout: 3), .completed,
                       "清空文本后保存按钮应禁用")
    }

    /// 断网下保存:解析必败,但编辑后文本先落库——卡片立即显示新文本且仍保留。
    func testSavePersistsEditedTextWhenExtractionFailsOffline() {
        launchWithUnparsedTodo(networkOff: true)

        let app = appHelper.app
        tapEditButton()

        let editor = app.textViews["UnparsedEditEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "编辑 sheet 应弹出")
        editor.tap()
        editor.clearText()
        let newTranscript = "后天下午去邮局取包裹"
        editor.typeText(newTranscript)

        app.buttons["UnparsedEditSave"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "保存应关闭编辑 sheet")

        // 解析失败(断网),卡片保留并显示已落库的新文本
        let body = app.staticTexts[newTranscript]
        XCTAssertTrue(body.waitForExistence(timeout: 10), "解析失败后卡片应显示编辑后已落库的新文本(永不丢话)")
        // 旧原文文本应不再作为卡片正文出现(同屏可能还有别的元素含旧文本,按正文精确匹配)
        XCTAssertFalse(app.staticTexts[originalTranscript].exists, "卡片正文不应再显示旧原文")
    }

    // MARK: - Helpers

    /// 点卡片上的「编辑」按钮(容器 identifier 污染,只能按 label 查询)。
    private func tapEditButton() {
        let editButton = appHelper.app.buttons["编辑"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "「编辑」按钮应出现在「没能识别」卡片上")
        editButton.tap()
    }

    /// 启动 App 并预置 1 条「没能识别」条目(extractionOutcome=unparsed)。
    /// - Parameter networkOff: true 时注入 --network-off(解析必败路径)。
    private func launchWithUnparsedTodo(networkOff: Bool = false) {
        let now = Date().timeIntervalSinceReferenceDate
        let json = """
        [{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","title":"\(originalTranscript)","detail":"\(originalTranscript)","rawTranscript":"\(originalTranscript)","hasDueTime":false,"priority":"normal","category":"other","isCompleted":false,"createdAt":\(now),"needsAIProcessing":false,"sortOrder":0,"extractionOutcome":"unparsed","source":"voice"}]
        """

        var arguments = [
            "--skip-onboarding",
            "--reset-user-data",
            "--preset-todos",
            "--todos-data=\(json)"
        ]
        if networkOff {
            arguments.append("--network-off")
        }
        appHelper.app.launchArguments += arguments
        appHelper.app.launch()
        appHelper.waitForAppReady()

        // 预置条目应出现在「没能识别」分组(卡片正文按 label 查询)
        XCTAssertTrue(appHelper.app.staticTexts[originalTranscript].waitForExistence(timeout: 8),
                      "预置的「没能识别」卡片应出现")
    }
}
