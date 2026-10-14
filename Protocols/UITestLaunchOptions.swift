import Foundation

struct UITestLaunchOptions {
    let isUITesting: Bool
    let skipOnboarding: Bool
    let resetUserData: Bool
    let forceOffline: Bool
    let micPermissionDenied: Bool
    let speechPermissionDenied: Bool
    let calendarPermissionDenied: Bool
    let enableAccessibilityIdentifiers: Bool
    /// UI 测试默认抑制「首次带日期待办后的一次性日历询问」(防既有场景断言被弹层打断);
    /// 传 `--calendar-ask` 显式开启以专测该流程。
    let calendarAskEnabled: Bool
    let scenario: String?
    let presetTodos: [TodoItemData]
    let presetTodosDecodeError: Error?
    /// 复盘截图套件(v6)的会话/置顶种子(`--preset-review-data=<json>`,
    /// shape 见 `UITestReviewSeed`)。解码失败与 todos-data 同口径:显式记错,
    /// app 启动 fatalError(UI 测试种子的 schema 漂移不允许静默空库)。
    let presetReviewData: UITestReviewSeed?
    let presetReviewDataDecodeError: Error?

    static let current = UITestLaunchOptions()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isUITesting = arguments.contains("--ui-testing")
        skipOnboarding = arguments.contains("--skip-onboarding")
        resetUserData = arguments.contains("--reset-user-data")
        forceOffline = arguments.contains("--network-off")
        micPermissionDenied = arguments.contains("--mic-permission-denied")
        speechPermissionDenied = arguments.contains("--speech-permission-denied")
        calendarPermissionDenied = arguments.contains("--calendar-permission-denied")
        enableAccessibilityIdentifiers = arguments.contains("--enable-accessibility-identifiers")
        calendarAskEnabled = arguments.contains("--calendar-ask")

        scenario = arguments.first(where: { $0.hasPrefix("--scenario=") })
            .map { String($0.dropFirst("--scenario=".count)) }

        if let reviewArgument = arguments.first(where: { $0.hasPrefix("--preset-review-data=") }) {
            let json = String(reviewArgument.dropFirst("--preset-review-data=".count))
            if let data = json.data(using: .utf8) {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    presetReviewData = try decoder.decode(UITestReviewSeed.self, from: data)
                    presetReviewDataDecodeError = nil
                } catch {
                    presetReviewData = nil
                    presetReviewDataDecodeError = error
                }
            } else {
                presetReviewData = nil
                presetReviewDataDecodeError = VoiceTodoError.apiResponseInvalid("Invalid --preset-review-data UTF-8")
            }
        } else {
            presetReviewData = nil
            presetReviewDataDecodeError = nil
        }

        let presetTodosRequested = arguments.contains("--preset-todos")
        if let todosArgument = arguments.first(where: { $0.hasPrefix("--todos-data=") }) {
            let json = String(todosArgument.dropFirst("--todos-data=".count))
            guard let data = json.data(using: .utf8) else {
                presetTodos = []
                presetTodosDecodeError = VoiceTodoError.apiResponseInvalid("Invalid --todos-data UTF-8")
                return
            }
            do {
                let decoded = try JSONDecoder().decode([TodoItemData].self, from: data)
                presetTodos = decoded
                presetTodosDecodeError = nil
            } catch {
                presetTodos = []
                presetTodosDecodeError = error
            }
        } else {
            presetTodos = []
            presetTodosDecodeError = presetTodosRequested
                ? VoiceTodoError.apiResponseInvalid("Missing --todos-data for --preset-todos")
                : nil
        }
    }

    var mockTranscript: String {
        switch scenario {
        case "multi-todo":
            return "明天去银行办卡，顺便买菜，晚上给老妈打电话"
        case "multi-todo-en":
            // App Store 截图套件(ScreenshotUITests)en 轮次的 mock 转写;
            // 配套 UITestTodoExtractor 的 bank/groceries/mom 分支。
            return "Go to the bank tomorrow, buy some groceries, and call mom tonight"
        case "streaming-partial":
            return "先生成第一条待办，再继续生成第二条待办"
        case "no-todo":
            return "最近好累，什么都不想干"
        case "urgent-single":
            return "必须今天交报告"
        case "today-single":
            // G2(S18a):落今天的单条——庆祝 toast 走 first_trial 分支(点名「今天」)。
            // 注意配套 UITestTodoExtractor 的「今晚八点」分支:mock 抽取器兜底分支
            // 恒给 dueHint nil(无日期),单靠这条转写落不了今天。
            return "今晚八点给妈妈打电话"
        case "no-date-single":
            // G2(S18b):无日期单条——庆祝 toast 走 first_trial_generic 分支(不点名「今天」)。
            // 转写本身不得含任何时间词(今天/明天/今晚/周X/N天后),否则会被
            // TodoDueDateResolver 解析出日期,落错分支。
            return "记得给阳台的花浇水"
        default:
            return "明天去银行"
        }
    }
}

/// `--preset-review-data` 的载荷(v6 复盘截图套件):历史会话(升序追加)
/// + 上次置顶 id 集。会话 JSON 直接用 `ReviewSession` 的 Codable 形状
/// (iso8601 日期);置顶 id 必须指向同批 `--todos-data` 种子里的待办。
struct UITestReviewSeed: Decodable {
    let sessions: [ReviewSession]
    let pinnedIDs: [UUID]
}
