import AppIntents

/// 注册 Siri 快捷指令短语
/// 让 Siri 能识别"用 VoiceTodo 记录..."等语音指令
struct VoiceTodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "用 \(.applicationName) 记录 \(\.$transcript)",
                "在 \(.applicationName) 添加待办 \(\.$transcript)",
                "Record \(\.$transcript) in \(.applicationName)",
                "Add todo \(\.$transcript) in \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.title",
            systemImageName: "checklist"
        )
    }
}
