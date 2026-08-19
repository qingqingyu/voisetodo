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
            "test_S12_firstLaunch_onboarding",
            "test_S16_calendarPermissionDenied_revertsToggle",
            "test_S17_onboarding_fitsWithoutScrolling",
            "test_S18_firstVoiceTrial_hintToWowPaywall",
            "test_S19_firstVoiceTrial_micDenied_noHint"
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
    /// 验证首次启动时显示引导流程并走到完成页;Pro 付费墙已移出 onboarding
    /// (后置到首次 wow,见 docs/onboarding-first-voice-trial.md §3.5),
    /// 引导内不再出现付费墙,走完后首次语音试用 hint 浮出。
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

        // Step 4: 权限页 → 完成页(Pro 付费墙已移出 onboarding,改为首次 wow 后弹,方案 §3.5)。
        // 从权限页到完成页经过 speechLanguage → calendarSync → [actionButton] → completion。
        appHelper.nextButton.tap()

        // 显式断言两个新步骤依次出现 —— 失败时直接指向具体哪一步,
        // 而不是笼统的「完成页没出现」。
        XCTAssertTrue(appHelper.app.otherElements["OnboardingSpeechLanguageStep"].waitForExistence(timeout: 2.0),
                      "应进入语音识别语言页")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.otherElements["OnboardingCalendarSyncStep"].waitForExistence(timeout: 2.0),
                      "应进入日历同步页")

        let completionTitle = appHelper.app.staticTexts["最后一步"]
        var attempts = 0
        while !completionTitle.exists && attempts < 6 {
            if appHelper.nextButton.exists {
                appHelper.nextButton.tap()
            }
            _ = completionTitle.waitForExistence(timeout: 1.5)
            attempts += 1
        }

        // Step 5: 完成页应出现(允许跨过可选的 Action Button 步骤)。
        // onboarding 内不应再出现付费墙 —— 它已后置到首次 wow。
        XCTAssertTrue(completionTitle.exists, "完成页应出现")
        XCTAssertFalse(appHelper.app.buttons["ProIntroLaterButton"].exists,
                       "onboarding 内不应再有 Pro 付费墙")

        // Step 6: 点击「去试一句」结束引导
        appHelper.nextButton.tap()

        // Step 8: 引导关闭并进入主界面;权限已 mock 授权,首次语音试用 hint 应浮出
        // (hint 容器 children:.contain 不作为可查询元素,用「知道了」按钮作存在信号)
        appHelper.waitForAppReady(timeout: 5.0)
        XCTAssertTrue(appHelper.onboardingView.waitForNonExistence(timeout: 2.0), "引导 sheet 应已关闭")
        XCTAssertTrue(appHelper.app.buttons["FirstVoiceTrialGotItButton"].waitForExistence(timeout: 3.0),
                      "走完 onboarding(含授权)后应显示首次语音试用 hint")

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

    // MARK: - S18: 首次语音试用引导(正例)

    /// 场景 S18: 走完 onboarding(含授权)→ hint 浮出 → 引导下录第一条 → wow → 后置 paywall。
    /// 方案 docs/onboarding-first-voice-trial.md §3.8c 正例。
    /// mock 转写默认「明天去银行」落别日 → 庆祝 toast 带「去看看」(4.0s),
    /// paywall 延迟 = 4.0 + 0.3 = 4.3s,断言超时给足余量。
    func test_S18_firstVoiceTrial_hintToWowPaywall() {
        // Step 1: 全新启动,走完 onboarding(权限 mock 已授权)
        appHelper.launch()
        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0), "应该显示 OnboardingView")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.staticTexts["说出你的待办"].waitForExistence(timeout: 2.0), "应进入权限合并页")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.otherElements["OnboardingSpeechLanguageStep"].waitForExistence(timeout: 2.0),
                      "应进入语音识别语言页")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.otherElements["OnboardingCalendarSyncStep"].waitForExistence(timeout: 2.0),
                      "应进入日历同步页")

        let completionTitle = appHelper.app.staticTexts["最后一步"]
        var attempts = 0
        while !completionTitle.exists && appHelper.onboardingView.exists && attempts < 6 {
            if appHelper.nextButton.exists {
                appHelper.nextButton.tap()
            }
            _ = completionTitle.waitForExistence(timeout: 1.5)
            attempts += 1
        }
        XCTAssertTrue(completionTitle.exists, "应走到完成页")
        appHelper.nextButton.tap()  // 「去试一句」→ 关闭引导

        // Step 2: hint 浮出(HomeView 挂载 + 0.4s 延迟)
        appHelper.waitForAppReady()
        // hint 容器(children: .contain)不作为可查询元素暴露,用「知道了」按钮作存在信号
        // (a11y id: FirstVoiceTrialGotItButton,树中已验证可达)。
        let hint = appHelper.app.buttons["FirstVoiceTrialGotItButton"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3.0), "走完 onboarding(含授权)后 hint 应浮出")

        // Step 3: 点 FAB 录音(mock 转写)→ 确认保存。
        // FAB 用坐标点击:hint 展示时其 a11y 元素被容器污染撑成全屏,tap 会落屏幕中心。
        appHelper.tapRecordFABByCoordinate()
        XCTAssertTrue(appHelper.switchToKeyboardButton.waitForExistence(timeout: 2.0), "录音面板应该出现")
        appHelper.stopRecording()
        appHelper.waitForConfirmSheet()
        appHelper.tapConfirmButton()
        XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 3.0))

        // Step 4: hint 消失(状态已 .completed)
        XCTAssertTrue(hint.waitForNonExistence(timeout: 3.0), "首次语音待办落库后 hint 应消失")

        // Step 5: 庆祝 toast → wow 播完后后置 paywall 弹出(§3.5d)。
        // toast 的 a11y identifier 受容器污染,用庆祝文案匹配(测试强制 zh)。
        let celebrateToast = appHelper.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "太棒了")
        ).firstMatch
        XCTAssertTrue(celebrateToast.waitForExistence(timeout: 3.0), "庆祝 toast 应出现")
        let paywallNavBar = appHelper.app.navigationBars["升级 VoiceTodo Pro"]
        let paywallClose = appHelper.app.buttons["关闭"]
        let paywallShown = paywallNavBar.waitForExistence(timeout: 10.0)
            || paywallClose.waitForExistence(timeout: 1.0)
            || appHelper.app.navigationBars.firstMatch.waitForExistence(timeout: 1.0)
        if !paywallShown {
            print("===PAYWALL-DEBUG-BEGIN===\n\(appHelper.app.debugDescription)\n===PAYWALL-DEBUG-END===")
        }
        XCTAssertTrue(paywallShown,
                      "wow 播完后付费墙应弹出(延迟 2.3~4.3s,取决于 toast 是否带「去看看」)")

        // Step 6: 一屏化断言 —— 付费墙全部内容(含「开始 7 天免费试用」CTA + 法务三件套)
        // 不滚动即可见。依赖 DEBUG 钩子 PaywallContentFits(value "1|content=|viewport=|state="),
        // 轮询/判定逻辑与 S17 的 OnboardingContentFits 同款。
        let fitsHook = appHelper.app.otherElements["PaywallContentFits"]
        XCTAssertTrue(fitsHook.waitForExistence(timeout: 5.0), "付费墙应暴露 PaywallContentFits 钩子")

        // 前置 ①:等商品加载落定到稳定态(success/empty/error),empty/error 时点
        // 重试按钮恢复(storekitd 偶发抽风,见 PaywallView productList `.empty` 注释)。
        // 注意:CLI `xcodebuild test` 不给被测进程注入 StoreKit 配置,商品恒 empty
        // (既有结论,S20 购买类测试因此只能 Xcode GUI 跑)——重试后仍非 success
        // 不是失败,下方的 fits 断言对实际到达的稳定态生效;success 最坏态
        // (商品卡+CTA+试用卡全渲染)由 GUI 跑法覆盖。
        var fits = (fitsHook.value as? String) ?? "nil"
        let retryButton = appHelper.app.buttons["PaywallRetryButton"]
        var retryRounds = 0
        while !fits.contains("state=success") && retryRounds < 2 {
            // 单轮最多等 2s 让 refresh 落定(loading → success/empty/error)
            var waited = 0.0
            while waited < 2.0,
                  !fits.contains("state=success"),
                  !fits.contains("state=empty"),
                  !fits.contains("state=error") {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 0.25
                fits = (fitsHook.value as? String) ?? "nil"
            }
            if fits.contains("state=success") { break }
            guard retryButton.waitForExistence(timeout: 2.0) else { break }
            retryButton.tap()
            retryRounds += 1
            fits = (fitsHook.value as? String) ?? "nil"
        }

        // 前置 ②(仅 success 态):intro 资格查询落定 —— 内容才是「最坏正常态」
        // (试用价值卡 + trial_included + 法务文案全渲染)。legalText 恰在 success
        // 且查询落定时渲染;CTA 在 success 时就出现(查询期间显 spinner),不能作信号。
        // 测试强制 zh,匹配中文「自动续费」。
        if fits.contains("state=success") {
            let legalText = appHelper.app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "自动续费")
            ).firstMatch
            if !legalText.waitForExistence(timeout: 10.0) {
                print("===PAYWALL-FITS-DEBUG-BEGIN===\nvalue=\(fits)\n\(appHelper.app.debugDescription)\n===PAYWALL-FITS-DEBUG-END===")
            }
            XCTAssertTrue(legalText.exists,
                          "付费墙(success)应渲染法务文案(最坏正常态,含试用卡),value=\(fits)")
        }

        // 钩子值过渡态等收敛:视口未测得报 "pending";content=0 是初值假阳性;
        // 试用卡渲染等后续布局变化会让 0→1,给短暂轮询窗口(同 S17)。
        var settleAttempts = 0
        while settleAttempts < 12,
              fits == "pending" || fits == "nil"
              || Self.contentHeight(from: fits) <= 0
              || (String(fits.prefix(1)) == "0" && settleAttempts < 6) {
            Thread.sleep(forTimeInterval: 0.25)
            fits = (fitsHook.value as? String) ?? "nil"
            settleAttempts += 1
        }
        attachScreenshot(named: "paywall-fits\(fits)")
        XCTAssertEqual(String(fits.prefix(1)), "1",
                       "付费墙内容溢出一屏(需要滚动才能看到 CTA),value=\(fits)")
    }

    // MARK: - S19: 首次语音试用引导(反例:权限未授予)

    /// 场景 S19: onboarding 里麦克风权限被拒 → arm 直接 .dismissed,不显示 hint;
    /// 点 FAB 走原有 VoicePermissionRepromptSheet 路径(§3.8c 反例)。
    func test_S19_firstVoiceTrial_micDenied_noHint() {
        appHelper.launchWithMicPermissionDenied()
        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0))

        // 欢迎页 → 权限页;权限 mock 拒绝,「继续」不授权也能走
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.staticTexts["说出你的待办"].waitForExistence(timeout: 2.0), "应进入权限合并页")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.otherElements["OnboardingSpeechLanguageStep"].waitForExistence(timeout: 2.0),
                      "应进入语音识别语言页")
        appHelper.nextButton.tap()
        XCTAssertTrue(appHelper.app.otherElements["OnboardingCalendarSyncStep"].waitForExistence(timeout: 2.0),
                      "应进入日历同步页")

        // 走到完成页,点「去试一句」关闭引导
        let completionTitle = appHelper.app.staticTexts["最后一步"]
        var attempts = 0
        while !completionTitle.exists && appHelper.onboardingView.exists && attempts < 6 {
            if appHelper.nextButton.exists {
                appHelper.nextButton.tap()
            }
            _ = completionTitle.waitForExistence(timeout: 1.5)
            attempts += 1
        }
        XCTAssertTrue(completionTitle.exists, "应走到完成页")
        appHelper.nextButton.tap()

        // 权限未授予 → 不出现 hint(arm 即 .dismissed);hint 容器不可查,用「知道了」按钮反查
        appHelper.waitForAppReady()
        XCTAssertFalse(appHelper.app.buttons["FirstVoiceTrialGotItButton"].waitForExistence(timeout: 2.5),
                      "权限未授予时不应出现首次语音试用 hint")

        // 点 FAB → 原有 VoicePermissionRepromptSheet 接管(坐标点击,理由同 S18)
        appHelper.tapRecordFABByCoordinate()
        // identifier 在 sheet 内可能被污染,label 兜底
        let repromptAllow = appHelper.app.buttons["RepromptAllowButton"]
        let repromptByLabel = appHelper.app.buttons["允许访问"]
        XCTAssertTrue(repromptAllow.waitForExistence(timeout: 3.0) || repromptByLabel.exists,
                      "应走原有权限二次引导 sheet(RepromptAllowButton / 允许访问)")
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

    // MARK: - S16: 日历权限被拒后开关视觉回弹

    /// 场景 S16: 日历权限被拒后开关视觉回弹
    /// 验证 onboarding 日历同步页在权限被拒时:
    ///   1. 开关视觉回弹到关(持久化保持 .appOnly,不变量成立)
    ///   2. 出现「去设置开启」按钮
    ///   3. 「下一步」始终可点,引导不被权限拒绝卡死
    ///   4. 能继续走完引导进入主界面
    func test_S16_calendarPermissionDenied_revertsToggle() {
        // Step 1: 启动 App(--calendar-permission-denied 模拟日历权限被拒)
        appHelper.launchWithCalendarPermissionDenied()
        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0), "应该显示 OnboardingView")

        // Step 2: 走到日历同步页(欢迎 → 权限 → 语言 → 日历,3 次 nextButton)
        appHelper.nextButton.tap()  // 欢迎页 → 权限合并页
        XCTAssertTrue(appHelper.app.staticTexts["说出你的待办"].waitForExistence(timeout: 2.0),
                      "应进入权限合并页")

        appHelper.nextButton.tap()  // 权限页 → 语言页
        XCTAssertTrue(appHelper.app.otherElements["OnboardingSpeechLanguageStep"].waitForExistence(timeout: 2.0),
                      "应进入语音识别语言页")

        appHelper.nextButton.tap()  // 语言页 → 日历页
        XCTAssertTrue(appHelper.app.otherElements["OnboardingCalendarSyncStep"].waitForExistence(timeout: 2.0),
                      "应进入日历同步页")

        // Step 3: 打开日历开关(Mock 必返回 denied)
        let toggle = appHelper.app.switches["CalendarSyncToggle"]
        XCTAssertTrue(toggle.exists, "日历同步开关应存在")
        toggle.tap()

        // Step 4: 权限被拒后应显示「去设置开启」按钮
        let openSettingsButton = appHelper.app.buttons["OnboardingCalendarOpenSettingsButton"]
        XCTAssertTrue(openSettingsButton.waitForExistence(timeout: 2.0),
                      "权限被拒后应显示「去设置开启」")

        // Step 5: 开关视觉应回弹到 off(持久化 calendarWriteModeRaw 全程没被写过,保持 .appOnly)
        XCTAssertEqual(toggle.value as? String, "0", "权限被拒后开关应回弹到关")

        // Step 6: 「下一步」仍可点 —— onboarding 不被权限拒绝卡死
        XCTAssertTrue(appHelper.nextButton.isEnabled, "「下一步」始终可点")

        // Step 7: 走完引导进入主界面
        appHelper.nextButton.tap()
        // 跳过 [Action Button](若存在)直至完成页,点「去试一句」结束引导。
        // 付费墙已不在 onboarding 内(移到首次 wow 后,方案 §3.5)。
        let completionTitle = appHelper.app.staticTexts["最后一步"]
        var attempts = 0
        while !completionTitle.exists && appHelper.onboardingView.exists && attempts < 6 {
            if appHelper.nextButton.exists {
                appHelper.nextButton.tap()
            }
            _ = completionTitle.waitForExistence(timeout: 1.5)
            attempts += 1
        }
        if completionTitle.exists {
            appHelper.nextButton.tap()
        }
        appHelper.waitForAppReady(timeout: 5.0)
        XCTAssertTrue(appHelper.onboardingView.waitForNonExistence(timeout: 3.0),
                      "权限被拒不应卡死引导,应能进入主界面")
    }

    // MARK: - S17: Onboarding 小屏一屏装下

    /// 场景 S17: onboarding 每一步在 iPhone SE 上不需要滚动。
    /// 依赖 App 侧 DEBUG 构建暴露的隐藏元素 OnboardingContentFits(value "1"/"0"),
    /// 对每一步做确定性断言,并附截图供人工核对布局(截断/居中/间距)。
    /// 覆盖 zh-Hans 与 en 两语言:每轮整体重建 launchArguments 指定语言
    /// (AppLaunchHelper 的默认语言参数不复用,避免拼接残留)。
    func test_S17_onboarding_fitsWithoutScrolling() {
        runOnboardingFitCheck(languageTag: "zh-Hans", appleLocale: "zh_Hans", suffix: "zh")
        runOnboardingFitCheck(languageTag: "en", appleLocale: "en_US", suffix: "en")
    }

    private func runOnboardingFitCheck(languageTag: String, appleLocale: String, suffix: String) {
        let app = appHelper.app
        // 每轮整体重建 launchArguments,不在上一轮残留参数上做增删 ——
        // 增删式拼接会留下裸 "-AppleLanguages"/"-AppleLocale" 键和重复 flag,
        // 语言归属依赖参数解析器的未定义行为。
        app.launchArguments = [
            "-AppleLanguages", "(\(languageTag))",
            "-AppleLocale", appleLocale,
            "--ui-testing",
            "--enable-accessibility-identifiers",
            "--reset-user-data"
        ]
        app.launch()

        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0), "应该显示 OnboardingView")

        // 逐步前进。每一步(共 5–6 步,proPaywall 已移出 onboarding)都断言
        // contentFits == "1" 并截图。
        //
        // 循环存续判定用内容钩子 OnboardingContentFits(它在每一步的 a11y 树里,
        // 实测稳定可查),不用 NextButton —— sheet 的 a11y 树中按钮 identifier 会被
        // 外层 accessibilityIdentifier("OnboardingView") 污染(identifier 查不到,
        // 只剩 label 可匹配),appHelper.nextButton 的 label 兜底又可能跨页面误匹配。
        // sheet 关闭时钩子随树一起消失,天然是可靠的「引导还在」信号。
        var stepIndex = 0
        var fittedStepCount = 0
        // 步数上限:模拟器 5 步(无 Action Button:welcome/权限/语言/日历/完成),
        // 真机最多 6 步,取 8 留余量。超过说明引导没按预期推进,
        // 由循环后的「引导应关闭」断言兜底报错。
        let maxStepCount = 8
        let fitsHook = app.otherElements["OnboardingContentFits"]
        while stepIndex < maxStepCount {
            guard fitsHook.waitForExistence(timeout: 2.0) else { break }
            // 钩子值有三个过渡态需要等收敛:视口未测得时报 "pending";
            // 视口测得后 isCompact 翻转,内容高度还需一帧布局才落到位
            // (首帧非紧凑的 "0" 是过渡值);content=0 说明内容高度还没测到,
            // 此时的 "1" 是初值假阳性,不能放行。轮询至稳定 1,或确认持续为 0。
            // 总尝试上限 12 次(≈3s)兜底:视口测量万一不触发,
            // "pending"/"nil" 分支不能无上限轮询,否则测试挂死。
            var fits = (fitsHook.value as? String) ?? "nil"
            var settleAttempts = 0
            while settleAttempts < 12,
                  fits == "pending" || fits == "nil"
                      || Self.contentHeight(from: fits) <= 0
                      || (String(fits.prefix(1)) == "0" && settleAttempts < 6) {
                Thread.sleep(forTimeInterval: 0.25)
                fits = (fitsHook.value as? String) ?? "nil"
                settleAttempts += 1
            }
            // 钩子值形如 "0|content=560|viewport=543",判定只看首字符
            let fitsFlag = String(fits.prefix(1))
            attachScreenshot(named: "onboarding-\(suffix)-step\(stepIndex)-fits\(fits)")
            XCTAssertEqual(fitsFlag, "1",
                           "[\(suffix)] 步骤 \(stepIndex) 内容溢出一屏(需要滚动),value=\(fits)")
            fittedStepCount += 1

            guard appHelper.nextButton.waitForExistence(timeout: 2.0) else { break }
            appHelper.nextButton.tap()
            // 等步骤切换稳定,避免下一轮读到上一步的钩子值
            Thread.sleep(forTimeInterval: 0.4)
            stepIndex += 1
        }

        // 防静默通过:循环若因钩子/按钮提前丢失而 break,可能一步都没断言就走到这;
        // 模拟器 5 步、真机 6 步(proPaywall 已移出),下限取 5。
        XCTAssertGreaterThanOrEqual(fittedStepCount, 5,
                                    "[\(suffix)] 实际做过 fits 断言的步骤只有 \(fittedStepCount),引导未按预期推进")

        // 不用 appHelper.waitForAppReady:它只认中文首页标记(「今天」等),
        // en 轮次首页是英文文案必然超时;引导 sheet 消失即为本测试的完成判据。
        XCTAssertTrue(appHelper.onboardingView.waitForNonExistence(timeout: 3.0),
                      "[\(suffix)] 走完所有步骤后引导应关闭")
        app.terminate()
    }

    /// 截图并作为永久附件挂到当前测试(供人工核对布局:截断/居中/间距)。
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 解析 OnboardingContentFits 钩子值里的 content 高度("1|content=543|viewport=521|compact=1")。
    /// 解析不出(过渡态 "pending"/"nil")返回 -1,调用方据此继续轮询。
    private static func contentHeight(from rawValue: String) -> Int {
        guard let contentPart = rawValue.split(separator: "|")
            .first(where: { $0.hasPrefix("content=") }),
              let value = Int(contentPart.dropFirst("content=".count))
        else { return -1 }
        return value
    }
}
