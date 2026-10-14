import XCTest

/// 复盘 v6 视觉改版截图套件(docs/todo-review-flow-v6-visual.md §5 验收):
/// 第 1–5 步 × zh/en/ja × 浅/深色 + zh AX5(第 1 步标题 / 第 2 步 2×2 /
/// 第 5 步问题与输入框)+ 回顾页(改版前后对比的「后」侧)。
///
/// 运行门禁:`TEST_RUNNER_V6_SCREENSHOTS=1` 传给 xcodebuild(runner 进程读到
/// `V6_SCREENSHOTS=1`);`V6_APPEARANCE=dark` 切深色(runner 内 simctl ui);
/// `V6_AX=1` 附加 AX5 内容字号;`V6_SCOPE=reviewpage` 只截回顾页(基线分支
/// 跑「前」侧对比用,旧代码走不进新流程断言)。
///
/// 附件名 `v6-slug__lang-appearance`(可再带 `-ax`),导出后按名分拣。
/// 种子数据经 `--todos-data`(与 ScreenshotUITests 同款手拼 JSON)+
/// `--preset-review-data`(历史会话 + 上次置顶,App 端 UITestLaunchOptions)。
final class ReviewFlowV6ScreenshotUITests: XCTestCase {
    private var appHelper: AppLaunchHelper!

    private struct Pass {
        let tag: String
        let appleLocale: String
        let suffix: String
        let localeIdentifier: String
        // 导航文案(label 直查,a11y identifier 被污染时的兜底)
        let nextLabels: [String]
        let dropLabels: [String]
        let keepLabels: [String]
        // 种子标题(按语言)
        let pinnedDone: String
        let pinnedOpen: String
        let pinnedOpenRaw: String
        let deckTitles: [String]
        let batchTitles: [String]
        let tailTitles: [String]
        let completedTitles: [String]
        let nextWeekTitles: [String]
        let longNote: String
        let oldNotes: [String]
    }

    private var passes: [Pass] {
        [
            Pass(
                tag: "zh-Hans", appleLocale: "zh_Hans", suffix: "zh", localeIdentifier: "zh-Hans",
                nextLabels: ["下一步", "完成复盘"],
                dropLabels: ["不做了"],
                keepLabels: ["排下周"],
                pinnedDone: "交季度报告",
                pinnedOpen: "找时间理发",
                pinnedOpenRaw: "这周找时间去理个发",
                deckTitles: [
                    "重庆的脚本调试", "预约牙医复诊", "更新测试环境的报文配置",
                    "整理对账差异清单", "回复数据迁移的邮件", "买猫粮",
                    "研究报销政策", "整理会议纪要模板",
                ],
                batchTitles: ["整理旧电脑里的照片", "研究个税专项附加扣除", "给阳台装个晾衣架"],
                tailTitles: ["换护照照片", "清理冰箱", "更新密码", "预约体检"],
                completedTitles: ["写周报", "处理快递", "准备评审材料", "回复合作邮件", "配置构建脚本"],
                nextWeekTitles: ["准备季度复盘会的材料", "交周报"],
                longNote: "工作的事太多了,下周想先把重庆的脚本收尾。\n周末尽量不看工作消息。\n另外想开始跑步,先一周两次。",
                oldNotes: ["工作占了 9 件,我想先放下……", "周末不想再看工作消息,试试关通知。"]
            ),
            Pass(
                tag: "en", appleLocale: "en_US", suffix: "en", localeIdentifier: "en-US",
                nextLabels: ["Next", "Done"],
                dropLabels: ["Not doing it"],
                keepLabels: ["Next week"],
                pinnedDone: "Finish quarterly report",
                pinnedOpen: "Get a haircut",
                pinnedOpenRaw: "Gotta find time for a haircut this week",
                deckTitles: [
                    "Debug the Chongqing script", "Book dentist follow-up", "Update test env config",
                    "Reconcile the diff list", "Reply to the migration email", "Buy cat food",
                    "Read the reimbursement policy", "Set up meeting notes template",
                ],
                batchTitles: ["Sort old laptop photos", "Research tax deductions", "Install a drying rack"],
                tailTitles: ["Renew passport photo", "Clean the fridge", "Update passwords", "Book a checkup"],
                completedTitles: ["Write the weekly", "Handle packages", "Prep review notes", "Reply to partner email", "Fix the build script"],
                nextWeekTitles: ["Prep the quarterly review deck", "Submit the weekly"],
                longNote: "Work piled up again. Next week I want to wrap up the Chongqing script first.\nTrying not to check work messages on weekends.\nAlso want to start running, twice a week.",
                oldNotes: ["Work was 9 of them. I want to let it go…", "No work messages on weekends. Muting notifications."]
            ),
            Pass(
                tag: "ja", appleLocale: "ja_JP", suffix: "ja", localeIdentifier: "ja-JP",
                nextLabels: ["次へ", "振り返り完了"],
                dropLabels: ["やめる"],
                keepLabels: ["来週へ"],
                pinnedDone: "四半期レポートを提出",
                pinnedOpen: "床屋に行く",
                pinnedOpenRaw: "今週どこかで床屋に行かないと",
                deckTitles: [
                    "重慶のスクリプト修正", "歯科の再診を予約", "テスト環境の設定を更新",
                    "照合差分リストを整理", "移行メールに返信", "猫のフードを買う",
                    "経費精算の規約を読む", "議事録テンプレを作る",
                ],
                batchTitles: ["古いPCの写真を整理", "所得税の控除を調べる", "ベランダに物干し台"],
                tailTitles: ["パスポート写真を更新", "冷蔵庫を掃除", "パスワード更新", "健康診断予約"],
                completedTitles: ["週報を書く", "荷物を処理", "レビュー資料", "取引先に返信", "ビルド修正"],
                nextWeekTitles: ["四半期レビュー資料", "週報を出す"],
                longNote: "仕事が多すぎて、来週はまず重慶のスクリプトを片付けたい。\n週末は仕事メッセージを見ない。\nあと走り始めたい、週2回から。",
                oldNotes: ["仕事が9件を占めていた。いったん手放したい……", "週末は仕事メッセージを見ないようにした。"]
            ),
        ]
    }

    // MARK: - 门禁

    private var screenshotMode: Bool {
        ProcessInfo.processInfo.environment["V6_SCREENSHOTS"] == "1"
    }
    private var appearance: String {
        ProcessInfo.processInfo.environment["V6_APPEARANCE"] == "dark" ? "dark" : "light"
    }
    private var isAX: Bool {
        ProcessInfo.processInfo.environment["V6_AX"] == "1"
    }
    /// reviewpage = 只截回顾页(基线分支跑「前」侧)。
    private var scope: String {
        ProcessInfo.processInfo.environment["V6_SCOPE"] ?? "flow"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard screenshotMode else {
            throw XCTSkip("v6 截图套件由显式环境变量驱动(V6_SCREENSHOTS=1)")
        }
        appHelper = AppLaunchHelper()
        // 外观由调用方 shell `xcrun simctl ui <udid> appearance dark` 切换
        // (iOS 测试进程无 Process);`V6_APPEARANCE` 只用于附件命名。
    }

    override func tearDown() {
        appHelper = nil
        super.tearDown()
    }

    // MARK: - 主流程

    func testReviewFlowShots() throws {
        for pass in passes {
            try runFlow(pass)
        }
    }

    private func runFlow(_ pass: Pass) throws {
        let todosJSON = try seedTodosJSON(for: pass)
        let reviewJSON = try seedReviewJSON(for: pass)

        var extra = [
            "--skip-onboarding",
            "--preset-todos",
            "--todos-data=\(todosJSON)",
            "--preset-review-data=\(reviewJSON)",
        ]
        if isAX {
            extra += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }

        appHelper.app.terminate()
        appHelper.app.launchArguments = [
            "-AppleLanguages", "(\(pass.tag))",
            "-AppleLocale", pass.appleLocale,
            "--ui-testing",
            "--enable-accessibility-identifiers",
            "--reset-user-data",
        ] + extra
        appHelper.app.launch()

        let app = appHelper.app
        XCTAssertTrue(waitForHomeNeutral(), "[\(pass.suffix)] 首页应出现")

        // 回顾页(「后」侧;R11 对比基线)。
        let statsBadge = app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+ / [0-9]+$")
        ).firstMatch
        XCTAssertTrue(statsBadge.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 统计条应出现")
        statsBadge.tap()
        let reviewReady = app.descendants(matching: .any)
            .matching(identifier: "ReviewPeriodPicker").firstMatch
        XCTAssertTrue(reviewReady.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 回顾页应出现")
        Thread.sleep(forTimeInterval: 0.8)
        capture("v6-reviewpage", pass: pass)

        if scope == "reviewpage" {
            app.terminate()
            return
        }

        // 进入五步流程。
        let entry = app.descendants(matching: .any).matching(identifier: "ReviewFlowEntryCard").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5.0), "[\(pass.suffix)] 复盘入口卡应出现")
        entry.tap()

        // 第 1 步:主卡(上次定的重点)。
        XCTAssertTrue(waitForPrimary(pass), "[\(pass.suffix)] 第 1 步主按钮应出现")
        Thread.sleep(forTimeInterval: 0.6)
        capture("v6-step1", pass: pass)
        // 滚动到底:上期你写了 + 展开按钮。
        swipeUp(app)
        capture("v6-step1b", pass: pass)

        // 第 2 步:卡堆(置顶卡带头像 chip + 原话)→ 划掉一张出撤销提示条 →
        // 再排一张进下周(第 4 步的「你刚排进下周的」来源)。
        try tapPrimary(pass)
        let triageCard = app.descendants(matching: .any).matching(identifier: "ReviewFlowTriageCard").firstMatch
        XCTAssertTrue(triageCard.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 第 2 步卡堆应出现")
        Thread.sleep(forTimeInterval: 0.8) // nudge 教学动画落定
        capture("v6-step2", pass: pass)
        let dropButton = app.buttons.matching(
            NSPredicate(format: "label IN %@", pass.dropLabels)
        ).firstMatch
        if dropButton.waitForExistence(timeout: 4.0) {
            tapElement(dropButton)
            Thread.sleep(forTimeInterval: 1.0) // 飞出动画 + 提示条落位
        }
        capture("v6-step2b", pass: pass)
        let keepButton = app.buttons.matching(
            NSPredicate(format: "label IN %@", pass.keepLabels)
        ).firstMatch
        if keepButton.waitForExistence(timeout: 4.0) {
            tapElement(keepButton)
            Thread.sleep(forTimeInterval: 1.0)
        }

        // 第 3 步:规则卡 + 你的清单。
        try tapPrimary(pass)
        Thread.sleep(forTimeInterval: 1.2) // 引擎在流程启动已跑完,等入场动画
        capture("v6-step3", pass: pass)
        // 滚动:你的清单卡的分布条/最久列表/积压集中段 + 事实行。
        swipeUp(app)
        capture("v6-step3b", pass: pass)

        // 第 4 步:勾一件升入「下周重点」。
        try tapPrimary(pass)
        let preexisting = app.staticTexts[pass.nextWeekTitles[0]].firstMatch
        XCTAssertTrue(preexisting.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 第 4 步候选应出现")
        if preexisting.exists {
            tapElement(preexisting)
            Thread.sleep(forTimeInterval: 0.5)
        }
        capture("v6-step4", pass: pass)

        // 第 5 步:小结 + 问问自己 + 历次笔记 + 下次复盘。
        try tapPrimary(pass)
        let askField = app.descendants(matching: .any).matching(identifier: "ReviewFlowAskYourself").firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 第 5 步输入框应出现")
        Thread.sleep(forTimeInterval: 0.6)
        capture("v6-step5", pass: pass)
        // 滚动到底:历次笔记全文 + AI 草稿 chip + 对照行 + 下次复盘一行。
        swipeUp(app)
        capture("v6-step5b", pass: pass)

        app.terminate()
    }

    /// 步骤内滚动(上滑一屏,看折叠线以下的内容)。
    private func swipeUp(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - 导航兜底

    /// 主按钮:identifier 优先(ReviewFlowPrimary),被污染时按 label 兜底
    /// (第 2 步未清空是「剩下 N 张…」,用前缀匹配)。
    private func primaryButton(_ pass: Pass) -> XCUIElement {
        let app = appHelper.app
        let byID = app.buttons["ReviewFlowPrimary"]
        if byID.waitForExistence(timeout: 2.0), byID.isHittable {
            return byID
        }
        let zhPrefix = pass.suffix == "zh" ? "剩下" : (pass.suffix == "en" ? "Leave" : "残り")
        let byLabel = app.buttons.matching(
            NSPredicate(format: "label IN %@ OR label BEGINSWITH %@", pass.nextLabels, zhPrefix)
        ).firstMatch
        return byLabel
    }

    private func waitForPrimary(_ pass: Pass) -> Bool {
        primaryButton(pass).waitForExistence(timeout: 6.0)
    }

    private func tapPrimary(_ pass: Pass) throws {
        let button = primaryButton(pass)
        XCTAssertTrue(button.waitForExistence(timeout: 8.0), "[\(pass.suffix)] 主按钮应可点")
        tapElement(button)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// AX5 下 `.tap()` 可能触发 XCTest 的 AX 滚动动作并失败
    /// (kAXErrorCannotComplete);兜底顺序:可点直点 → 滚一屏再直点 →
    /// 元素中心坐标直点。
    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        swipeUp(appHelper.app)
        if element.isHittable {
            element.tap()
            return
        }
        let window = appHelper.app.windows.firstMatch
        let frame = element.frame
        window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
    }

    private func waitForHomeNeutral(timeout: TimeInterval = 12) -> Bool {
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

    private func capture(_ name: String, pass: Pass) {
        Thread.sleep(forTimeInterval: 0.3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        var suffix = "\(pass.suffix)-\(appearance)"
        if isAX { suffix += "-ax" }
        attachment.name = "\(name)__\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - 种子数据

    /// 种子总览(以「今天」为锚,任何一天跑都成立)。卡堆按停滞天数降序取
    /// 前 8——所以「卡堆 8 张」必须是**最老的 8 张**,批量候选(≥21 天)要
    /// 进尾部就得比卡堆第 8 名更年轻:
    /// - 上次置顶:P1 已完成(3 天前)、P2 未完成(45 天 = 卡堆第 1 张,带头像
    ///   chip 与语音原话);
    /// - 卡堆 8 张(24–45 天);
    /// - 批量出口候选 3 张(21–23 天,恰好排在卡堆之后);
    /// - 尾部「先不动」4 张(10–20 天);
    /// - 本周完成 12 条(8 条当天记当天完 → sameDay 判词 + 救火占比);
    /// - 更早完成 5 条(凑满洞察引擎 ≥15 样本);
    /// - 本来就在下周 2 条(第 4 步 preexisting 组);
    /// - 分类集中在 work(第 5 步领域提示问「工作」)。
    private func seedTodosJSON(for pass: Pass) throws -> String {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())

        func ts(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) throws -> Double {
            let date = try XCTUnwrap(
                calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: todayStart),
                "种子日期计算失败"
            )
            return date.timeIntervalSinceReferenceDate
        }

        var index = 0
        func item(
            _ title: String,
            category: String,
            createdDaysAgo: Int,
            isCompleted: Bool = false,
            completedDaysAgo: Int? = nil,
            completedHour: Int = 18,
            raw: String? = nil,
            due: Double? = nil
        ) throws -> String {
            index += 1
            var fields: [String] = [
                "\"id\":\"bbbb0000-0000-4000-8000-\(String(format: "%012d", index))\"",
                "\"title\":\"\(title)\"",
                "\"hasDueTime\":false",
                "\"priority\":\"normal\"",
                "\"category\":\"\(category)\"",
                "\"isCompleted\":\(isCompleted)",
                "\"createdAt\":\(String(format: "%.3f", try ts(-createdDaysAgo, 10)))",
                "\"needsAIProcessing\":false",
                "\"sortOrder\":\(index)",
                "\"extractionOutcome\":\"parsed\"",
                "\"source\":\"voice\"",
                "\"localeIdentifier\":\"\(pass.localeIdentifier)\"",
            ]
            if let due { fields.append("\"dueDate\":\(String(format: "%.3f", due))") }
            if let completedDaysAgo {
                fields.append("\"completedAt\":\(String(format: "%.3f", try ts(-completedDaysAgo, completedHour, 25)))")
            }
            if let raw { fields.append("\"rawTranscript\":\"\(raw)\"") }
            return "{" + fields.joined(separator: ",") + "}"
        }

        var objects: [String] = []

        // 今日:3 开放(统计条 3/5 + 首页有内容)+ 2 已完成(今天)。
        // 注意:P1/P2 必须保持 id 尾号 0001/0002(复盘种子的 pinnedIDs 引用),
        // 今日块放在 P2 之后追加。
        func appendTodayItems() throws {
            objects.append(try item(pass.deckTitles[3], category: "work",
                                    createdDaysAgo: 2, due: try ts(0, 18)))
            objects.append(try item(pass.tailTitles[2], category: "life",
                                    createdDaysAgo: 3, due: try ts(0, 9)))
            objects.append(try item(pass.completedTitles[0], category: "health",
                                    createdDaysAgo: 1, due: try ts(0, 14)))
            objects.append(try item(pass.completedTitles[2], category: "study",
                                    createdDaysAgo: 1, isCompleted: true, completedDaysAgo: 0, completedHour: 11))
            objects.append(try item(pass.completedTitles[3], category: "work",
                                    createdDaysAgo: 0, isCompleted: true, completedDaysAgo: 0, completedHour: 16))
        }

        // P1 上次置顶·已完成(3 天前完成)。
        objects.append(try item(pass.pinnedDone, category: "work", createdDaysAgo: 12,
                                isCompleted: true, completedDaysAgo: 3))
        // P2 上次置顶·未完成(45 天,停滞排序卡堆第 1 张——带头像 chip + 原话)。
        objects.append(try item(pass.pinnedOpen, category: "life", createdDaysAgo: 45,
                                raw: pass.pinnedOpenRaw))

        try appendTodayItems()

        // 卡堆其余 7 张(24–40 天,全部老于批量候选)。
        let deckAges = [40, 36, 33, 30, 28, 26, 24]
        let deckCategories = ["work", "health", "work", "finance", "work", "life", "finance"]
        for (offset, age) in deckAges.enumerated() {
            objects.append(try item(
                pass.deckTitles[offset + 1],
                category: deckCategories[offset],
                createdDaysAgo: age
            ))
        }

        // 批量出口候选(21–23 天:比卡堆第 8 名(24 天)年轻 → 落尾部)。
        let batchAges = [23, 22, 21]
        for (i, age) in batchAges.enumerated() {
            objects.append(try item(pass.batchTitles[i], category: ["other", "finance", "other"][i], createdDaysAgo: age))
        }
        // 尾部「先不动」4 张(10–20 天)。
        let tailAges = [20, 15, 11, 10]
        for (i, age) in tailAges.enumerated() {
            objects.append(try item(pass.tailTitles[i], category: ["other", "life", "other", "health"][i], createdDaysAgo: age))
        }

        // 本周完成 12 条(上次复盘 6 天前):8 条当天记当天完(sameDay + 救火),
        // 4 条隔几天完成(计划)。createdAt = 完成日当天或更早。
        for i in 0..<8 {
            let dayAgo = i % 5 + 1 // 1–5 天前完成
            objects.append(try item(
                pass.completedTitles[i % pass.completedTitles.count],
                category: ["work", "work", "life", "health", "work", "social", "study", "finance"][i],
                createdDaysAgo: dayAgo, isCompleted: true, completedDaysAgo: dayAgo,
                completedHour: [21, 10, 15, 9, 20, 11, 16, 22][i]
            ))
        }
        for i in 0..<4 {
            let dayAgo = i + 2
            objects.append(try item(
                pass.completedTitles[(i + 2) % pass.completedTitles.count],
                category: ["work", "life", "study", "social"][i],
                createdDaysAgo: dayAgo + 4, isCompleted: true, completedDaysAgo: dayAgo,
                completedHour: [14, 19, 10, 17][i]
            ))
        }
        // 更早完成 5 条(10–25 天前,补洞察样本到 17)。
        for i in 0..<5 {
            let dayAgo = 10 + i * 3
            objects.append(try item(
                pass.completedTitles[i % pass.completedTitles.count],
                category: ["work", "life", "health", "study", "finance"][i],
                createdDaysAgo: i < 2 ? dayAgo : dayAgo + 5,
                isCompleted: true, completedDaysAgo: dayAgo,
                completedHour: [9, 16, 11, 20, 15][i]
            ))
        }

        // 本来就在下周(下周一/周二):进第 4 步 preexisting 组,不进卡堆。
        let nextMonday = ReviewFlowV6ScreenshotUITests.nextMondayIntervalSinceReference()
        objects.append(try item(pass.nextWeekTitles[0], category: "work", createdDaysAgo: 4,
                                due: nextMonday + 10 * 3600))
        objects.append(try item(pass.nextWeekTitles[1], category: "work", createdDaysAgo: 4,
                                due: nextMonday + (24 + 11) * 3600))

        return "[" + objects.joined(separator: ",") + "]"
    }

    /// 历史会话:三期,最近一期(6 天前)带长笔记 + finalBacklogCount=20
    /// (地板 B 账本差「积压 20 → 17」);置顶 = P1+P2。
    private func seedReviewJSON(for pass: Pass) throws -> String {
        let calendar = Calendar.current
        func iso(_ daysAgo: Int, _ hour: Int) throws -> String {
            let date = try XCTUnwrap(
                calendar.date(byAdding: DateComponents(day: -daysAgo, hour: hour), to: Date()),
                "会话日期计算失败"
            )
            return ISO8601DateFormatter().string(from: date)
        }

        func session(id: String, daysAgo: Int, note: String, aiKept: Bool, ledgerJSON: String, topicsJSON: String? = nil) throws -> String {
            let completedAt = try iso(daysAgo, 21)
            let periodStart = try iso(daysAgo + 7, 21)
            var fields: [String] = [
                "\"id\":\"\(id)\"",
                "\"completedAt\":\"\(completedAt)\"",
                "\"periodStart\":\"\(periodStart)\"",
                "\"periodEnd\":\"\(completedAt)\"",
                "\"voiceNote\":\"\(note)\"",
                "\"voiceNoteIsUneditedAIDraft\":\(aiKept)",
                "\"completedCount\":12",
                "\"ledger\":\(ledgerJSON)",
                "\"shownInsights\":[]",
            ]
            if let topicsJSON { fields.append("\"topics\":\(topicsJSON)") }
            return "{" + fields.joined(separator: ",") + "}"
        }

        let ledgerOld = """
        {"inputCount":5,"backlogCount":21,"finalBacklogCount":19,"remainingCount":2,"scheduledCount":1,"todayCount":1,"abandonedCount":1,"splitCount":0,"pinnedCount":2,"somedayCount":0}
        """
        let ledgerLast = """
        {"inputCount":8,"backlogCount":23,"finalBacklogCount":23,"remainingCount":3,"scheduledCount":2,"todayCount":1,"abandonedCount":2,"splitCount":0,"pinnedCount":2,"somedayCount":0}
        """

        // 换行转义进 JSON 字符串。
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: "\\n")
        }

        let s1 = try session(
            id: "cccc0000-0000-4000-8000-000000000001",
            daysAgo: 20, note: escaped(pass.oldNotes[0]), aiKept: true, ledgerJSON: ledgerOld
        )
        let s2 = try session(
            id: "cccc0000-0000-4000-8000-000000000002",
            daysAgo: 13, note: escaped(pass.oldNotes[1]), aiKept: false, ledgerJSON: ledgerOld
        )
        let s3 = try session(
            id: "cccc0000-0000-4000-8000-000000000003",
            daysAgo: 6, note: escaped(pass.longNote), aiKept: false, ledgerJSON: ledgerLast,
            // 最新一条带语义对照关注点 → 第 5 步「本期 N 件(上期 5 件)」对照行。
            topicsJSON: """
            [{"text":"work","category":"work","timeBucket":null,"periodCount":5}]
            """
        )

        return """
        {"sessions":[\(s1),\(s2),\(s3)],"pinnedIDs":["bbbb0000-0000-4000-8000-000000000001","bbbb0000-0000-4000-8000-000000000002"]}
        """
    }

    /// 下一个周一的自然日 timeIntervalSinceReferenceDate(第 4 步 preexisting
    /// 种子的 dueDate 落点;用户日起点的抬升由 DayClock 兜,截图种子取整即可)。
    private static func nextMondayIntervalSinceReference() -> Double {
        let calendar = Calendar.current
        var components = DateComponents()
        components.weekday = 2
        let next = calendar.nextDate(
            after: Date(), matching: components, matchingPolicy: .nextTime
        ) ?? Date()
        return calendar.startOfDay(for: next).timeIntervalSinceReferenceDate
    }
}
