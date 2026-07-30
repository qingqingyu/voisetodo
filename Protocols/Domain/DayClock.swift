import Foundation

/// 用户自定义"一天起始时刻"工具。
///
/// 当用户把 `startHour` 设为非零值（例如 3），凌晨 0:00–2:59 仍算"昨天"，
/// 03:00 才进入新一天。适合晚睡、轮班、自由职业作息。
///
/// `startHour = 0` 时行为完全等于 `Calendar.startOfDay(for:)`——零回归。
///
/// **范围限制（路线 A）**：
/// 只影响"语义今天"边界（首页 selectedDate、回顾聚合、Widget 可见区间等）；
/// **不影响** `TodoOccurrenceCompletion` 存储归一化、`RecurrenceRule.occurs`
/// 判定、`SystemCalendarWriter` 写入、月历视觉锚点——这些仍走自然日。
enum DayClock {
    /// 共享 UserDefaults 键。主 App 写、Widget 读。
    static let startHourKey = "VoiceTodoDayStartHour"

    /// 强解包的 App Group 共享 UserDefaults。
    /// 直接用 `WidgetConfig.appGroupIdentifier` 避免依赖 Store/ 模块（SPM Protocols 包限制）。
    /// `@AppStorage(store:)` 需要非可选 `UserDefaults`；标识符是硬编码字符串，强解包安全。
    static let appGroupDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier) else {
            fatalError("App Group UserDefaults unavailable: \(WidgetConfig.appGroupIdentifier)")
        }
        return defaults
    }()

    /// 当前配置的一天起始小时（0–23）。读不到或非法时返回 0（零回归）。
    static var startHour: Int {
        let raw = appGroupDefaults.integer(forKey: startHourKey)
        return (0...23).contains(raw) ? raw : 0
    }

    /// 写入起始小时。主 App 专用。Widget 只读。
    /// 自动 clamp 到 0–23。
    static func setStartHour(_ hour: Int) {
        let clamped = max(0, min(23, hour))
        appGroupDefaults.set(clamped, forKey: startHourKey)
    }

    /// 把"自然日 day"映射到该自然日对应"用户日"的起点（day 的 00:00 + startHour）。
    ///
    /// 与 `startOfUserDay(for:)` 的区别：那个接收**时刻**并问"它属于哪个用户日"；
    /// 这个接收**已归一化的日**（自然日 0 点）并问"这一天作为用户日从几点开始"。
    /// 对一个 00:00 调 `startOfUserDay(for:)` 会掉到前一个用户日——那是 bug，不是本函数。
    ///
    /// 调用约定：传入的 `day` 应该是 `calendar.startOfDay(for: ...)` 之类的归一化值；
    /// 内部不再二次折算（不像 `startOfUserDay` 会判断"是否已进入用户日"）。
    ///
    /// `startHour = 0` 时等价于 `calendar.startOfDay(for: day)`——零回归。
    ///
    /// 用途：把"日历日"概念（`HomeView.selectedDate`、月网格、`dayKey`）抬到用户日
    /// 坐标系，再与"时刻"（如 `completedAt`、`dueDate`）通过 `isSameUserDay` 比较。
    static func userDayStart(onNaturalDay day: Date, calendar: Calendar = .current) -> Date {
        let hour = startHour
        // hour=0 走 Calendar.startOfDay 的快路径——避免 bySettingHour 兜底差异
        if hour == 0 {
            return calendar.startOfDay(for: day)
        }

        // day 已是自然日 0 点；在该自然日上把 hour 拼上去，得到该自然日作为用户日的起点。
        // 与 startOfUserDay(for:) 不同：这里**不需要**判断 moment 与 candidateStart 的先后，
        // 因为输入就是"日"语义，candidateStart 永远是这一天的用户日起点。
        let naturalMidnight = calendar.startOfDay(for: day)
        guard let start = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: naturalMidnight
        ) else {
            // bySettingHour 在极端 DST 情况可能返回 nil，兜底回退到自然日 0 点
            return naturalMidnight
        }
        return start
    }

    /// 返回 `moment` 所属"用户日"的起点。
    ///
    /// 例：`startHour = 3`，`moment = 2026-03-15 01:30` → `2026-03-14 03:00`
    ///
    /// 必须用 `Calendar.date(bySettingHour:...)` 而不是 `addingTimeInterval`，
    /// 以正确处理 DST（夏令时）切换日。
    static func startOfUserDay(for moment: Date, calendar: Calendar = .current) -> Date {
        let hour = startHour
        // hour=0 走 Calendar.startOfDay 的快路径——避免 bySettingHour 兜底差异
        if hour == 0 {
            return calendar.startOfDay(for: moment)
        }

        let naturalMidnight = calendar.startOfDay(for: moment)
        guard let candidateStart = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: naturalMidnight
        ) else {
            // bySettingHour 在极端 DST 情况可能返回 nil，兜底回退到自然日 0 点
            return naturalMidnight
        }

        if candidateStart <= moment {
            return candidateStart
        }
        // moment 还在自然日 0 点到 hour 之间，属于前一用户日
        return calendar.date(byAdding: .day, value: -1, to: candidateStart) ?? candidateStart
    }

    /// 返回 `moment` 所属"用户日"覆盖的区间 `[start, end)`。
    ///
    /// 例：`startHour = 3`，`moment = 2026-03-15 04:00` →
    /// `[2026-03-15 03:00, 2026-03-16 03:00)`
    ///
    /// DST 切换日 `end - start` 可能是 23 或 25 小时，符合预期。
    static func userDayInterval(for moment: Date, calendar: Calendar = .current) -> DateInterval {
        let start = startOfUserDay(for: moment, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// 判断两个时刻是否属于同一"用户日"。
    static func isSameUserDay(_ a: Date, _ b: Date, calendar: Calendar = .current) -> Bool {
        startOfUserDay(for: a, calendar: calendar) == startOfUserDay(for: b, calendar: calendar)
    }
}
