import Foundation

struct UITestLaunchOptions {
    let isUITesting: Bool
    let skipOnboarding: Bool
    let resetUserData: Bool
    let forceOffline: Bool
    let micPermissionDenied: Bool
    let speechPermissionDenied: Bool
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
        case "no-todo":
            return "最近好累，什么都不想干"
        case "urgent-single":
            return "必须今天交报告"
        default:
            return "明天去银行"
        }
    }
}
