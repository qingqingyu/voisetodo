import AppIntents

/// 注册 Siri 快捷指令短语。
///
/// 每个 AppShortcut 的 phrases 规则:
/// - `\(.applicationName)` → 系统 placeholder,自动替换为 App 显示名
/// - `\(\.$paramName)` → 必须**仅用于 AppEntity / AppEnum 参数**(Apple 平台限制)
///   String 参数不能放进 phrase(参见下方 AddTodoIntent 的 transcript 注释)
/// - 有默认值的参数(如 QueryTodosIntent.status)可不写进 phrase —— Siri 用默认值调用
struct VoiceTodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 记录待办 —— 接收 transcript 字符串,不能用 $(param) placeholder,
        // 用户说"用 VoiceTodo 记录"后 Siri 通过 dialog 追问内容。
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

        // 完成待办 —— `$todo` 是 TodoEntity,Siri 会通过自然语言解析("完成 [买菜]")。
        AppShortcut(
            intent: CompleteTodoIntent(),
            phrases: [
                "在 \(.applicationName) 完成 \(\.$todo)",
                "用 \(.applicationName) 标记 \(\.$todo) 已完成",
                "Mark \(\.$todo) as done in \(.applicationName)",
                "Complete \(\.$todo) in \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.complete.title",
            systemImageName: "checkmark.circle"
        )

        // 删除待办 —— 同样依赖 TodoEntity 自然语言解析。
        AppShortcut(
            intent: DeleteTodoIntent(),
            phrases: [
                "在 \(.applicationName) 删除 \(\.$todo)",
                "用 \(.applicationName) 移除 \(\.$todo)",
                "Delete \(\.$todo) in \(.applicationName)",
                "Remove \(\.$todo) from \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.delete.title",
            systemImageName: "trash"
        )

        // 查询待办 —— status 有默认值 .incomplete,phrase 不带参数时 Siri 走默认。
        AppShortcut(
            intent: QueryTodosIntent(),
            phrases: [
                "在 \(.applicationName) 查询待办",
                "\(.applicationName) 我的待办",
                "What's on my \(.applicationName) list",
                "Show \(.applicationName) todos"
            ],
            shortTitle: "siri.shortcut.query.title",
            systemImageName: "list.bullet"
        )
    }
}
