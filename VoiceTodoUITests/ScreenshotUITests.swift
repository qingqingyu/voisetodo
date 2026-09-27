import XCTest

/// App Store 截图套件:在 6.9" 模拟器(iPhone 17 Pro Max, 1320×2868)上
/// 按 7 个固定画面截屏,zh-Hans / en 各一套,共 14 张。
///
/// 运行方式:只经 `scripts/capture-screenshots.sh` 启动(它以
/// `TEST_RUNNER_SCREENSHOT_MODE=1` 传给 xcodebuild,测试进程内读到
/// `SCREENSHOT_MODE=1`);普通 `xcodebuild test` 在 setUp 即 XCTSkip 整类跳过。
///
/// 与脚本/既有设施的对齐约定:
/// - 附件名 `NN-slug__lang`,脚本按 `__` 后缀分拣到 screenshots/{zh,en}/NN-slug.png;
/// - launchArguments 每轮整体重建(S17 先例:增删式拼接会留裸 "-AppleLanguages" 键);
/// - 就绪等待只用 locale 无关的 a11y 标识 —— 禁用 AppLaunchHelper.waitForAppReady
///   (它只探测中文文案「今天」,en 轮必超时,见 ScenarioTests.swift 注释);
/// - 种子 JSON 手工拼、以 App 端 `TodoItemData`(Protocols/Models.swift:545)的
///   Codable 键为准 —— 禁用 AppLaunchHelper.launchWithPresetTodos(它的
///   UITestTodoPayload schema 已漂移,解码失败 app 启动即 fatalError)。
///   日期编码是 JSONDecoder 默认的 timeIntervalSinceReferenceDate 双精度。
final class ScreenshotUITests: XCTestCase {
    private var appHelper: AppLaunchHelper!

    // MARK: - 语言轮次定义

    private struct LanguagePass {
        let tag: String
        let appleLocale: String
        let suffix: String
        /// 录音 mock scenario(zh 用中文句,en 用配套 multi-todo-en)。
        let scenario: String
        /// 种子数据的 localeIdentifier(TodoItemData.localeIdentifier)。
        let localeIdentifier: String
        let titles: [String]
        /// mock 抽取器应返回的 3 条标题 —— ConfirmSheet 画面就绪的显式断言信号
        /// (TodoTitleText_N identifier 被污染,不可用)。
        let expectedExtractTitles: [String]
        /// onboarding 演示步大标题(onboarding.demo.title)—— 演示步就绪信号。
        let demoStepTitle: String
    }

    private var languagePasses: [LanguagePass] {
        [
            LanguagePass(
                tag: "zh-Hans", appleLocale: "zh_Hans", suffix: "zh",
                scenario: "multi-todo", localeIdentifier: "zh-Hans",
                titles: [
                    "整理季度报告", "健身房私教课", "给阳台的花浇水", "团队周会准备",
                    "预约牙医复诊", "买生日礼物", "读 30 页书", "给爸妈打电话",
                    "超市采购一周食材", "练英语听力 20 分钟",
                ],
                expectedExtractTitles: ["去银行办卡", "买菜", "给老妈打电话"],
                demoStepTitle: "一句话，就整理好了"
            ),
            LanguagePass(
                tag: "en", appleLocale: "en_US", suffix: "en",
                scenario: "multi-todo-en", localeIdentifier: "en-US",
                titles: [
                    "Finish quarterly report", "Personal training session", "Water the plants",
                    "Prep for team weekly", "Dentist follow-up", "Buy a birthday gift",
                    "Read 30 pages", "Call parents", "Grocery run for the week",
                    "20 min listening practice",
                ],
                expectedExtractTitles: ["Go to the bank", "Buy groceries", "Call mom"],
                demoStepTitle: "One sentence, neatly done"
            ),
        ]
    }

    // MARK: - 门禁与通用助手

    override func setUpWithError() throws {
        // 截图套件允许单断言失败后继续:一次跑 14 张,某张的等待超时不应吞掉其余画面。
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1" else {
            throw XCTSkip("截图套件只由 scripts/capture-screenshots.sh 运行(需 SCREENSHOT_MODE=1)")
        }
        appHelper = AppLaunchHelper()
    }

    override func tearDown() {
        appHelper = nil
        super.tearDown()
    }

    /// 整体重建 launchArguments 并启动(语言 + UI 测试基础参数 + 各组附加参数)。
    /// 先强制 terminate:上一条流中途失败时 app 可能残留,僵尸 app 会让下一次
    /// launch 的隐式 terminate 挂死(run4 实测 test2/test3 连续死于启动阶段)。
    private func launchApp(_ pass: LanguagePass, extraArguments: [String]) {
        appHelper.app.terminate()
        appHelper.app.launchArguments = [
            "-AppleLanguages", "(\(pass.tag))",
            "-AppleLocale", pass.appleLocale,
            "--ui-testing",
            "--enable-accessibility-identifiers",
            "--reset-user-data",
        ] + extraArguments
        // 付费墙截图需要 StoreKit 本地商品。scheme TestAction 的 StoreKit 引用在
        // iOS 26.5 运行时 + xcodebuild CLI 下不生效(Apple 开发者论坛 826971),
        // 改用 Xcode 同款机制:直接给 app 进程注入 SKStoreKitConfigurationPath。
        appHelper.app.launchEnvironment["SKStoreKitConfigurationPath"] = storeKitConfigPath
        appHelper.app.launch()
    }

    /// Products.storekit 的宿主机绝对路径(#filePath 上两级 = VoiceTodo/)。
    /// 模拟器进程可读宿主路径;截图流水线恒在本机跑,无需打进 runner 包。
    private var storeKitConfigPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Products.storekit")
            .path
    }

    /// locale 无关的首页就绪探测:任一标识出现即算就绪。
    @discardableResult
    private func waitForHomeNeutral(timeout: TimeInterval = 10) -> Bool {
        let app = appHelper.app
        let probes = [
            app.otherElements["HomeHeader"],
            app.otherElements["MonthHomeView"],
            app.tables["TodoList"],
            app.otherElements["RootTabView"],
            app.otherElements["HomeRootView"],
        ]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probes.contains(where: \.exists) { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    /// 终局静置 + 截屏挂永久附件(命名 `NN-slug__lang`,脚本按此分拣)。
    private func capture(_ name: String, pass: LanguagePass) {
        Thread.sleep(forTimeInterval: 0.3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)__\(pass.suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 按 label 查按钮(zh/en 双语文案)。
    ///
    /// 为什么 label 直查而不用 identifier:实测(2026-09-27 Pro Max)Home 根容器的
    /// identifier 会污染子元素 —— tab/FAB/统计条/设置齿轮在 a11y 树里 identifier 均
    /// 变为 'HomeRootView';且**对不存在 identifier 的 waitForExistence 会触发 XCTest
    /// 取证 dump 整棵污染树,runner 两次被 jetsam SIGKILL**(2026-09-27 复现)。
    /// 已知不受污染、可安全用 identifier 的:sheet 子树(ConfirmSheet/ExtractedTodoList/
    /// PaywallPurchaseButton/ReviewPeriodPicker)与列表行(TodoCell_N)。
    private func buttonByLabel(_ labels: [String]) -> XCUIElement {
        appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", labels)
        ).firstMatch
    }

    /// 统计条按钮:label 形如 "2 / 5"(数字 / 数字),与语言无关(identifier 被污染)。
    private func statsBadgeButton() -> XCUIElement {
        appHelper.app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$")
        ).firstMatch
    }

    /// 点录音 FAB:label 直查(zh「录音添加待办」/ en "Tap to record a todo",
    /// key panel.fab.record)→ 坐标兜底(Pro Max 校准:home indicator 34 + 底距 16 +
    /// FAB 72,中心 y = maxY - 86;AppLaunchHelper 的 maxY - 52 是无安全 inset 的
    /// SE 校准值)。
    private func tapRecordFAB() {
        let byLabel = appHelper.app.buttons.matching(
            NSPredicate(format: "label IN %@", ["录音添加待办", "Tap to record a todo"])
        ).firstMatch
        if byLabel.waitForExistence(timeout: 2.0) {
            byLabel.tap()
            return
        }
        let window = appHelper.app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: window.frame.midX, dy: window.frame.maxY - 86)).tap()
    }

    /// 录音面板可见:面板容器 identifier 或「正在聆听/Listening...」文案。
    private func waitForRecordingPanel(timeout: TimeInterval = 4.0) -> Bool {
        let app = appHelper.app
        let probes = [
            app.otherElements["BottomInputPanel"],
            app.staticTexts["正在聆听"],
            app.staticTexts["Listening..."],
        ]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probes.contains(where: \.exists) { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    // MARK: - 组 1:录音中 + ConfirmSheet(mock 语音,shot 01/02)

    func test1_RecordingAndConfirmSheet() throws {
        for pass in languagePasses {
            try runRecordingFlow(pass)
        }
    }

    private func runRecordingFlow(_ pass: LanguagePass) throws {
        launchApp(pass, extraArguments: ["--skip-onboarding", "--scenario=\(pass.scenario)"])
        XCTAssertTrue(waitForHomeNeutral(), "[\(pass.suffix)] 首页应出现")
        Thread.sleep(forTimeInterval: 0.6)

        // Shot 01:录音面板 + 波形 + 转写卡片
        // mock 语音 startRecording 即同步落全文转写(UITestSupport),等录音指示器 +
        // 转写卡片入场(0.2s easeOut)后截屏,波形保持呼吸动画中。
        tapRecordFAB()
        XCTAssertTrue(waitForRecordingPanel(),
                      "[\(pass.suffix)] 录音面板应出现")
        Thread.sleep(forTimeInterval: 1.0)
        capture("01-recording", pass: pass)

        // Shot 02:ConfirmSheet 三条分组待办。
        // 不点确认按钮 —— 避开日历询问/庆祝/首 wow 付费墙弹层链,画面只留确认页本身。
        // 停止成功以「正在聆听/Listening...」消失为显式信号(label 查询可能命中
        // 污染帧,合成事件落到屏幕中心,点了个寂寞;信号未消失就坐标兜底重试)。
        stopRecordingRobust()
        // 确认页内容就绪直接等 mock 的已知标题:停止→抽取→sheet 呈现有延迟,
        // 首个标题给足 8s。不用 appHelper.waitForConfirmSheet/extractedTodoList ——
        // 它们挂在 confirmSheet 的一次性 .exists 解析上,sheet 未及出现时退化到
        // 「取消」按钮子树里找,恒空(run4 实测假失败)。
        for title in pass.expectedExtractTitles {
            XCTAssertTrue(appHelper.app.staticTexts[title].firstMatch.waitForExistence(timeout: 8.0),
                          "[\(pass.suffix)] 待办「\(title)」应出现")
        }
        Thread.sleep(forTimeInterval: 0.6)
        capture("02-confirmsheet", pass: pass)

        appHelper.app.terminate()
    }

    /// 停止录音,三段兜底:identifier(InputSendButton,面板子树实测存活)→
    /// label(「停止录音」/ "Stop recording")→ 面板右下坐标。
    /// 每次 attempt 后用「正在聆听/Listening...」消失验证真的停了。
    private func stopRecordingRobust() {
        let app = appHelper.app
        let listeningText = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["正在聆听", "Listening..."])
        ).firstMatch

        func coordinateStop() {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: window.frame.maxX - 64, dy: window.frame.maxY - 96))
                .tap()
        }

        let byId = app.buttons["InputSendButton"]
        if byId.waitForExistence(timeout: 2.0), byId.isHittable {
            byId.tap()
        } else {
            let byLabel = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["停止录音", "Stop recording", "生成", "Generate"])
            ).firstMatch
            if byLabel.waitForExistence(timeout: 1.5) {
                byLabel.tap()
            } else {
                coordinateStop()
            }
        }

        if !listeningText.waitForNonExistence(timeout: 3.0) {
            coordinateStop()
            _ = listeningText.waitForNonExistence(timeout: 3.0)
        }
    }

    // MARK: - 组 2:种子数据主页流程(shot 03/04/05/06)

    func test2_HomeSeededFlow() throws {
        for pass in languagePasses {
            try runSeededFlow(pass)
        }
    }

    private func runSeededFlow(_ pass: LanguagePass) throws {
        launchApp(pass, extraArguments: ["--skip-onboarding", "--preset-todos", "--todos-data=\(try seedJSON(for: pass))"])
        XCTAssertTrue(waitForHomeNeutral(), "[\(pass.suffix)] 首页应出现")

        let app = appHelper.app

        // 种子解码 smoke:已知今日标题可见。若 TodoItemData schema 漂移导致静默空库,
        // 在这里显式失败,而不是截出 14 张空状态图。
        let knownTitle = app.staticTexts[pass.titles[0]].firstMatch
        XCTAssertTrue(knownTitle.waitForExistence(timeout: 5.0),
                      "[\(pass.suffix)] 种子待办「\(pass.titles[0])」应出现(空库=种子 JSON schema 漂移)")
        Thread.sleep(forTimeInterval: 0.8)

        // Shot 03:Calendar tab 月网格(collapseProgress 初值 0 = 展开满 6 行)。
        // tab.today 的 zh 文案是「今日」(不是「今天」);tab identifier 被污染,label 直查。
        let calendarTab = buttonByLabel(["日历", "Calendar"])
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 3.0), "[\(pass.suffix)] 日历 tab 应存在")
        calendarTab.tap()
        // MonthHomeView identifier 被污染,改用月份大标题做就绪信号
        // (zh "9月" / en "Sep",HomeView.calendarMonthTitle,恒 abbreviated)。
        let monthTitle = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}月$|^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$")
        ).firstMatch
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 3.0),
                      "[\(pass.suffix)] 月视图大标题应出现")
        Thread.sleep(forTimeInterval: 0.8)
        capture("03-month", pass: pass)

        // Shot 04:Today tab 列表 + 进度统计行。TodoList 表 identifier 被污染,
        // 但列表行 TodoCell_N 实测存活,用首行 + 统计条做就绪断言。
        let todayTab = buttonByLabel(["今日", "Today"])
        XCTAssertTrue(todayTab.waitForExistence(timeout: 3.0), "[\(pass.suffix)] 今日 tab 应存在")
        todayTab.tap()
        XCTAssertTrue(app.buttons["TodoCell_0"].waitForExistence(timeout: 3.0),
                      "[\(pass.suffix)] 今日列表首行应出现")
        XCTAssertTrue(statsBadgeButton().waitForExistence(timeout: 3.0),
                      "[\(pass.suffix)] 统计条应可见(今日有种子的完成+未完成)")
        Thread.sleep(forTimeInterval: 0.6)
        capture("04-today", pass: pass)

        // Shot 05:复盘统计页。入口是统计行(HomeStatsBadge → showReviewFromStats sheet)。
        // 类别饼图/柱图数据来自过去 30 天种子完成记录。
        statsBadgeButton().tap()
        let periodPicker = app.descendants(matching: .any).matching(identifier: "ReviewPeriodPicker").firstMatch
        let heroCount = app.descendants(matching: .any).matching(identifier: "ReviewHeroCount").firstMatch
        XCTAssertTrue(periodPicker.waitForExistence(timeout: 5.0) || heroCount.waitForExistence(timeout: 3.0),
                      "[\(pass.suffix)] 复盘统计页应出现")
        Thread.sleep(forTimeInterval: 0.8)
        capture("05-review", pass: pass)

        // 复盘 sheet 的关闭手势不做花活:同参数重启(数据重新种子),保证 06 的起点确定。
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForHomeNeutral(), "[\(pass.suffix)] 重启后首页应出现")
        Thread.sleep(forTimeInterval: 0.6)

        // Shot 06:付费墙。设置 → Upgrade Pro → 等商品加载(TestAction 需带 StoreKit
        // 配置,由脚本注入 .xcscheme —— xcodegen 不生成 test action 的 storeKit 引用);
        // 显式断言非错误态,StoreKit 配置失效时大声失败而不是截出 retry 页。
        let settingsButton = buttonByLabel(["设置", "Settings"])
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5.0), "[\(pass.suffix)] 设置入口应出现")
        settingsButton.tap()
        let upgradeEntry = app.buttons["UpgradeProButton"]
        XCTAssertTrue(upgradeEntry.waitForExistence(timeout: 5.0), "[\(pass.suffix)] 设置页 Pro 入口应出现")
        upgradeEntry.tap()

        let purchaseButton = app.buttons["PaywallPurchaseButton"]
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 10.0), "[\(pass.suffix)] 购买按钮应出现")
        XCTAssertTrue(purchaseButton.waitUntilEnabled(timeout: 10.0),
                      "[\(pass.suffix)] 商品应加载完成(CTA 结束 spinner)")
        XCTAssertFalse(app.buttons["PaywallRetryButton"].exists,
                       "[\(pass.suffix)] 付费墙不应处于错误态(StoreKit 配置未生效?)")
        Thread.sleep(forTimeInterval: 0.5)
        capture("06-paywall", pass: pass)

        app.terminate()
    }

    // MARK: - 组 3:Onboarding 演示页(shot 07)

    func test3_OnboardingDemo() throws {
        for pass in languagePasses {
            try runOnboardingFlow(pass)
        }
    }

    private func runOnboardingFlow(_ pass: LanguagePass) throws {
        // 不带 --skip-onboarding:让 onboarding 全屏引导呈现。
        launchApp(pass, extraArguments: [])
        let app = appHelper.app
        XCTAssertTrue(appHelper.onboardingView.waitForExistence(timeout: 5.0),
                      "[\(pass.suffix)] onboarding 应出现")
        Thread.sleep(forTimeInterval: 0.8)

        // welcome → demo。sheet 内按钮 identifier 被外层 OnboardingView 污染,
        // appHelper.nextButton 的 label 兜底(zh「下一步」/ en "Next")是既有可靠路径。
        XCTAssertTrue(appHelper.nextButton.waitForExistence(timeout: 3.0),
                      "[\(pass.suffix)] 下一步按钮应出现")
        appHelper.nextButton.tap()
        // 演示步就绪信号用大标题 staticText(OnboardingDemoStep identifier 的
        // waitForExistence 在污染树上会触发取证 dump,曾致 runner 被 jetsam SIGKILL)。
        XCTAssertTrue(app.staticTexts[pass.demoStepTitle].firstMatch.waitForExistence(timeout: 5.0),
                      "[\(pass.suffix)] onboarding 演示步应出现")
        Thread.sleep(forTimeInterval: 1.0)
        capture("07-onboarding", pass: pass)

        app.terminate()
    }

    // MARK: - 种子数据(手工 JSON,对齐 App 端 TodoItemData)

    /// 构造截图种子:今日 5 条(3 开放 + 2 完成,统计条 2/5)+ 过去 30 天 ~27 条完成
    /// (复盘月度 hero≈29、类别全覆盖)+ 未来 7 天每天 1 条(月视图即将到来圆点)。
    /// 日期全部由运行时 Date() 推算,任何一天跑都成立;UUID 固定序号,重跑 diff 稳定。
    private func seedJSON(for pass: LanguagePass) throws -> String {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let createdAt = todayStart.addingTimeInterval(-32 * 86400).timeIntervalSinceReferenceDate

        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) throws -> Double {
            let date = try XCTUnwrap(
                calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: todayStart),
                "种子日期计算失败(day=\(dayOffset) hour=\(hour))"
            )
            return date.timeIntervalSinceReferenceDate
        }

        let categories = ["work", "study", "life", "health", "finance", "social"]
        var index = 0

        func item(
            _ title: String,
            category: String,
            timeBucket: String? = nil,
            priority: String = "normal",
            hasDueTime: Bool = false,
            due: Double,
            isCompleted: Bool = false,
            completedAt: Double? = nil
        ) -> String {
            index += 1
            var fields: [String] = [
                "\"id\":\"aaaa0000-0000-4000-8000-\(String(format: "%012d", index))\"",
                "\"title\":\"\(title)\"",
                "\"dueDate\":\(String(format: "%.3f", due))",
                "\"hasDueTime\":\(hasDueTime)",
            ]
            if let timeBucket { fields.append("\"timeBucket\":\"\(timeBucket)\"") }
            fields.append("\"priority\":\"\(priority)\"")
            fields.append("\"category\":\"\(category)\"")
            fields.append("\"isCompleted\":\(isCompleted)")
            if let completedAt { fields.append("\"completedAt\":\(String(format: "%.3f", completedAt))") }
            fields.append("\"createdAt\":\(String(format: "%.3f", createdAt))")
            fields.append("\"needsAIProcessing\":false")
            fields.append("\"sortOrder\":\(index)")
            fields.append("\"extractionOutcome\":\"parsed\"")
            fields.append("\"source\":\"voice\"")
            fields.append("\"localeIdentifier\":\"\(pass.localeIdentifier)\"")
            return "{" + fields.joined(separator: ",") + "}"
        }

        var objects: [String] = []

        // 今日:3 开放(1 条定时傍晚 + 高优) + 2 完成(统计条 2/5)
        objects.append(item(pass.titles[0], category: "work", timeBucket: "evening",
                            priority: "high", hasDueTime: true, due: try at(0, 18)))
        objects.append(item(pass.titles[2], category: "life", timeBucket: "morning", due: try at(0, 9)))
        objects.append(item(pass.titles[1], category: "health", timeBucket: "afternoon", due: try at(0, 14)))
        objects.append(item(pass.titles[9], category: "study", timeBucket: "morning",
                            due: try at(0, 8), isCompleted: true, completedAt: try at(0, 9, 15)))
        objects.append(item(pass.titles[7], category: "social", timeBucket: "afternoon",
                            due: try at(0, 11), isCompleted: true, completedAt: try at(0, 12, 40)))

        // 过去 30 天:每天 1 条完成(跳过 d%9==0 打破均匀感),类别轮换全覆盖
        for day in 1...30 where day % 9 != 0 {
            objects.append(item(
                pass.titles[day % pass.titles.count],
                category: categories[(day - 1) % categories.count],
                due: try at(-day, 9 + day % 3),
                isCompleted: true,
                completedAt: try at(-day, 9 + day % 3, 45)
            ))
        }

        // 未来 7 天:每天 1 条开放,时段轮换,第 3 天高优
        for day in 1...7 {
            objects.append(item(
                pass.titles[(day + 3) % pass.titles.count],
                category: categories[(day + 2) % categories.count],
                timeBucket: ["morning", "afternoon", "evening"][day % 3],
                priority: day == 3 ? "high" : "normal",
                due: try at(day, 10 + day % 3)
            ))
        }

        return "[" + objects.joined(separator: ",") + "]"
    }
}
