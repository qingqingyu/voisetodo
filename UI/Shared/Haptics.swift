import UIKit

/// 集中管理 haptic 反馈。避免各处直接 new feedback generator 散落调用。
///
/// 用法:`HapticFeedback.selection()` / `HapticFeedback.success()` 等。
/// 每次调用都 new 一个 generator —— Apple 文档建议只在要触发时才 prepare/trigger,
/// 避免长生命周期 generator 持有造成电量损耗(本类型只在用户交互瞬间调用,无此问题)。
enum HapticFeedback {
    /// 轻量选择反馈。用于 hover / 高亮变化 / picker 切换。
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 成功反馈。用于任务落位 / 保存成功 / 操作完成。
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 警告反馈。用于操作失败 / 输入校验未过。
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 错误反馈。用于严重失败。
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// 轻撞击反馈。用于 button tap / 微交互确认。
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 中等撞击反馈。用于较重的交互(如卡片落位前的预提示)。
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
