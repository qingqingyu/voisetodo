import Foundation

/// 把待办的"时间相关结构化字段"合成成一行用户可读的时间串。
///
/// 解决的问题：HomeView 与 ConfirmSheet 各自实现了一份 `composedTimeText`，
/// 因数据源不同（`ExtractedTodo.dueTime: String?` vs `TodoItemData.dueDate+hasDueTime`）
/// 而出现行为偏差。这里抽出"给定 recurrence + 钟点串 + 自由文本兜底，怎么拼"的纯展示逻辑，
/// 让两个调用方各自负责"怎么把模型字段转成钟点串"，拼装规则只此一处。
///
/// 规则（与 ConfirmSheet `TodoItemRow` 原 review 决策保持一致）：
/// 1. 优先用结构化字段（recurrence.displayTextWithEndDate + 钟点）拼成
///    "每天 · 至 8月5日 · 15:00"。
/// 2. 结构化字段全空时退回 `dueHint` 原文（AI 自由文本，例如"明天下午3点"）。
/// 3. 再空则返回 nil（调用方不渲染）。
///
/// 冗余权衡（沿用 TodoItemRow 注释）：当结构化字段存在时丢弃 dueHint 原文，
/// 避免出现 "每天 · 至 8月5日 · 15:00 · 每天下午3点至8月5日" 这样的冗余串。
enum TodoTimeDisplayComposer {
    /// 把结构化时间字段拼成单行展示串。
    ///
    /// - Parameters:
    ///   - recurrenceRule: 重复规则；非 nil 时贡献 `displayTextWithEndDate`（已含结束日期）。
    ///   - timeText: 已格式化好的钟点串（"HH:mm"），传 nil 表示无明确钟点。
    ///   - dueHint: AI 自由文本兜底；仅在前两者全空时使用。
    /// - Returns: 拼好的展示串；输入全空时返回 nil。
    static func compose(
        recurrenceRule: RecurrenceRule?,
        timeText: String?,
        dueHint: String?
    ) -> String? {
        var parts: [String] = []
        if let rule = recurrenceRule {
            parts.append(rule.displayTextWithEndDate)
        }
        if let time = timeText?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty {
            parts.append(time)
        }
        if parts.isEmpty {
            if let hint = dueHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                return hint
            }
            return nil
        }
        return parts.joined(separator: " · ")
    }
}
