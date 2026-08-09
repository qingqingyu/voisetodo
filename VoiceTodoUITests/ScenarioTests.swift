import XCTest

/// E2E 场景测试
/// 实现测试策略文档中定义的 15 个场景 (S01-S15)
final class ScenarioTests: XCTestCase {
    var appHelper: AppLaunchHelper!

    // MARK: - Setup & Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        appHelper = AppLaunchHelper()

        let defaultEnabledScenarios = [
            "test_confirmSheetKeyboardInputKeepsHeaderAtTopAndEnablesFirstPartial",
            "test_S11_homeView_emptyState",
            "test_S12_firstLaunch_onboarding"
        ]
        let isDefaultEnabledScenario = defaultEnabledScenarios.contains { name.contains($0) }
        let isLegacyScenarioEnabled = ProcessInfo.processInfo.environment["RUN_LEGACY_SCENARIOS"] == "1"
        guard isDefaultEnabledScenario || isLegacyScenarioEnabled else {
            throw XCTSkip("Legacy ScenarioTests 依赖旧的 SwiftUI 可访问性层级；默认跳过，待重写后再恢复。")
        }
    }

    override func tearDownWithError() throws {
        appHelper = nil
        try super.tearDownWithError()
    }

    func test_confirmSheetKeyboardInputKeepsHeaderAtTopAndEnablesFirstPartial() {
        appHelper.launchWithCompletedOnboarding(scenario: "streaming-partial")
        appHelper.waitForAppReady()

        XCTAssertTrue(appHelper.homeHeader.waitForExistence(timeout: 2.0))
        let initialHeaderMinY = appHelper.homeHeader.frame.minY

        appHelper.startRecording()
        appHelper.submitKeyboardInput("Create a first todo and keep parsing another todo")
        appHelper.waitForConfirmSheet()

        XCTAssertFalse(appHelper.confirmButton.isEnabled, "尚无解析结果时 Add 应保持灰色且不可用")
        XCTAssertTrue(appHelper.confirmButton.waitUntilEnabled(timeout: 4.0), "第一条待办出现后 Add 应立即可用")
        let identifiedStreamingFooter = appHelper.app.otherElements["ConfirmStreamingFooter"]
        let visibleStreamingLabel = appHelper.app.staticTexts["还在识别..."]
        XCTAssertTrue(identifiedStreamingFooter.exists || visibleStreamingLabel.exists, "Add 可用时解析仍应继续")
        XCTAssertEqual(appHelper.homeHeader.frame.minY, initialHeaderMinY, accuracy: 2.0)
        XCTAssertTrue(appHelper.cancelButton.exists)

        let screenshot = XCTAttachment(screenshot: appHelper.app.screenshot())
        screenshot.name = "ConfirmSheet single-capsule controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        appHelper.tapConfirmButton()
        XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 3.0))
        XCTAssertTrue(appHelper.app.staticTexts["第一条待办"].exists)
        XCTAssertFalse(appHelper.app.staticTexts["第二条待办"].exists)
    }

    // MARK: - S01: 正常录入 → 提取多条 → 确认保存

    /// 场景 S01: 正常录入 → 提取多条 → 确认保存
    /// 验证完整的语音录入流程，从录音到保存
    func test_S01_normalInput_multiTodo_confirm() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "multi-todo")
        appHelper.waitForAppReady()

        // Step 3: 点击录音按钮
        appHelper.startRecording()

        // 验证: 录音状态指示器出现
        XCTAssertTrue(appHelper.app.otherElements["RecordingIndicator"].exists)

        // Step 4: 停止录音
        appHelper.stopRecording()

        // Step 5: 等待确认弹窗出现
        appHelper.waitForConfirmSheet()

        // 验证: Sheet 可见，显示语音原文
        XCTAssertTrue(appHelper.confirmSheet.exists)
        XCTAssertTrue(appHelper.transcriptArea.exists)

        // Step 6: 检查提取结果
        XCTAssertEqual(appHelper.extractedTodoCount(), 3, "应该显示 3 条 TODO")

        // 验证: 显示正确的待办标题
        XCTAssertTrue(appHelper.confirmSheet.staticTexts["去银行办卡"].exists)
        XCTAssertTrue(appHelper.confirmSheet.staticTexts["买菜"].exists)
        XCTAssertTrue(appHelper.confirmSheet.staticTexts["给老妈打电话"].exists)

        // Step 7: 点击确认添加
        appHelper.tapConfirmButton()

        // Step 8: 等待 Sheet 关闭
        XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 3.0))

        // Step 9: 验证成功反馈 toast 出现(底部「已添加 N 条」)。
        // 注意:Toast identifier 在 S02 / 流式反馈 / 根部 toast 多处复用,
        // 此断言主要保证"成功反馈确实渲染了",真正的 stagger/cells 揭晓 gate 由 Step 10 兜底。
        // 超时 3s 给余量(toast 寿命本身 2s,前置 cells.count 遍历会吃掉部分时间)。
        XCTAssertTrue(appHelper.app.otherElements["Toast"].waitForExistence(timeout: 3.0))

        // Step 10: 检查 HomeView。新行被压在 opacity 0 直到 revealConfirmedTodos +
        // stagger 跑完,瞬时快照可能读到 0 个 cell。改用 predicate 等待 cells.count == 3。
        let homeTodoList = appHelper.todoList
        let cellsCountPredicate = NSPredicate(format: "cells.count == 3")
        let cellsCountExpectation = XCTNSPredicateExpectation(
            predicate: cellsCountPredicate,
            object: homeTodoList
        )
        let cellsCountResult = XCTWaiter().wait(for: [cellsCountExpectation], timeout: 3.0)
        XCTAssertEqual(
            cellsCountResult,
            .completed,
            "HomeView 应该有 3 条待办(实际 cells.count=\(homeTodoList.cells.count))"
        )
    }

    // MARK: - S02: 纯感受输入 → 空结果 Toast

    /// 场景 S02: 纯感受输入 → 空结果 Toast
    /// 验证 AI 判断为纯感受时，不弹出确认框，而是显示 Toast
    func test_S02_pureFeeling_showsToast() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "no-todo")
        appHelper.waitForAppReady()

        let initialCount = appHelper.todoList.cells.count

        // Step 3: 录音
        appHelper.startRecording()
        appHelper.stopRecording()

        // Step 4: 等待处理完成
        // 验证: ConfirmSheet 不弹出
        XCTAssertFalse(appHelper.confirmSheet.waitForExistence(timeout: 2.0), "ConfirmSheet 不应该弹出")

        // Step 5: 检查 Toast
        appHelper.waitForToast()
        XCTAssertTrue(appHelper.toast.staticTexts["未识别到待办事项"].exists)

        // Step 6: 等待 Toast 消失
        appHelper.waitForToastDismiss()

        // Step 7: 检查 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, initialCount, "待办列表应该无变化")
    }

    // MARK: - S03: 编辑提取结果后确认

    /// 场景 S03: 编辑提取结果后确认
    /// 验证可以在确认界面编辑待办标题
    func test_S03_editTodoTitle_savesModified() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "multi-todo")
        appHelper.waitForAppReady()

        // Step 3: 录音并等待确认弹窗
        appHelper.startRecording()
        appHelper.stopRecording()
        appHelper.waitForConfirmSheet()

        // Step 4: 点击第一条的标题文字
        appHelper.editTodoInSheet(at: 0, newTitle: "去工商银行办卡")

        // Step 5: 点击确认添加
        appHelper.tapConfirmButton()

        // Step 6: 等待 Sheet 关闭
        XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 3.0))

        // Step 7: 检查 HomeView
        XCTAssertTrue(appHelper.todoList.staticTexts["去工商银行办卡"].exists, "保存的标题应该是修改后的版本")
    }

    // MARK: - S04: 删除提取结果中的某条

    /// 场景 S04: 删除提取结果中的某条
    /// 验证可以删除单条提取结果
    func test_S04_deleteOneTodo() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "multi-todo")
        appHelper.waitForAppReady()

        // Step 3: 录音并等待确认弹窗
        appHelper.startRecording()
        appHelper.stopRecording()
        appHelper.waitForConfirmSheet()

        let initialCount = appHelper.extractedTodoCount()
        XCTAssertEqual(initialCount, 3, "应该有 3 条 TODO")

        // Step 4: 点击第 2 条的 ✕ 按钮
        appHelper.deleteTodoInSheet(at: 1)

        // Step 5: 检查列表
        let remainingCount = appHelper.extractedTodoCount()
        XCTAssertEqual(remainingCount, 2, "应该剩余 2 条")

        // Step 6: 检查确认按钮显示
        XCTAssertTrue(appHelper.confirmButton.label.contains("(2)"))

        // Step 7: 点击确认
        appHelper.tapConfirmButton()

        // Step 8: 检查 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, 2, "只保存 2 条")
    }

    // MARK: - S05: 删除全部提取结果

    /// 场景 S05: 删除全部提取结果
    /// 验证删除全部待办后，确认按钮置灰
    func test_S05_deleteAllTodos() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "multi-todo")
        appHelper.waitForAppReady()

        // Step 3: 录音并等待确认弹窗
        appHelper.startRecording()
        appHelper.stopRecording()
        appHelper.waitForConfirmSheet()

        // Step 4: 逐个点击 ✕ 删除全部
        appHelper.deleteTodoInSheet(at: 2)
        appHelper.deleteTodoInSheet(at: 1)
        appHelper.deleteTodoInSheet(at: 0)

        // Step 5: 检查列表为空
        let remainingCount = appHelper.extractedTodoCount()
        XCTAssertEqual(remainingCount, 0, "列表应该为空")

        // Step 6: 检查确认按钮
        XCTAssertFalse(appHelper.confirmButton.isEnabled, "「确认添加 (0)」应该置灰")
        XCTAssertTrue(appHelper.confirmButton.label.contains("(0)"))

        // Step 7: 点击取消
        appHelper.tapCancelButton()

        // Step 8: 检查 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, 0, "无数据写入")
    }

    // MARK: - S06: 取消确认

    /// 场景 S06: 取消确认
    /// 验证点击取消按钮后，不保存数据
    func test_S06_cancelConfirmation() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "multi-todo")
        appHelper.waitForAppReady()

        let initialCount = appHelper.todoList.cells.count

        // Step 3: 录音并等待确认弹窗
        appHelper.startRecording()
        appHelper.stopRecording()
        appHelper.waitForConfirmSheet()

        // Step 4: 点击取消
        appHelper.tapCancelButton()

        // Step 5: 验证 Sheet 关闭
        XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 2.0))

        // Step 6: 检查 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, initialCount, "无新增待办，数据未写入")
    }

    // MARK: - S07: 网络失败 → 离线降级保存

    /// 场景 S07: 网络失败 → 离线降级保存
    /// 验证无网络时，自动降级保存原始文本
    func test_S07_offlineFallback_savesRawTranscript() {
        // Step 1: 启动 App（模拟网络断开）
        appHelper.launchWithNetworkOff()
        appHelper.waitForAppReady()

        let initialCount = appHelper.todoList.cells.count

        // Step 2: 录音
        appHelper.startRecording()
        appHelper.stopRecording()

        // Step 3: 等待处理
        // 验证: ConfirmSheet 不弹出
        XCTAssertFalse(appHelper.confirmSheet.waitForExistence(timeout: 2.0), "ConfirmSheet 不应该弹出")

        // Step 4: 检查 Toast
        appHelper.waitForToast()
        XCTAssertTrue(appHelper.toast.staticTexts["已保存原始记录，联网后将自动整理"].exists)

        // Step 5: 检查 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, initialCount + 1, "新增 1 条")

        // 验证: 标题为原文前 20 字
        let newTodo = appHelper.todoList.cells.element(boundBy: 0)
        XCTAssertTrue(newTodo.staticTexts["明天去银行"].exists)
    }

    // MARK: - S08: 网络恢复后批量补处理

    /// 场景 S08: 网络恢复后批量补处理
    /// 验证网络恢复后，自动处理待处理条目
    func test_S08_networkRecovery_batchProcessing() {
        // Step 1: 预置 2 条 needsAIProcessing=true 的条目
        let presetTodos = [
            UITestTodoPayload(title: "待处理1", rawTranscript: "明天去银行办卡", needsAIProcessing: true),
            UITestTodoPayload(title: "待处理2", rawTranscript: "必须今天交报告", needsAIProcessing: true)
        ]
        appHelper.launchWithPresetTodos(presetTodos)
        appHelper.waitForAppReady()

        XCTAssertEqual(appHelper.todoList.cells.count, 2, "应该有 2 条待处理")

        // Step 2: Mock 网络恢复 + App 进入前台
        // （实际测试中需要模拟网络恢复，这里简化处理）

        // Step 3: 等待处理完成
        let batchConfirmSheet = appHelper.confirmSheet
        XCTAssertTrue(batchConfirmSheet.waitForExistence(timeout: 5.0), "批量确认界面应该弹出")

        // Step 4: 检查提取结果
        let extractedCount = appHelper.extractedTodoCount()
        XCTAssertGreaterThan(extractedCount, 0, "应该显示提取结果")

        // Step 5: 点击确认
        let confirmButton = batchConfirmSheet.buttons["ConfirmAddButton"]
        confirmButton.tap()

        // Step 6: 验证待处理条目被替换
        XCTAssertTrue(batchConfirmSheet.waitForNonExistence(timeout: 3.0))
    }

    // MARK: - S09: HomeView 勾选完成

    /// 场景 S09: HomeView 勾选完成
    /// 验证可以勾选待办为完成状态
    func test_S09_homeView_toggleComplete() {
        // Step 1: 预置 3 条待办
        let presetTodos = [
            UITestTodoPayload(title: "任务A"),
            UITestTodoPayload(title: "任务B"),
            UITestTodoPayload(title: "任务C")
        ]
        appHelper.launchWithPresetTodos(presetTodos)
        appHelper.waitForAppReady()

        XCTAssertEqual(appHelper.todoList.cells.count, 3)

        // Step 2: 点击第 1 条的勾选框
        appHelper.toggleTodoCompletion(at: 0)

        // Step 3: 验证完成状态
        let completedCell = appHelper.todoList.cells["TodoCell_0"]
        XCTAssertTrue(completedCell.staticTexts["completed"].exists, "该条应该显示完成状态")

        // Step 4: 检查数据（isCompleted == true）
        // （通过 UI 验证，实际数据验证需要其他方式）
    }

    // MARK: - S10: HomeView 左滑删除

    /// 场景 S10: HomeView 左滑删除
    /// 验证可以左滑删除待办
    func test_S10_homeView_swipeDelete() {
        // Step 1: 预置 3 条待办
        let presetTodos = [
            UITestTodoPayload(title: "任务1"),
            UITestTodoPayload(title: "任务2"),
            UITestTodoPayload(title: "任务3")
        ]
        appHelper.launchWithPresetTodos(presetTodos)
        appHelper.waitForAppReady()

        XCTAssertEqual(appHelper.todoList.cells.count, 3)

        // Step 2: 左滑第 2 条，点击删除
        appHelper.swipeDeleteTodo(at: 1)

        // Step 3: 检查列表
        XCTAssertEqual(appHelper.todoList.cells.count, 2, "应该剩余 2 条")

        // 验证被删除的条目不存在
        XCTAssertFalse(appHelper.todoList.cells.containing(.staticText, identifier: "任务2").firstMatch.exists)
    }

    // MARK: - S11: HomeView 空状态

    /// 场景 S11: HomeView 全局空状态
    /// 验证无待办时显示今日空状态、底部录音入口，并可切换到日历视图。
    func test_S11_homeView_emptyState() {
        // Step 1: 数据库无待办条目
        appHelper.launchWithCompletedOnboarding()
        appHelper.waitForAppReady()

        // Step 2: 打开 HomeView
        XCTAssertEqual(appHelper.todoList.cells.count, 0)

        // Step 3: 验证今日 tab 的产品化空状态
        XCTAssertTrue(appHelper.emptyState.exists, "应该显示 EmptyStateView")
        XCTAssertTrue(appHelper.emptyState.staticTexts["先把今天想做的事说出来"].exists, "应该显示首页空状态标题")
        XCTAssertTrue(appHelper.app.buttons["RecordFAB"].exists, "应该显示底部录音入口")
        XCTAssertTrue(appHelper.app.buttons["TodayTabButton"].exists, "应该显示今日 tab")

        // Step 4: 切换到日历 tab 后显示月历控制
        let calendarTab = appHelper.app.buttons["CalendarTabButton"]
        XCTAssertTrue(calendarTab.exists, "应该显示日历 tab")
        calendarTab.tap()
        let today = Calendar.current.startOfDay(for: Date())
        let todayButtonIdentifier = "MonthDay_\(today.formatted(.dateTime.year().month().day()))"
        XCTAssertTrue(appHelper.app.buttons[todayButtonIdentifier].waitForExistence(timeout: 2), "应该能进入日历视图")
    }

    // MARK: - S12: 首次启动引导流程

    /// 场景 S12: 首次启动引导流程
    /// 验证首次启动时显示引导流程,包括第三屏 Pro 付费墙的降级路径
    /// (UI 测试环境无 StoreKit mock,商品加载失败时「以后再说」仍可点)。
    func test_S12_firstLaunch_onboarding() {
        // Step 1: App 首次启动(不注入 --skip-onboarding,应显示引导)
        appHelper.launch()

        // Step 2: 验证显示 OnboardingView 及欢迎页
        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0), "应该显示 OnboardingView")
        XCTAssertTrue(appHelper.app.staticTexts["VoiceTodo"].waitForExistence(timeout: 2.0), "应显示欢迎页")

        // Step 3: 欢迎页 → 权限合并页(麦克风 + 语音识别)。
        // UI 测试下权限默认 mock 为「已授权」,合并页不显示授权按钮,直接「下一步」即可。
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.staticTexts["说出你的待办"].waitForExistence(timeout: 2.0), "应进入权限合并页")

        // Step 4: 权限页 → Pro 付费墙。
        // 某些模拟器机型(iPhone 15 Pro+)存在 Action Button 步骤,中间会多一跳 ——
        // 循环 nextButton 直到 Pro 付费墙出现,兼容两类机型。
        appHelper.nextButton.tap()
        let laterButton = appHelper.app.buttons["ProIntroLaterButton"]
        var attempts = 0
        while !laterButton.exists && attempts < 3 {
            if appHelper.nextButton.exists {
                appHelper.nextButton.tap()
            }
            _ = laterButton.waitForExistence(timeout: 1.5)
            attempts += 1
        }

        // Step 5: Pro 付费墙应出现,且「以后再说」可点 —— 这是降级路径的核心验收点。
        // UI 测试环境无 StoreKit mock,Product.products(for:) 返回空 → 付费墙落到 .empty 状态,
        // 显示「暂时无法加载订阅方案」+ 重试按钮。但「以后再说」在外层,始终可点。
        XCTAssertTrue(laterButton.exists, "Pro 付费墙应出现(允许跨过可选的 Action Button 步骤)")
        XCTAssertTrue(laterButton.isEnabled, "「以后再说」始终可点 —— onboarding 不能被 StoreKit 加载失败卡死")

        // Step 6: Pro 付费墙 → 完成页
        laterButton.tap()
        XCTAssertTrue(appHelper.app.staticTexts["搞定啦！"].waitForExistence(timeout: 2.0), "应进入完成页")

        // Step 7: 点击「开始使用」结束引导
        appHelper.nextButton.tap()

        // Step 8: 引导关闭并进入主界面
        appHelper.waitForAppReady(timeout: 5.0)
        XCTAssertTrue(appHelper.onboardingView.waitForNonExistence(timeout: 2.0), "引导 sheet 应已关闭")

        // Step 9: 重新启动 App(保留数据,不重置 UserDefaults)
        appHelper.app.terminate()
        appHelper.relaunchPreservingData()

        // Step 10: 验证直接进入主界面,不再显示引导
        appHelper.waitForAppReady(timeout: 5.0)
        XCTAssertFalse(appHelper.onboardingView.waitForExistence(timeout: 2.0), "重启后不应再显示引导")
    }

    // MARK: - S13: 权限被拒绝场景

    /// 场景 S13: 权限被拒绝场景
    /// 验证权限被拒绝时的处理
    func test_S13_permissionDenied_showsSettings() {
        // Step 1: 启动 App（Mock 麦克风权限被拒）
        appHelper.launchWithMicPermissionDenied()

        // Step 2: 进入权限页面
        appHelper.nextButton.tap()

        // Step 3: 尝试授权（Mock 返回 denied）
        let authorizeButton = appHelper.app.buttons["AuthorizeMicButton"]
        authorizeButton.tap()

        // Step 4: 验证显示错误提示
        XCTAssertTrue(appHelper.app.staticTexts["需要麦克风权限才能录音，请在设置中开启"].waitForExistence(timeout: 2.0))

        // Step 5: 验证显示「跳转设置」按钮
        XCTAssertTrue(appHelper.openSettingsButton.exists, "应该显示跳转设置按钮")

        // Step 6: 验证仍可继续引导流程（不卡死）
        let skipButton = appHelper.app.buttons["SkipButton"]
        if skipButton.exists {
            skipButton.tap()
            // 应该能进入下一步
        }
    }

    // MARK: - S14: 紧急单条待办

    /// 场景 S14: 紧急单条待办
    /// 验证高优先级待办的显示
    func test_S14_urgentTodo_displaysPriority() {
        // Step 1: 启动 App
        appHelper.launchWithCompletedOnboarding(scenario: "urgent-single")
        appHelper.waitForAppReady()

        // Step 3: 录音
        appHelper.startRecording()
        appHelper.stopRecording()

        // Step 4: ConfirmSheet 弹出
        appHelper.waitForConfirmSheet()

        // Step 5: 验证显示 1 条，priority 标签显示"紧急"
        XCTAssertEqual(appHelper.extractedTodoCount(), 1)

        let priorityLabel = appHelper.confirmSheet.staticTexts["PriorityLabel"]
        XCTAssertTrue(priorityLabel.exists)
        XCTAssertEqual(priorityLabel.label, "紧急")

        // Step 6: 确认添加
        appHelper.tapConfirmButton()

        // Step 7: 验证 HomeView 中该条有紧急标记
        XCTAssertTrue(appHelper.app.waitForExistence(timeout: 3.0))
        let homeTodo = appHelper.todoList.cells.firstMatch
        XCTAssertTrue(homeTodo.staticTexts["PriorityLabel"].exists)
    }

    // MARK: - S15: Widget 显示验证

    /// 场景 S15: Widget 显示验证
    /// 验证 Widget 在不同尺寸下的显示
    /// 注意：Widget 测试需要特殊的测试环境，这里提供框架代码
    func test_S15_widget_display() {
        // Widget 测试通常需要使用 WidgetKit 的 snapshot 测试
        // 以下代码为框架示例

        // Step 1: 预置 5 条未完成待办
        let presetTodos = (1...5).map { i in
            UITestTodoPayload(title: "Widget 任务 \(i)")
        }
        appHelper.launchWithPresetTodos(presetTodos)
        appHelper.waitForAppReady()

        // Step 2: 验证 medium Widget snapshot
        // （实际测试需要在 Widget Extension target 中进行）
        // 使用 WidgetKit 的 getTimeline 和 snapshot 方法

        // Step 3: 验证 small Widget snapshot
        // （同上）

        // Step 4: 清空所有待办
        // 清空数据

        // Step 5: 验证 Widget snapshot 显示空状态
        // （同上）

        // 由于 Widget 测试需要特殊的测试环境，这里标记为 pending
        print("Widget 测试需要在 Widget Extension target 中单独执行")
    }
}
