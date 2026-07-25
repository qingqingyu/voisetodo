import Foundation

/// Todo 日期平移工具。
///
/// 把"移到明天"的日期计算抽出来,便于单测覆盖相对日期场景(选中日 ≠ 真实今天)。
///
/// 设计语义(2026-07-25 修复):
/// "明天"相对 `baseDate`,**不是相对 `Date()`**。baseDate 由调用方传入,
/// 通常是 HomeView.selectedDate(用户当前在看的那一天)。
/// 之前在 `moveTodoToTomorrow` 里硬用 `Date()` 导致 calendar tab 选非今天时
/// "移到明天"违背用户心智(选中 24 号时移到明天会变成移到真实今天+1)。
enum TodoDueDateShifter {
    /// 计算 baseDate 的下一天,保留原 dueDate 的钟点分量。
    ///
    /// - Parameters:
    ///   - baseDate: 平移基准日。语义上的"今天"——通常是用户当前选中的日期。
    ///   - originalDue: 任务原 dueDate。用于提取钟点分量;nil 时视为 00:00
    ///   - hasDueTime: true=把原钟点拼到明天;false=钟点清零(明天 00:00)
    ///   - calendar: 日历(时区/DST 处理由它决定)
    /// - Returns: 平移后的 Date。理论上 `calendar.date(byAdding:.day, value:1)` 不会返回 nil,
    ///   但兜底 fallback 到 originalDue ?? baseDay 保证永远有返回值(不静默吞错误,
    ///   但用户预期「明天」会得到一个合理的 fallback)。
    ///
    /// **DST 边界**:`bySettingHour` 在春令时跳变日凌晨 2:00→3:00 时若原钟点是 2:30
    /// 会返回 nil,fallback 到 tomorrow(00:00)。一年 1-2 次,符合用户预期妥协。
    static func nextDay(
        baseDate: Date,
        originalDue: Date?,
        hasDueTime: Bool,
        calendar: Calendar = .current
    ) -> Date {
        let baseDay = DayClock.startOfUserDay(for: baseDate, calendar: calendar)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: baseDay) else {
            // 理论兜底:Gregorian calendar 在合理输入下不会到这里。
            // 真到了,fallback 到 originalDue(不动任务)比返回 baseDay(昨天)更安全。
            return originalDue ?? baseDay
        }
        guard hasDueTime, let originalDue else {
            // 无钟点:明天 00:00(startOfUserDay 已经把钟点清零了)
            return tomorrow
        }
        // 有钟点:把原 hour/minute 拼到明天上
        return calendar.date(
            bySettingHour: calendar.component(.hour, from: originalDue),
            minute: calendar.component(.minute, from: originalDue),
            second: 0,
            of: tomorrow
        ) ?? tomorrow  // DST fallback
    }
}
