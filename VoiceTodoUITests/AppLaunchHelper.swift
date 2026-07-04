import XCTest

/// App 启动助手
/// 封装 XCUIApplication 启动，注入 --ui-testing 参数
class AppLaunchHelper {
    let app: XCUIApplication
    private let baseLaunchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans"]
    private let defaultUITestArguments = ["--ui-testing", "--enable-accessibility-identifiers"]

    init() {
        app = XCUIApplication()
        // 强制中文渲染：S12 等用例断言中文界面文案，而文案有英文翻译；
        // 不固定语言时英文模拟器会渲染英文导致断言失败。参数在实例上持续，覆盖所有 launch* 变体。
        app.launchArguments = baseLaunchArguments
    }

    /// 启动 App 并注入 UI 测试参数
    func launch() {
        configureLaunchArguments(["--reset-user-data"])
        app.launch()
    }

    /// 启动 App 并配置特定场景
    /// - Parameter scenario: 场景名称
    func launch(withScenario scenario: String) {
        configureLaunchArguments(["--scenario=\(scenario)", "--reset-user-data"])
        app.launch()
    }

    /// 启动 App 并跳过引导（已授权状态）
    func launchWithCompletedOnboarding(scenario: String? = nil) {
        var arguments = ["--skip-onboarding", "--reset-user-data"]
        if let scenario {
            arguments.append("--scenario=\(scenario)")
        }
        configureLaunchArguments(arguments)
        app.launch()
    }

    /// 启动 App 并模拟网络断开
    func launchWithNetworkOff(scenario: String? = nil) {
        var arguments = ["--network-off", "--reset-user-data"]
        if let scenario {
            arguments.append("--scenario=\(scenario)")
        }
        configureLaunchArguments(arguments)
        app.launch()
    }

    /// 启动 App 并模拟麦克风权限被拒绝
    func launchWithMicPermissionDenied() {
        configureLaunchArguments(["--mic-permission-denied", "--reset-user-data"])
        app.launch()
    }

    /// 启动 App 并模拟语音识别权限被拒绝
    func launchWithSpeechPermissionDenied() {
        configureLaunchArguments(["--speech-permission-denied", "--reset-user-data"])
        app.launch()
    }

    /// 启动 App 并预置待办数据
    /// - Parameter todos: 预置的待办数据
    func launchWithPresetTodos(_ todos: [UITestTodoPayload]) {
        var arguments = ["--preset-todos"]
        do {
            let data = try JSONEncoder().encode(todos)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                XCTFail("预置待办数据无法转换为 UTF-8 JSON")
                return
            }
            arguments.append("--todos-data=\(jsonString)")
        } catch {
            XCTFail("预置待办数据编码失败: \(error)")
            return
        }
        arguments.append("--skip-onboarding")
        arguments.append("--reset-user-data")
        configureLaunchArguments(arguments)
        app.launch()
    }

    /// 重新启动 App，保留已有数据（不注入 --reset-user-data / --skip-onboarding）
    /// 用于验证 hasCompletedOnboarding 等持久化状态在重启后保持。
    func relaunchPreservingData() {
        configureLaunchArguments([])
        app.launch()
    }

    /// 等待 App 完全启动
    func waitForAppReady(timeout: TimeInterval = 5.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.otherElements["HomeRootView"].exists
                || app.otherElements["RootTabView"].exists
                || app.otherElements["MonthHomeView"].exists
                || app.tables["TodoList"].exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("首页根视图应该在规定时间内出现")
    }

    /// 重置 App 状态（清空数据库）
    func resetAppState() {
        // 通过菜单或按钮触发重置（需要 App 实现）
        // 或者直接 terminate 并重新 launch
        app.terminate()
        launch()
    }

    private func configureLaunchArguments(_ arguments: [String]) {
        app.launchArguments = baseLaunchArguments + defaultUITestArguments + arguments
    }
}

// MARK: - UI Element Helpers

extension AppLaunchHelper {
    /// 录音按钮
    var recordButton: XCUIElement {
        app.buttons["RecordButton"]
    }

    /// 确认弹窗
    var confirmSheet: XCUIElement {
        app.otherElements["ConfirmSheet"]
    }

    /// 语音原文区域
    var transcriptArea: XCUIElement {
        app.staticTexts["TranscriptArea"]
    }

    /// 待办列表
    var todoList: XCUIElement {
        app.tables["TodoList"]
    }

    /// 确认添加按钮
    var confirmButton: XCUIElement {
        app.buttons["ConfirmAddButton"]
    }

    var extractedTodoList: XCUIElement {
        confirmSheet.otherElements["ExtractedTodoList"]
    }

    /// 取消按钮
    var cancelButton: XCUIElement {
        app.buttons["CancelButton"]
    }

    /// Toast 提示
    var toast: XCUIElement {
        app.otherElements["Toast"]
    }

    /// 空状态视图
    var emptyState: XCUIElement {
        app.otherElements["EmptyState"]
    }

    /// 引导视图
    var onboardingView: XCUIElement {
        app.otherElements["OnboardingView"]
    }

    /// 下一步按钮（引导中）
    var nextButton: XCUIElement {
        let identifierMatch = app.buttons["NextButton"]
        if identifierMatch.exists {
            return identifierMatch
        }

        let labels = ["下一步", "跳过", "知道了", "开始使用", "Next", "Skip", "Got it", "Get started"]
        return app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// 跳转设置按钮
    var openSettingsButton: XCUIElement {
        app.buttons["OpenSettingsButton"]
    }
}

// MARK: - Action Helpers

extension AppLaunchHelper {
    /// 点击录音按钮并等待录音状态
    func startRecording() {
        recordButton.tap()
        // 等待录音指示器出现
        let recordingIndicator = app.otherElements["RecordingIndicator"]
        XCTAssertTrue(recordingIndicator.waitForExistence(timeout: 2.0), "录音指示器应该出现")
    }

    /// 停止录音
    func stopRecording() {
        recordButton.tap()
        // 等待录音指示器消失
        let recordingIndicator = app.otherElements["RecordingIndicator"]
        XCTAssertTrue(recordingIndicator.waitForNonExistence(timeout: 2.0), "录音指示器应该消失")
    }

    /// 等待确认弹窗出现
    func waitForConfirmSheet(timeout: TimeInterval = 5.0) {
        XCTAssertTrue(confirmSheet.waitForExistence(timeout: timeout), "确认弹窗应该在规定时间内出现")
    }

    /// 等待 Toast 出现
    func waitForToast(timeout: TimeInterval = 3.0) {
        XCTAssertTrue(toast.waitForExistence(timeout: timeout), "Toast 应该在规定时间内出现")
    }

    /// 等待 Toast 消失
    func waitForToastDismiss(timeout: TimeInterval = 3.0) {
        XCTAssertTrue(toast.waitForNonExistence(timeout: timeout), "Toast 应该在规定时间内消失")
    }

    /// 点击确认添加按钮
    func tapConfirmButton() {
        XCTAssertTrue(confirmButton.isEnabled, "确认按钮应该可用")
        confirmButton.tap()
    }

    func extractedTodoCount() -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'DeleteTodo_'")).count
    }

    /// 点击取消按钮
    func tapCancelButton() {
        cancelButton.tap()
    }

    /// 删除确认弹窗中的指定待办
    /// - Parameter index: 待办索引
    func deleteTodoInSheet(at index: Int) {
        let deleteButton = app.buttons["DeleteTodo_\(index)"]
        XCTAssertTrue(deleteButton.exists, "删除按钮应该存在")
        deleteButton.tap()

        // 等待删除动画完成
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: deleteButton
        )
        XCTWaiter().wait(for: [expectation], timeout: 1.0)
    }

    /// 编辑确认弹窗中的指定待办
    /// - Parameters:
    ///   - index: 待办索引
    ///   - newTitle: 新标题
    func editTodoInSheet(at index: Int, newTitle: String) {
        let titleText = app.staticTexts["TodoTitleText_\(index)"]
        XCTAssertTrue(titleText.exists, "待办标题应该存在")
        titleText.tap()

        let todoField = app.textFields["TodoTitle_\(index)"]
        XCTAssertTrue(todoField.exists, "待办文本框应该存在")

        todoField.tap()
        todoField.clearText()
        todoField.typeText(newTitle)
    }

    /// 在主界面勾选指定待办
    /// - Parameter index: 待办索引
    func toggleTodoCompletion(at index: Int) {
        let checkbox = todoList.buttons["TodoCheckbox_\(index)"]
        XCTAssertTrue(checkbox.exists, "勾选框应该存在")
        checkbox.tap()
    }

    /// 在主界面左滑删除指定待办
    /// - Parameter index: 待办索引
    func swipeDeleteTodo(at index: Int) {
        let cell = todoList.cells["TodoCell_\(index)"]
        XCTAssertTrue(cell.exists, "待办单元格应该存在")
        cell.swipeLeft()

        let deleteButton = cell.buttons["Delete"]
        XCTAssertTrue(deleteButton.exists, "删除按钮应该出现")
        deleteButton.tap()
    }
}

// MARK: - XCUIElement Extension

extension XCUIElement {
    /// 清空文本字段内容
    func clearText() {
        guard let stringValue = value as? String else { return }

        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
        typeText(deleteString)
    }

    /// 等待元素不存在
    /// - Parameter timeout: 超时时间
    /// - Returns: 是否成功等待
    @discardableResult
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
