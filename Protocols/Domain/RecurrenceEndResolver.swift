import Foundation

/// 把归一化的 `RecurrenceEnd` + 今天/起始日，**确定性**算成精确的截止日期（重复规则的 endDate）。
/// 全部是日历运算，不依赖大模型算日期。
enum RecurrenceEndResolver {
    static func resolve(
        _ end: RecurrenceEnd?,
        start: Date,
        today: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let end else { return nil }
        let startDay = calendar.startOfDay(for: start)
        let todayDay = calendar.startOfDay(for: today)

        let resolved: Date?
        switch end {
        case let .afterCount(count, unit):
            switch unit {
            case .day:
                resolved = calendar.date(byAdding: .day, value: count - 1, to: startDay)
            case .week:
                resolved = calendar.date(byAdding: .day, value: count * 7 - 1, to: startDay)
            case .month:
                // "未来一个月" = 起始日 + count 个月（落在同一日号），与既有 few-shot 约定一致。
                resolved = calendar.date(byAdding: .month, value: count, to: startDay)
            }
        case let .weekday(weekday, scope):
            resolved = upcomingWeekday(weekday, scope: scope, today: todayDay, calendar: calendar)
        case let .monthEnd(scope):
            resolved = monthEnd(scope: scope, today: todayDay, calendar: calendar)
        case let .dayOfMonth(day, scope):
            resolved = dayOfMonth(day, scope: scope, today: todayDay, calendar: calendar)
        case let .date(value):
            resolved = parseISODate(value, calendar: calendar)
        }

        guard let resolved else { return nil }
        let endDay = calendar.startOfDay(for: resolved)
        // 截止早于起始 = 无效边界（避免生成空规则）。
        return endDay >= startDay ? endDay : nil
    }

    // MARK: - Helpers

    /// 即将到来的该 weekday（scope=this 取最近的、含今天；next 再 +7）。
    private static func upcomingWeekday(
        _ weekday: Int, scope: RecurrenceEnd.Scope, today: Date, calendar: Calendar
    ) -> Date? {
        let current = calendar.component(.weekday, from: today)
        let daysUntil = (weekday - current + 7) % 7 // 0…6，0=今天
        let offset = daysUntil + (scope == .next ? 7 : 0)
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    /// 本/下月最后一天。
    private static func monthEnd(
        scope: RecurrenceEnd.Scope, today: Date, calendar: Calendar
    ) -> Date? {
        guard let first = firstOfMonth(scope: scope, today: today, calendar: calendar),
              let range = calendar.range(of: .day, in: .month, for: first) else {
            return nil
        }
        return calendar.date(byAdding: .day, value: range.count - 1, to: first)
    }

    /// 本/下月的第 day 天（按当月天数 clamp）。
    private static func dayOfMonth(
        _ day: Int, scope: RecurrenceEnd.Scope, today: Date, calendar: Calendar
    ) -> Date? {
        guard let first = firstOfMonth(scope: scope, today: today, calendar: calendar),
              let range = calendar.range(of: .day, in: .month, for: first) else {
            return nil
        }
        let clamped = min(max(day, 1), range.count)
        return calendar.date(byAdding: .day, value: clamped - 1, to: first)
    }

    /// 本月（this）或下月（next）的 1 号 startOfDay。
    private static func firstOfMonth(
        scope: RecurrenceEnd.Scope, today: Date, calendar: Calendar
    ) -> Date? {
        let base: Date
        if scope == .next {
            guard let next = calendar.date(byAdding: .month, value: 1, to: today) else { return nil }
            base = next
        } else {
            base = today
        }
        return calendar.date(from: calendar.dateComponents([.year, .month], from: base))
    }

    private static func parseISODate(_ raw: String, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
