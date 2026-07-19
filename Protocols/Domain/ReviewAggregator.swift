import Foundation

/// 统一两种完成数据源(TodoItem / TodoOccurrenceCompletion)的中间类型。
struct CompletionEvent: Hashable, Equatable, Sendable {
    let id: UUID
    let completedAt: Date
    let category: TodoCategory
}

/// 回顾摘要——把已完成事件聚合成可展示的统计。
struct ReviewSummary: Hashable, Equatable, Sendable {
    /// 展示用周期标签(如 "2026年7月" / "第29周"),由调用方传入。
    let periodLabel: String
    /// 完成总数。
    let total: Int
    /// 分类计数。
    let byCategory: [TodoCategory: Int]
    /// 每天完成数(用户日归一化)。
    let byDay: [Date: Int]
    /// 连续有完成的天数。
    let streakDays: Int
    /// 完成最多的一天。
    let busiestDay: Date?
    /// 那天完成了几件。
    let busiestDayCount: Int
    /// 完成/创建(nil = 无法算分母)。
    let completionRate: Double?
}

/// 纯函数聚合层——把已完成事件聚合成回顾摘要,无副作用、无 SwiftData 依赖。
enum ReviewAggregator {
    /// 把 CompletionEvent 数组聚合成 ReviewSummary。
    ///
    /// - Parameters:
    ///   - events: 完成事件列表(已从 SwiftData 转换好)
    ///   - startDay: 区间起始(按用户日归一化,闭区间)
    ///   - endDay: 区间结束(按用户日归一化,开区间——不含当天)
    ///   - calendar: 日历,默认 .current
    ///   - createdCount: 可选分母,用于算 completionRate
    /// - Returns: 聚合后的回顾摘要
    static func summarize(
        events: [CompletionEvent],
        from startDay: Date,
        to endDay: Date,
        calendar: Calendar = .current,
        createdCount: Int? = nil
    ) -> ReviewSummary {
        let normalizedStart = DayClock.startOfUserDay(for: startDay, calendar: calendar)
        let normalizedEnd = DayClock.startOfUserDay(for: endDay, calendar: calendar)

        // 空区间或无事件 → 全零摘要
        guard normalizedStart < normalizedEnd, !events.isEmpty else {
            return ReviewSummary(
                periodLabel: "",
                total: 0,
                byCategory: [:],
                byDay: [:],
                streakDays: 0,
                busiestDay: nil,
                busiestDayCount: 0,
                completionRate: nil
            )
        }

        // 过滤到 [startDay, endDay) 区间
        let inRange = events.filter { event in
            let day = DayClock.startOfUserDay(for: event.completedAt, calendar: calendar)
            return day >= normalizedStart && day < normalizedEnd
        }

        guard !inRange.isEmpty else {
            return ReviewSummary(
                periodLabel: "",
                total: 0,
                byCategory: [:],
                byDay: [:],
                streakDays: 0,
                busiestDay: nil,
                busiestDayCount: 0,
                completionRate: nil
            )
        }

        // byCategory: group by category, count
        var byCategory: [TodoCategory: Int] = [:]
        for event in inRange {
            byCategory[event.category, default: 0] += 1
        }

        // byDay: group by userDay, count
        var byDay: [Date: Int] = [:]
        for event in inRange {
            let day = DayClock.startOfUserDay(for: event.completedAt, calendar: calendar)
            byDay[day, default: 0] += 1
        }

        // busiestDay: byDay 中 count 最大的那天
        var busiestDay: Date?
        var busiestDayCount = 0
        for (day, count) in byDay {
            if count > busiestDayCount {
                busiestDay = day
                busiestDayCount = count
            }
        }

        // streakDays: 从最后一天有事件的天开始往前数连续天数。
        // 今天没完成不算断(从最近有活动的那天开始数),避免"今天还没做事 streak 就归零"。
        var streakDays = 0
        var cursor = calendar.date(byAdding: .day, value: -1, to: normalizedEnd) ?? normalizedEnd
        // 先跳过没有事件的天,找到最近的活动日
        while cursor >= normalizedStart && byDay[cursor] == nil {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        // 从活动日开始往前数连续天数
        while cursor >= normalizedStart && byDay[cursor] != nil {
            streakDays += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = prev
        }

        // completionRate: createdCount > 0 ? total / createdCount : nil
        let total = inRange.count
        let completionRate: Double?
        if let createdCount, createdCount > 0 {
            completionRate = Double(total) / Double(createdCount)
        } else {
            completionRate = nil
        }

        return ReviewSummary(
            periodLabel: "",
            total: total,
            byCategory: byCategory,
            byDay: byDay,
            streakDays: streakDays,
            busiestDay: busiestDay,
            busiestDayCount: busiestDayCount,
            completionRate: completionRate
        )
    }
}
