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
    /// 完成/到期(nil = 无法算分母)。分母是区间内 dueDate ≤ 今天的待办数,
    /// 避免月中把未来到期的任务也算进分母导致完成率假性偏低。
    let completionRate: Double?
    /// 区间内 dueDate ≤ 今天的待办数(完成率新分母)。由调用方传入。
    /// nil 表示无数据,UI 层会隐藏完成率卡片。
    let dueByTodayCount: Int?
    /// 未来 7 天(明起到第 7 天)到期的待办数。UI 用作完成率副文案。
    let upcomingDueIn7DaysCount: Int
    /// byDay 中 count > 0 的天数。UI 层据此判定是否切到稀疏文本态。
    let daysWithCompletion: Int
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
    ///   - dueByTodayCount: 区间内 dueDate ≤ 今天的待办数(完成率分母)。
    ///     传入 nil 或 0 时 completionRate 返回 nil,UI 层隐藏完成率卡片。
    ///   - upcomingDueIn7DaysCount: 未来 7 天到期的待办数(完成率副文案)
    /// - Returns: 聚合后的回顾摘要
    static func summarize(
        events: [CompletionEvent],
        from startDay: Date,
        to endDay: Date,
        calendar: Calendar = .current,
        dueByTodayCount: Int? = nil,
        upcomingDueIn7DaysCount: Int = 0
    ) -> ReviewSummary {
        let normalizedStart = DayClock.startOfUserDay(for: startDay, calendar: calendar)
        let normalizedEnd = DayClock.startOfUserDay(for: endDay, calendar: calendar)

        // 空区间或无事件 → 全零摘要(但保留传入的分母数据,让 UI 能显示副文案)
        guard normalizedStart < normalizedEnd, !events.isEmpty else {
            return ReviewSummary(
                periodLabel: "",
                total: 0,
                byCategory: [:],
                byDay: [:],
                streakDays: 0,
                busiestDay: nil,
                busiestDayCount: 0,
                completionRate: nil,
                dueByTodayCount: dueByTodayCount,
                upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
                daysWithCompletion: 0
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
                completionRate: nil,
                dueByTodayCount: dueByTodayCount,
                upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
                daysWithCompletion: 0
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

        // completionRate: total / dueByTodayCount,夹逼 [0,1]。
        // 分母是区间内 dueDate ≤ 今天的待办数——月中分母只算已到期的,
        // 不会出现"整月分母 → 月中显示 10%"的打击人情况。
        // 分子是区间内完成事件总数(含规律任务多次完成),
        // 人群不一致时比率可能 >100%(规律任务被算作 1 个分母但 N 次完成),夹逼避免误读。
        let total = inRange.count
        let completionRate: Double?
        if let dueByTodayCount, dueByTodayCount > 0 {
            let raw = Double(total) / Double(dueByTodayCount)
            completionRate = min(max(raw, 0), 1)
        } else {
            completionRate = nil
        }

        // daysWithCompletion: byDay 中 count > 0 的天数。UI 据此判定稀疏文本态。
        let daysWithCompletion = byDay.values.filter { $0 > 0 }.count

        return ReviewSummary(
            periodLabel: "",
            total: total,
            byCategory: byCategory,
            byDay: byDay,
            streakDays: streakDays,
            busiestDay: busiestDay,
            busiestDayCount: busiestDayCount,
            completionRate: completionRate,
            dueByTodayCount: dueByTodayCount,
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
            daysWithCompletion: daysWithCompletion
        )
    }
}
