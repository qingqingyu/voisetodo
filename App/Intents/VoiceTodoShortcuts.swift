import AppIntents

/// 注册 Siri 快捷指令短语。
///
/// 本地化:代码里只写开发语言(en)的短语;中文 / 日文短语在
/// `Resources/AppShortcuts.xcstrings`。中文短语若直接写在这里,会被系统当成英文
/// 环境的短语,中文 Siri 一条也匹配不到(表现为「不认识这个 App」)。
/// 改短语时两边同步:xcstrings 的 key 是每个 AppShortcut 的**第一条**英文短语。
/// App 名的中文别名见 Info.plist 的 `INAlternativeAppNames`。
///
/// 每个 AppShortcut 的 phrases 规则:
/// - `\(.applicationName)` → 系统 placeholder,自动替换为 App 显示名
/// - `\(\.$paramName)` → 必须**仅用于 AppEntity / AppEnum 参数**(Apple 平台限制)
///   String 参数不能放进 phrase(参见下方 AddTodoIntent 的 transcript 注释)
/// - 有默认值的参数(如 QueryTodosIntent.status)可不写进 phrase —— Siri 用默认值调用
struct VoiceTodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 开始录音 —— 无参数 + openAppWhenRun,专供 Action Button / 锁屏 / 控制中心。
        // 放在第一位:Action Button 设置页按 provider 顺序列出 App 快捷指令,
        // 排在 AddTodoIntent 前面可避免用户误选那个会弹文本框的。
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.record.title",
            systemImageName: "mic.fill"
        )

        // 记录待办 —— 接收 transcript 字符串,不能用 $(param) placeholder,
        // 用户说"用 VoiceTodo 记录"后 Siri 通过 dialog 追问内容。
        // 注意:这个 intent 有必填 String 参数,从 Action Button 触发会弹键盘输入框
        // (非语音会话拿不到参数值)。想「一按就录音」请用上面的 StartRecordingIntent。
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "Add todo in \(.applicationName)",
                "Record in \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.title",
            systemImageName: "checklist"
        )

        // 完成待办 —— `$todo` 是 TodoEntity,Siri 会通过自然语言解析("完成 [买菜]")。
        AppShortcut(
            intent: CompleteTodoIntent(),
            phrases: [
                "Complete \(\.$todo) in \(.applicationName)",
                "Mark \(\.$todo) as done in \(.applicationName)"
            ],
            shortTitle: "siri.shortcut.complete.title",
            systemImageName: "checkmark.circle"
        )

        // 删除待办 —— 同样依赖 TodoEntity 自然语言解析。
        AppShortcut(
            intent: DeleteTodoIntent(),
            phrases: [
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
                "Show \(.applicationName) todos",
                "What's on my \(.applicationName) list"
            ],
            shortTitle: "siri.shortcut.query.title",
            systemImageName: "list.bullet"
        )
    }
}
