import Foundation

/// 第 2 步卡堆排序与截断(2026-09-01 拍板 1+2,docs/todo-review-flow-v2.md)。
///
/// 排序是**字典序双键**(非乘积):推迟次数 desc → 停滞天数 desc → id 决胜。
/// 选字典序的原因:事件表 2026-08-21 才建且不回填历史(v1 取舍 1),冷启动时
/// 推迟次数恒 0——乘积会全为 0 排不出先后;字典序在主键全 0 时自动退化成
/// 纯按停滞天数排,推迟数据长出来后主键平滑接管。
///
/// 截断:排序后只取前 `deckSize` 张进卡堆(周复盘 3 分钟结束,35 次逐张决策
/// 是苦役),尾部留给批量出口(停滞 ≥ `batchStagnationDays` 天的可一键推
/// 「稍后」,其余原样留着)。
enum TriageRanking {
    /// 卡堆规模(拍板 1):排序后取前 8。
    static let deckSize = 8
    /// 批量出口门槛(拍板 3):尾部里停滞 ≥ 30 天的才提供一键推「稍后」。
    static let batchStagnationDays = 30

    /// 字典序排序:推迟次数 desc → 停滞天数 desc → id(确定性决胜,单测稳定)。
    /// - Parameters:
    ///   - todos: 待排序任务(`triageInput` 的输出,不在此重复过滤)。
    ///   - deferCounts: 任务 → 推迟次数(事件表聚合,`InsightContext.deferCounts`)。
    ///   - now: 「现在」(停滞天数 = now - createdAt 的整日数,注入可测)。
    ///   - calendar: 日历(日差按日历日计算,默认 `.current`)。
    static func rank(
        _ todos: [TodoItemData],
        deferCounts: [UUID: Int],
        now: Date,
        calendar: Calendar = .current
    ) -> [TodoItemData] {
        todos.sorted { lhs, rhs in
            let lhsDefer = deferCounts[lhs.id] ?? 0
            let rhsDefer = deferCounts[rhs.id] ?? 0
            if lhsDefer != rhsDefer { return lhsDefer > rhsDefer }
            let lhsAge = stagnationDays(of: lhs, now: now, calendar: calendar)
            let rhsAge = stagnationDays(of: rhs, now: now, calendar: calendar)
            if lhsAge != rhsAge { return lhsAge > rhsAge }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 停滞天数(创建日到 now 的整日数;未来创建的脏数据钳 0)。
    static func stagnationDays(
        of todo: TodoItemData,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        max(0, calendar.dateComponents([.day], from: todo.createdAt, to: now).day ?? 0)
    }
}
