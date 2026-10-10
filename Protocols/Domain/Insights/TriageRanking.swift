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
    /// 批量出口门槛(v5 拍板 3,supersede v2 的 30 天):尾部里停滞 ≥ 21 天
    /// 才提供一键推「稍后」——与地板 A 的 21+ 档(RottingRule.ageThresholdDays)
    /// 同尺同数:地板点名说「该处理了」,出口就能给动作,系统只说一套话
    /// (21 天没动 = 要么处理,要么承认稍后)。`extractionOutcome == .parsed`
    /// 门槛保留(不承诺做不到的落点)。
    static let batchStagnationDays = 21

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

    /// 停滞天数(创建的用户日到 now 的用户日整日数;未来创建的脏数据钳 0)。
    ///
    /// 口径(v5 E7,2026-10-11 起):**DayClock 用户日**——与 `RottingRule` /
    /// `InsightEngine.backlogAgeFact` 同一把尺。v4 时代这里是自然日,卡头
    /// 「记下 N 天了」与第 3 步地板 A 的用户日年龄同屏会差 1 天(已知显示
    /// 口径差);批量出口门槛对齐 21 天后,「地板 A 说 21+ 天、出口按自然日
    /// 还差一天收不了」的错位会以 ±1 天形式重现——根因修复=口径统一,
    /// 全部 5 个调用方(rank 排序 / somedayBatch 批量资格 / preexisting 排序 /
    /// 卡头显示 / scheduled 排序)随本函数一致切换,卡头显示差 1 天的旧毛刺
    /// 随之消失(预期收益)。
    static func stagnationDays(
        of todo: TodoItemData,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let createdDay = DayClock.startOfUserDay(for: todo.createdAt, calendar: calendar)
        let nowDay = DayClock.startOfUserDay(for: now, calendar: calendar)
        return max(0, calendar.dateComponents([.day], from: createdDay, to: nowDay).day ?? 0)
    }

    /// 单键排序:停滞天数 desc → id 决胜(v3 拍板 8,第 4 步候选池)。
    /// 与 `rank` 的区别:不带推迟次数主键——第 4 步排序的是「从池子里挑焦点」
    /// 的呈现顺序,不是卡堆的处理优先级;停滞天数是现成且有意义的代理
    /// (放得最久的排最前),复用同一决胜规则保证确定性。不引入新的重要性
    /// 模型(任务没有 estimate 字段,按「大小」排当前数据模型做不到)。
    static func sortByStagnation(
        _ todos: [TodoItemData],
        now: Date,
        calendar: Calendar = .current
    ) -> [TodoItemData] {
        todos.sorted { lhs, rhs in
            let lhsAge = stagnationDays(of: lhs, now: now, calendar: calendar)
            let rhsAge = stagnationDays(of: rhs, now: now, calendar: calendar)
            if lhsAge != rhsAge { return lhsAge > rhsAge }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
