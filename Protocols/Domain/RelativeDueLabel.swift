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
    static func status(
        dueDate: Date?,
        isCompleted: Bool,
        recurrenceRule: RecurrenceRule?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodoDueStatus? {
        guard let dueDate, !isCompleted, recurrenceRule == nil else {
            return nil
        }

        let dueDay = calendar.startOfDay(for: dueDate)
        let today = calendar.startOfDay(for: now)

        if dueDay < today {
            return .overdue
        }
        if calendar.isDate(dueDay, inSameDayAs: today) {
            return .today
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(dueDay, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .future(dueDay)
    }
}
