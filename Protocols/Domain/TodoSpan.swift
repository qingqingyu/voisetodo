import Foundation

/// 跨天事件(multi-day span)的日期计算工具。
///
/// 把"周五到周日出游"这种连续跨多天的事件相关计算收在无依赖 enum 里,
/// 供 store / widget / UI 共用。风格对齐 `TodoDueDateShifter` 与
/// `RecurrenceRule.occurs(on:startDate:calendar:)`。
///
/// - Invariants(由 `normalized` 统一应用,写入侧归一化):
///   1. `dueDate == nil` ⇒ `eventEndDate = nil`
///   2. `recurrenceRule != nil` ⇒ `eventEndDate = nil`(v1 与重复互斥)
///   3. `startOfDay(eventEndDate) <= startOfDay(dueDate)` ⇒ `eventEndDate = nil`(退化单天)
///   4. 跨度超过 `maxSpanDays` 天 ⇒ 截断到 `startOfDay(dueDate) + maxSpanDays - 1`
///
/// - 日口径:用 `calendar.startOfDay(for:)`,与 `TodoQueryActor.daysBetween`、
///   `RecurrenceRule.occurs(on:)`、`TodoOccurrenceData.dayKey` 全部一致。
///   已知代价:`VoiceTodoDayStartHour > 0` 时,"通宵到次日 02:00"仍渲染在自然日次日,
///   与现有 occurrence 路径同口径,不在本次扩大战线(见
///   docs/day-clock-day-boundary-inconsistencies.md)。
enum TodoSpan {
    /// 跨度上限(含两端自然日)。保护内存展开循环不会无限增长。
    /// 366 覆盖一年 + 闰年尾巴;超过的事件(如跨年休假)会被截断,
    /// 由调用方负责记日志或给用户提示(见 docs/multi-day-span-events.md 截断 UI 提示)。
    static let maxSpanDays = 366

    /// 事件覆盖的自然日序列(含两端,逐日 0 点)。
    /// - Parameters:
    ///   - dueDate: 事件起点(调用方负责保证非 nil)
    ///   - eventEndDate: 跨天闭区间终点;nil 表示单天,返回单元素数组
    ///   - calendar: 日历
    /// - Returns: 自然日 0 点数组。跨天超 `maxSpanDays` 时截断到上限。
    static func coveredDays(
        dueDate: Date,
        eventEndDate: Date?,
        calendar: Calendar = .current
    ) -> [Date] {
        let startDay = calendar.startOfDay(for: dueDate)
        guard let eventEndDate else { return [startDay] }
        let endDay = calendar.startOfDay(for: eventEndDate)
        guard endDay > startDay else { return [startDay] }

        var days: [Date] = []
        var current = startDay
        var count = 0
        while current <= endDay && count < maxSpanDays {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
            count += 1
        }
        return days
    }

    /// 某一天是否落在事件区间内(widget 与快速判定用,不构造数组)。
    /// - Parameters:
    ///   - day: 待判定的自然日(通常是月网格的一天)
    ///   - dueDate: 事件起点
    ///   - eventEndDate: 跨天终点,nil 表示单天
    ///   - calendar: 日历
    /// - Returns: true 表示该日属于事件覆盖范围
    static func covers(
        day: Date,
        dueDate: Date,
        eventEndDate: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let startDay = calendar.startOfDay(for: dueDate)
        guard let eventEndDate else {
            return dayStart == startDay
        }
        let endDay = calendar.startOfDay(for: eventEndDate)
        return dayStart >= startDay && dayStart <= endDay
    }

    /// 应用 4 条不变式,返回应当持久化的 `eventEndDate`。
    /// - Parameters:
    ///   - eventEndDate: 调用方原始想设的终点
    ///   - dueDate: 事件起点(可能为 nil)
    ///   - hasRecurrence: 是否带重复规则
    ///   - calendar: 日历
    /// - Returns: 归一化后的终点;nil 表示应清空(单天语义)
    static func normalized(
        eventEndDate: Date?,
        dueDate: Date?,
        hasRecurrence: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        // 不变式 1 + 2:无起点 或 带重复 → 一律 nil(v1 与重复互斥)
        guard let dueDate, !hasRecurrence else { return nil }
        // 输入本身就是 nil:无需归一化
        guard let eventEndDate else { return nil }
        // 不变式 3:终点不晚于起点 → 退化为单天
        let startDay = calendar.startOfDay(for: dueDate)
        let endDay = calendar.startOfDay(for: eventEndDate)
        guard endDay > startDay else { return nil }
        // 不变式 4:跨度超限 → 截断到 startDay + maxSpanDays - 1(startOfDay 形式)
        let spanDays = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        if spanDays >= maxSpanDays {
            return calendar.date(byAdding: .day, value: maxSpanDays - 1, to: startDay)
        }
        // 其他情况:保留原始 eventEndDate(可能含钟点分量,后续显示用)
        return eventEndDate
    }

    /// 平移事件:`dueDate` 变化时保持跨度不变,返回新的 `eventEndDate`。
    /// - Parameters:
    ///   - originalDue: 原起点
    ///   - originalEnd: 原终点(nil 表示单天)
    ///   - newDue: 新起点
    ///   - calendar: 日历
    /// - Returns: 新终点;`originalEnd == nil` 时返回 nil(保持单天语义)
    static func shiftedEnd(
        originalDue: Date,
        originalEnd: Date?,
        newDue: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let originalEnd else { return nil }
        let originalStartDay = calendar.startOfDay(for: originalDue)
        let originalEndDay = calendar.startOfDay(for: originalEnd)
        let spanDays = calendar.dateComponents([.day], from: originalStartDay, to: originalEndDay).day ?? 0
        // 跨度非正(原数据异常)→ 不平移,返回 nil 让调用方清掉跨天
        guard spanDays > 0 else { return nil }
        let newStartDay = calendar.startOfDay(for: newDue)
        return calendar.date(byAdding: .day, value: spanDays, to: newStartDay)
    }
}
