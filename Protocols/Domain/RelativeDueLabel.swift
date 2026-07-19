import Foundation

/// 待办截止日期在列表中的语义状态。
///
/// 该类型不承载本地化文字或颜色，确保日期判定可在 Protocols 单测中稳定验证。
enum TodoDueStatus: Equatable {
    case overdue
    case today
    case tomorrow
    case future(Date)
}

/// 根据待办状态生成轻量的截止日期语义。
enum RelativeDueLabel {
    /// 返回普通待办的截止日期状态；已完成和重复待办不显示截止状态。
    ///
    /// `hasDueTime=true` 时按"具体时刻"判过期：今天 12:00 的任务在 12:00 之后即算 `.overdue`
    /// （不再等到跨天）。无钟点的任务（含"时段⇒今天"落的模糊时段任务）仍按天判定，不误标过期。
    static func status(
        dueDate: Date?,
        isCompleted: Bool,
        recurrenceRule: RecurrenceRule?,
        hasDueTime: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodoDueStatus? {
        guard let dueDate, !isCompleted, recurrenceRule == nil else {
            return nil
        }

        // 带钟点且具体时刻已过 → 过期（哪怕就是今天）。
        if hasDueTime, dueDate < now {
            return .overdue
        }

        let dueDay = DayClock.startOfUserDay(for: dueDate, calendar: calendar)
        let today = DayClock.startOfUserDay(for: now, calendar: calendar)

        if dueDay < today {
            return .overdue
        }
        if DayClock.isSameUserDay(dueDay, today, calendar: calendar) {
            return .today
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           DayClock.isSameUserDay(dueDay, tomorrow, calendar: calendar) {
            return .tomorrow
        }
        return .future(dueDay)
    }
}
