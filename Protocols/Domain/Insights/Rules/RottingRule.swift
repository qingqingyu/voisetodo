import Foundation

/// 洞察 02「任务在腐烂」(v1 两条规则之一,拍板 2)。
///
/// 判定(§2.2):未完成 && abandonedAt == nil && recurrenceRule == nil(原料
/// `InsightContext.openTasks` 已在上游保证)且满足任一——
///   - 有效推迟 ≥ 3 次(deferCounts 已排除 origin == .review:复盘里的主动排期不算推迟)
///   - `now - createdAt ≥ 21` 个用户日(`ctx.to` 兼作 now)
///
/// **冷启动只有 age 分支**——推迟事件表从现在起记、历史不回填,推迟分支在
/// 数据攒起来之前恒为空(§取舍 1)。但只要 age 分支命中就照常触发:
/// 这是六条里唯一冷启动可用的洞察,唯一直连第 2 步处理动作的。
///
/// 阈值推导(规格文档不在仓库,从 docs/todo-review-flow-design.md「验证」节用例反推):
/// - `minSample = 3`:02-A「3 条推迟 ≥3 次 → 触发」是推迟分支最小触发夹具;
/// - 触发条件是**腐烂列表非空**而非 n ≥ minSample——02-B「1 条 25 天前创建、
///   0 推迟 → 命中 age 分支」要求单条也触发。minSample 只作用于 confidence/
///   强度标签(02-B 场景 n=1 → 强制 lowData,诚实标注)。
/// - 满分效应量 = 1.0(全部未完成一次性任务都在腐烂);effect = 腐烂数 / 未完成总数。
struct RottingRule: InsightRule {
    let id = InsightID.rotting
    let minSample = 3

    /// 腐烂判定:有效推迟 ≥ 3 次,或躺了 ≥ 21 个用户日。
    static let deferThreshold = 3
    static let ageThresholdDays = 21

    func evaluate(_ ctx: InsightContext, calendar: Calendar) -> InsightAvailability {
        let open = ctx.openTasks
        guard !open.isEmpty else { return .hidden }

        let nowDay = DayClock.startOfUserDay(for: ctx.to, calendar: calendar)
        var items: [RottingVizItem] = []
        for task in open {
            let defers = ctx.deferCounts[task.todoId] ?? 0
            let createdDay = DayClock.startOfUserDay(for: task.createdAt, calendar: calendar)
            let ageDays = calendar.dateComponents([.day], from: createdDay, to: nowDay).day ?? 0
            guard defers >= Self.deferThreshold || ageDays >= Self.ageThresholdDays else { continue }
            items.append(
                RottingVizItem(todoId: task.todoId, title: task.title, deferCount: defers, ageDays: ageDays)
            )
        }
        guard !items.isEmpty else { return .hidden }

        // 列表按推迟次数降序(次键躺的天数降序)——最「卡住」的排最前。
        items.sort { lhs, rhs in
            if lhs.deferCount != rhs.deferCount { return lhs.deferCount > rhs.deferCount }
            return lhs.ageDays > rhs.ageDays
        }

        let n = open.count
        let effect = Double(items.count) / Double(n)
        let score = InsightEngine.score(normalizedEffect: effect, sampleCount: n, minSample: minSample)
        let rottingCount = items.count
        let oldestAge = items.map(\.ageDays).max() ?? 0

        return .fired(
            InsightResult(
                id: id,
                strength: InsightEngine.strength(score: score, sampleCount: n, minSample: minSample),
                tone: .observation,
                // 文案走 xcstrings 参数化格式(%lld),不在 Swift 里拼接——
                // 日语的数量词和语序与中英文不同(§本地化)。
                headline: String(localized: "review.insight.rotting.headline_\(rottingCount)"),
                // 文案止于观察(§2.2):只报现象与数字,不说「你应该」。
                body: String(
                    localized: "review.insight.rotting.body_\(rottingCount)_\(oldestAge)_\(n)"
                ),
                viz: .rotting(items: items),
                suggestedRule: nil, // v1 只存储规则,不替用户预填(阶段 3 UI 决定)
                sampleNote: String(localized: "review.insight.rotting.sample_note_\(n)"),
                score: score,
                effectSize: effect,
                sampleCount: n
            )
        )
    }
}
