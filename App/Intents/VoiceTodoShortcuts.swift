import AppIntents

/// 注册 Siri 快捷指令短语
/// 让 Siri 能识别"用 VoiceTodo 记录..."等语音指令。
///
/// 注意：Apple 平台限制——AppShortcut phrases 里的 `\(...)` 占位符只能引用
/// AppEntity/AppEnum 类型的参数。AddTodoIntent.transcript 是 String，不能直接放占位符。
/// 因此 phrase 不带 transcript 占位；用户说"用 VoiceTodo 记录"后 Siri 通过
/// AddTodoIntent.perform 的 dialog 询问要记录什么。
struct VoiceTodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "用 \(.applicationName) 记录",
                "在 \(.applicationName) 添加待办",
                "Record in \(.applicationName)",
                "Add todo in \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.title",
            systemImageName: "checklist"
        )
    }
}
