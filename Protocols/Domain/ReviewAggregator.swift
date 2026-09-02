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
    /// 未来 7 天(明起到第 7 天)到期的待办数。UI 用作统计卡副文案。
    let upcomingDueIn7DaysCount: Int
    /// byDay 中 count > 0 的天数。UI 层据此判定是否切到稀疏文本态。
    let daysWithCompletion: Int
    /// 「当天记下、当天做完」的完成件数(一次性任务口径)。由调用方用
    /// `ReviewAggregator.sameDayCompletions` 算好传入——`CompletionEvent`
    /// 不带 createdAt,summarize 内部算不了;规律任务无 per-occurrence
    /// createdAt,不参与(设计文档「偏差与口径」)。
    let sameDayCount: Int
    /// 窗口内「新增」的任务数(2026-09-01 拍板:第 1 步判词证据链
    /// 「完成 9 / 新增 12 / 还挂着 35」)。由调用方用 `createdInWindow`
    /// 算好传入(同 sameDayCount 的注入模式)。**不过滤 recurrenceRule**:
    /// 判词比的是清单进出(新增 vs 完成),规律父任务记下时也是新增。
    let createdCount: Int
    /// 「还挂着」的一次性任务数(与复盘入口卡「N 件事等你决定」、第 2 步
    /// 卡堆输入同一口径:!isCompleted && abandonedAt == nil &&
    /// recurrenceRule == nil)。三处数字必须同源,否则同屏自相矛盾。
    let pendingOneOffCount: Int
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
    ///   - upcomingDueIn7DaysCount: 未来 7 天到期的待办数(统计卡副文案)
    /// - Returns: 聚合后的回顾摘要
    static func summarize(
        events: [CompletionEvent],
        from startDay: Date,
        to endDay: Date,
        calendar: Calendar = .current,
        upcomingDueIn7DaysCount: Int = 0
    ) -> ReviewSummary {
        let normalizedStart = DayClock.startOfUserDay(for: startDay, calendar: calendar)
        let normalizedEnd = DayClock.startOfUserDay(for: endDay, calendar: calendar)

        // 空区间或无事件 → 全零摘要(但保留传入的副文案数据,让 UI 能显示)
        guard normalizedStart < normalizedEnd, !events.isEmpty else {
            return ReviewSummary(
                periodLabel: "",
                total: 0,
                byCategory: [:],
                byDay: [:],
                streakDays: 0,
                busiestDay: nil,
                busiestDayCount: 0,
                upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
                daysWithCompletion: 0,
                sameDayCount: 0,
                createdCount: 0,
                pendingOneOffCount: 0
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
                upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
                daysWithCompletion: 0,
                sameDayCount: 0,
                createdCount: 0,
                pendingOneOffCount: 0
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

        // 完成率已下岗(2026-08-23 拍板):比率口径(有截止日的才进分母)与
        // 「N 件事待处理」同屏必然撞出「100% + 5 件没做」的矛盾,且与洞察引擎
        // 反 gaming 章程(「不把完成率放大成主指标」)打架。统计卡改显绝对数 total。
        let total = inRange.count

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
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount,
            daysWithCompletion: daysWithCompletion,
            sameDayCount: 0,
            createdCount: 0,
            pendingOneOffCount: 0
        )
    }

    /// 「当天记、当天做完」件数:completedAt 落在 [startDay, endDay) 且与
    /// createdAt 同一用户日。只数一次性任务(recurrenceRule == nil)——
    /// 规律任务的完成记录(TodoOccurrenceCompletion)没有 per-occurrence
    /// createdAt,算不了,排除(与第 3 步洞察 03 同口径)。
    ///
    /// - Parameters:
    ///   - todos: 一次性/规律混排的待办 DTO(内部自过滤,规律任务直接跳过)
    ///   - startDay: 区间起始(按用户日归一化,闭区间)
    ///   - endDay: 区间结束(按用户日归一化,开区间——不含当天)
    ///   - calendar: 日历,默认 .current
    static func sameDayCompletions(
        _ todos: [TodoItemData],
        from startDay: Date,
        to endDay: Date,
        calendar: Calendar = .current
    ) -> Int {
        let normalizedStart = DayClock.startOfUserDay(for: startDay, calendar: calendar)
        let normalizedEnd = DayClock.startOfUserDay(for: endDay, calendar: calendar)
        return todos.filter { todo in
            guard todo.recurrenceRule == nil, let completedAt = todo.completedAt else { return false }
            let doneDay = DayClock.startOfUserDay(for: completedAt, calendar: calendar)
            guard doneDay >= normalizedStart, doneDay < normalizedEnd else { return false }
            let createdDay = DayClock.startOfUserDay(for: todo.createdAt, calendar: calendar)
            return createdDay == doneDay
        }.count
    }

    /// 窗口内「新增」的任务数:createdAt 落在 [startDay, endDay)。
    /// **不过滤 recurrenceRule**(判词比的是清单进出,规律父任务记下时也是新增),
    /// 也不看完成态(新增后做完仍是本期新增)。
    ///
    /// - Parameters:
    ///   - todos: 待办 DTO(含已完成)。
    ///   - startDay/endDay: 用户日归一化的闭开区间(与 sameDayCompletions 同约定)。
    static func createdInWindow(
        _ todos: [TodoItemData],
        from startDay: Date,
        to endDay: Date,
        calendar: Calendar = .current
    ) -> Int {
        let normalizedStart = DayClock.startOfUserDay(for: startDay, calendar: calendar)
        let normalizedEnd = DayClock.startOfUserDay(for: endDay, calendar: calendar)
        return todos.filter { todo in
            let day = DayClock.startOfUserDay(for: todo.createdAt, calendar: calendar)
            return day >= normalizedStart && day < normalizedEnd
        }.count
    }

    /// 「还挂着」的一次性任务数:!isCompleted && abandonedAt == nil &&
    /// recurrenceRule == nil——与复盘入口卡、第 2 步卡堆输入同一口径
    /// (2026-09-01 拍板:三处数字必须同源)。
    static func pendingOneOffCount(_ todos: [TodoItemData]) -> Int {
        todos.filter { !$0.isCompleted && $0.abandonedAt == nil && $0.recurrenceRule == nil }.count
    }
}
