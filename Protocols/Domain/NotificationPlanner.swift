import Foundation

/// 一条待排程的本地通知（纯数据，供调度器直接构造 UNNotificationRequest）。
/// 统一表达一次性与重复触发：`repeats=false` 时 `dateComponents` 含年月日+时分；
/// `repeats=true` 时只含重复所需分量（{时分} / {weekday,时分} / {day,时分}）。
struct PlannedNotification: Equatable, Sendable {
    let identifier: String
    let todoID: UUID
    let dateComponents: DateComponents
    let repeats: Bool
    let title: String
    let body: String?
    /// 用于 64 上限截断排序；重复项用 now（优先保留），一次性用其触发时间。
    let sortKey: Date
}

/// 从待办列表算出"应存在的通知集合"的纯函数。
/// 只提醒**带明确钟点、未完成**的待办：
/// - 非规律：一次性通知（仅未来）。
/// - 规律无结束日：重复触发器（每天/每周各 weekday/每月）。
/// - 规律有结束日：展开成到 endDate 的一次性 occurrence（重复触发器无法表达结束）。
/// 结果对重复项全保留、一次性按时间补齐至 limit。
enum NotificationPlanner {
    static let identifierPrefix = "todo-reminder-"

    /// App 级"到点提醒"总开关的 UserDefaults 键（默认 ON）。
    static let enabledDefaultsKey = "todoNotificationsEnabled"

    /// 有界规律展开时每条待办的 occurrence 上限，防止极端区间爆量。
    static let boundedExpansionCap = 30

    static func plannedNotifications(
        from todos: [TodoItemData],
        now: Date,
        calendar: Calendar = .current,
        limit: Int = 60,
        enabled: Bool = true
    ) -> [PlannedNotification] {
        // 总开关关闭：产出空集合，交由 reconcile 清空已排通知。
        guard enabled else { return [] }
        var repeating: [PlannedNotification] = []
        var oneShots: [PlannedNotification] = []

        for todo in todos {
            guard !todo.isCompleted, todo.hasDueTime, let due = todo.dueDate else { continue }
            let hm = calendar.dateComponents([.hour, .minute], from: due)
            let body = trimmedBody(todo.detail)
            let base = "\(identifierPrefix)\(todo.id.uuidString)"

            guard let rule = todo.recurrenceRule, rule.isValid else {
                // 非规律：一次性，仅未来。
                guard due > now else { continue }
                var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                comps.second = 0
                oneShots.append(PlannedNotification(
                    identifier: base, todoID: todo.id, dateComponents: comps,
                    repeats: false, title: todo.title, body: body, sortKey: due
                ))
                continue
            }

            if rule.endDate == nil {
                // 无界规律 → 重复触发器。
                repeating.append(contentsOf: repeatingNotifications(
                    rule: rule, hm: hm, base: base, todoID: todo.id, title: todo.title, body: body, now: now
                ))
            } else {
                // 有界规律 → 展开一次性到 endDate。
                oneShots.append(contentsOf: expandedNotifications(
                    rule: rule, due: due, hm: hm, base: base, todoID: todo.id,
                    title: todo.title, body: body, now: now, calendar: calendar
                ))
            }
        }

        // 重复项全保留（少而高价值）；一次性按触发时间升序补齐剩余额度。
        oneShots.sort { $0.sortKey < $1.sortKey }
        let remaining = max(0, limit - repeating.count)
        return repeating + oneShots.prefix(remaining)
    }

    // MARK: - Helpers

    private static func trimmedBody(_ detail: String?) -> String? {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func repeatingNotifications(
        rule: RecurrenceRule, hm: DateComponents, base: String, todoID: UUID,
        title: String, body: String?, now: Date
    ) -> [PlannedNotification] {
        switch rule.frequency {
        case .daily:
            var comps = DateComponents()
            comps.hour = hm.hour
            comps.minute = hm.minute
            return [PlannedNotification(
                identifier: base, todoID: todoID, dateComponents: comps,
                repeats: true, title: title, body: body, sortKey: now
            )]
        case .weekly:
            return rule.weekdays.map { weekday in
                var comps = DateComponents()
                comps.weekday = weekday
                comps.hour = hm.hour
                comps.minute = hm.minute
                return PlannedNotification(
                    identifier: "\(base)-w\(weekday)", todoID: todoID, dateComponents: comps,
                    repeats: true, title: title, body: body, sortKey: now
                )
            }
        case .monthly:
            guard let day = rule.dayOfMonth else { return [] }
            var comps = DateComponents()
            comps.day = day
            comps.hour = hm.hour
            comps.minute = hm.minute
            return [PlannedNotification(
                identifier: "\(base)-m\(day)", todoID: todoID, dateComponents: comps,
                repeats: true, title: title, body: body, sortKey: now
            )]
        }
    }

    private static func expandedNotifications(
        rule: RecurrenceRule, due: Date, hm: DateComponents, base: String, todoID: UUID,
        title: String, body: String?, now: Date, calendar: Calendar
    ) -> [PlannedNotification] {
        guard let endDate = rule.endDate else { return [] }
        let endDay = calendar.startOfDay(for: endDate)
        var day = max(calendar.startOfDay(for: now), calendar.startOfDay(for: due))
        var result: [PlannedNotification] = []
        let idFormatter = Self.dayIDFormatter

        while day <= endDay && result.count < boundedExpansionCap {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? endDay.addingTimeInterval(86_400)
            }
            guard rule.occurs(on: day, startDate: due, calendar: calendar) else { continue }
            guard let fireDate = calendar.date(
                bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day
            ), fireDate > now else { continue }

            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            comps.second = 0
            result.append(PlannedNotification(
                identifier: "\(base)-d\(idFormatter.string(from: day))",
                todoID: todoID, dateComponents: comps, repeats: false,
                title: title, body: body, sortKey: fireDate
            ))
        }
        return result
    }

    private static let dayIDFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
