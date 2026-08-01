import Foundation

/// 把 `ExternalCalendarEvent` 转 `TodoItemData`(source = .calendarImport)。
/// 对称于 `SystemCalendarEventMapper`(后者把 TodoItemData → 待写入 EKEvent 草稿)。
///
/// 第一版本设计:
/// - **不**设 `systemCalendarEventIdentifier`——导入的 todo 不"拥有"日历事件,
///   删除 todo 时不应影响用户在系统日历的原始事件。
/// - 避免重复写入由 `source` 字段把关:`SystemCalendarWriter` 只对 `source == .voice`
///   的 todo 创建 EKEvent,导入的 todo 不会被二次同步。
enum SystemCalendarEventImporter {
    /// 把单个日历事件转 TodoItemData。
    /// - Parameters:
    ///   - event: 系统日历事件 DTO
    ///   - calendar: 用于日期归一化的日历(默认 .current)
    /// - Returns: 待办 DTO;nil 表示事件缺关键字段(如空标题),应跳过
    static func todo(from event: ExternalCalendarEvent, calendar: Calendar = .current) -> TodoItemData? {
        let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let dueDate: Date
        let hasDueTime: Bool
        if event.isAllDay {
            // 全天事件:用事件所在日的 00:00 作为 dueDate,hasDueTime=false。
            dueDate = calendar.startOfDay(for: event.startDate)
            hasDueTime = false
        } else {
            // 定时事件:用事件开始时间作为 dueDate,hasDueTime=true。
            dueDate = event.startDate
            hasDueTime = true
        }

        return TodoItemData(
            title: trimmedTitle,
            detail: nil,
            dueDate: dueDate,
            hasDueTime: hasDueTime,
            priority: .normal,
            category: .other,
            isCompleted: false,
            createdAt: Date(),
            needsAIProcessing: false,
            source: .calendarImport
            // systemCalendarEventIdentifier 不设——见类型注释。
        )
    }
}
