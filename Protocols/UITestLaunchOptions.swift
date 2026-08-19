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
    let scenario: String?
    let presetTodos: [TodoItemData]
    let presetTodosDecodeError: Error?

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

        scenario = arguments.first(where: { $0.hasPrefix("--scenario=") })
            .map { String($0.dropFirst("--scenario=".count)) }

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
