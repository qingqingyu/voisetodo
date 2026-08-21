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
///
/// 提前提醒：`reminderOffsetMinutes`(1...1440) 把触发锚点前移 offset 分钟，nil = 准时。
/// 重复触发器的日期分量按偏移修正：weekly 跨日回退 weekday、monthly 跨日用偏移后 day；
/// 唯一表达不了的 corner case——每月 1 号提前跨到上月末(28/29/30/31 随月变化)——
/// 钳制为当天 00:00 触发(保守方向:宁可稍晚,不提前错过)。
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
            // 已划掉(abandonedAt != nil)的任务不再排提醒——用户已决定不做。
            guard !todo.isCompleted, todo.abandonedAt == nil, todo.hasDueTime, let due = todo.dueDate else { continue }
            // 提前提醒:防御性钳 0...1440(越界脏值按准时处理)。fireAnchor = 实际触发时刻。
            let offset = min(max(todo.reminderOffsetMinutes ?? 0, 0), ReminderOffsetConfig.maxMinutes)
            let fireAnchor = offset > 0
                ? calendar.date(byAdding: .minute, value: -offset, to: due) ?? due
                : due
            // 偏移跨过的日界数(offset ≤ 1440 ⇒ 0 或 1),weekly/monthly 重复触发器按它修正日期分量。
            // ⚠️ 必须 startOfDay 后再差:直接对 fireAnchor→due 取 .day 分量差,30 分钟跨午夜会算出 0。
            let crossedDays = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: fireAnchor),
                to: calendar.startOfDay(for: due)
            ).day ?? 0
            // hm 一律取偏移后的时分(= 实际触发时刻的时分);expandedNotifications 另行按事件时分减偏移。
            let hm = calendar.dateComponents([.hour, .minute], from: fireAnchor)
            let body = bodyWithAdvancePrefix(offsetMinutes: offset, detail: todo.detail)
            let base = "\(identifierPrefix)\(todo.id.uuidString)"

            guard let rule = todo.recurrenceRule, rule.isValid else {
                // 非规律：一次性，仅未来(以偏移后的触发时刻判断,已过期的提前提醒不再补发)。
                guard fireAnchor > now else { continue }
                var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAnchor)
                comps.second = 0
                oneShots.append(PlannedNotification(
                    identifier: base, todoID: todo.id, dateComponents: comps,
                    repeats: false, title: todo.title, body: body, sortKey: fireAnchor
                ))
                continue
            }

            if rule.endDate == nil {
                // 无界规律 → 重复触发器(hm 已是偏移后时分,日期分量在 helper 里修正)。
                repeating.append(contentsOf: repeatingNotifications(
                    rule: rule, hm: hm, crossedDays: crossedDays,
                    base: base, todoID: todo.id, title: todo.title, body: body, now: now
                ))
            } else {
                // 有界规律 → 展开一次性到 endDate(每个 occurrence 各自减偏移)。
                oneShots.append(contentsOf: expandedNotifications(
                    rule: rule, due: due, hm: calendar.dateComponents([.hour, .minute], from: due),
                    offsetMinutes: offset, base: base, todoID: todo.id,
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

    /// 提前提醒时通知 body 拼本地化前缀("30 分钟后 · 备注原文");无备注时只显示前缀。
    /// 准时(offset == 0)保持原行为:body = 备注,无备注则 nil。
    private static func bodyWithAdvancePrefix(offsetMinutes: Int, detail: String?) -> String? {
        let trimmed = trimmedBody(detail)
        guard offsetMinutes > 0 else { return trimmed }
        let prefix: String
        if offsetMinutes >= ReminderOffsetConfig.maxMinutes {
            prefix = String(localized: "notification.advance.day")
        } else if offsetMinutes == 60 {
            prefix = String(localized: "notification.advance.hour")
        } else {
            prefix = String.localizedStringWithFormat(
                String(localized: "notification.advance.minutes"), offsetMinutes
            )
        }
        return trimmed.map { "\(prefix) · \($0)" } ?? prefix
    }

    private static func repeatingNotifications(
        rule: RecurrenceRule, hm: DateComponents, crossedDays: Int,
        base: String, todoID: UUID,
        title: String, body: String?, now: Date
    ) -> [PlannedNotification] {
        switch rule.frequency {
        case .daily:
            // 每日重复:只用时分,跨午夜天然成立(00:15 提前 30 → 每天 23:45)。
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
                // 触发 weekday = 发生 weekday 回退 crossedDays 天(7 取模防负)。
                // 周一 00:15 提前 30 分钟 → 周日 23:45 触发。
                comps.weekday = ((weekday - 1 - crossedDays) % 7 + 7) % 7 + 1
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
            var fireHM = hm
            if day - crossedDays >= 1 {
                // 跨日但仍在当月(如 5 号提前 1 天 → 4 号),day 确定性回退。
                comps.day = day - crossedDays
            } else {
                // 每月 1 号提前跨到上月末(28/29/30/31 随月变化,重复触发器表达不了)
                // → 钳制为当天 00:00 触发。保守方向:宁可稍晚,不提前错过。
                comps.day = day
                fireHM = DateComponents(hour: 0, minute: 0)
            }
            comps.hour = fireHM.hour
            comps.minute = fireHM.minute
            return [PlannedNotification(
                identifier: "\(base)-m\(day)", todoID: todoID, dateComponents: comps,
                repeats: true, title: title, body: body, sortKey: now
            )]
        }
    }

    private static func expandedNotifications(
        rule: RecurrenceRule, due: Date, hm: DateComponents, offsetMinutes: Int,
        base: String, todoID: UUID,
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
            // 先还原 occurrence 的发生时刻(hm = 事件时分),再减偏移得触发时刻。
            // 跨日偏移(如 00:15 提前 30)会自然落到前一天 23:45,一次性通知含完整日期无表达问题。
            guard let occurrenceDate = calendar.date(
                bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day
            ) else { continue }
            let fireDate = offsetMinutes > 0
                ? calendar.date(byAdding: .minute, value: -offsetMinutes, to: occurrenceDate) ?? occurrenceDate
                : occurrenceDate
            guard fireDate > now else { continue }

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
