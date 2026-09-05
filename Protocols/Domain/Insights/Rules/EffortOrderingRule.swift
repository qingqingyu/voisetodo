import Foundation

/// 洞察 01「先易后难:重要的事,你放得最久」(2026-08-23 拍板启用,原 v1 预留)。
///
/// 判定:高优先级完成事件与普通事件各 ≥3 条时,比较两组「记下→做完」的
/// 用户日跨度中位数:
///   - high ≥ max(other × 2, 2 天) → 触发警示(重要的事拖得明显更久)
///   - high ≤ other → 触发正向(重要的事没被拖——复盘不能只报坏消息,§2.4)
///   - 中间地带 → hidden(没有可行动的信号就不说)
///
/// minSample = 6(两组各 3)。confidence/strength 用**较稀缺组**的样本量而非
/// 总完成数——决定中位数可信度的是小组。
///
/// effectSize 方向约定(冷却 §2.4 用,**越大越糟**):observation 分支 = 拖延
/// 倍数归一;improving 分支取**负值**(好转深度)。冷却判定按 lowerIsBetter
/// 比较,若 improving 也存正值,「好转→恶化」的跨期转换会被误标 improving。
struct EffortOrderingRule: InsightRule {
    let id = InsightID.effortOrdering
    let minSample = 6

    /// 触发:高优中位 ≥ 其他中位的该倍数。
    static let triggerRatio = 2.0
    /// 且高优中位自身至少这么多天(0/1 天的差距不值得说)。
    static let minHighDays = 2
    /// 警示方向满分效应量的倍数线。
    static let fullEffectRatio = 6.0
    /// 每组最少条数(中位数的最小意义样本)。
    static let minPerGroup = 3

    func evaluate(_ ctx: InsightContext, calendar: Calendar) -> InsightAvailability {
        let events = ctx.completedEvents
        let high = events.filter { $0.priority == .high }
        let other = events.filter { $0.priority != .high }

        guard high.count >= Self.minPerGroup, other.count >= Self.minPerGroup else {
            // 组样本不足:占位写清还差多少(§2.3)。高优组有缺口时报高优缺口
            // ——解锁条件是「高优任务的完成」,占位文案(need_more.effortOrdering_)
            // 据此写「做完 N 条高优先级任务」,照做恰好解锁。
            // **对照组(非高优)缺口不出占位**(v3 ③「占位必须说真话」):该分支
            // 的 needMore 是非高优缺口,按 effortOrdering 键写「做完 N 条高优」
            // 照做永不解锁;而诚实的建议(「去完成 N 条普通任务以解锁洞察」)
            // 是在教用户为解锁洞察而优化行为,违反反 gaming 章程——没有可诚实
            // 建议的动作就不说(hidden)。
            let needHigh = max(0, Self.minPerGroup - high.count)
            if needHigh > 0 {
                return .placeholder(needMore: needHigh)
            }
            return .hidden
        }

        let highMedian = Self.medianDays(high, calendar: calendar)
        let otherMedian = Self.medianDays(other, calendar: calendar)
        let highCount = high.count
        let otherCount = other.count
        // 较稀缺组:决定两条中位数里哪条更不可信。
        let n = min(highCount, otherCount)

        let effect: Double
        let tone: InsightTone
        let headline: String
        let body: String

        if Double(highMedian) >= max(Double(otherMedian) * Self.triggerRatio, Double(Self.minHighDays)) {
            tone = .observation
            // 倍数越大越糟,6× 封顶(归一余量留给更病态的场景)。
            let ratio = Double(highMedian) / Double(max(otherMedian, 1))
            effect = min(1.0, (ratio - Self.triggerRatio) / (Self.fullEffectRatio - Self.triggerRatio))
            headline = String(localized: "review.insight.effort.headline_\(highMedian)")
            body = String(
                localized: "review.insight.effort.body_\(highMedian)_\(otherMedian)_\(highCount)_\(otherCount)"
            )
        } else if highMedian <= otherMedian {
            tone = .improving
            // 离「拖得更久」越远越强;其他组中位做分母兜底(0 天时按 1 算)。
            effect = min(1.0, Double(otherMedian - highMedian) / Double(max(otherMedian, 1)))
            headline = String(localized: "review.insight.effort.headline_positive_\(highMedian)")
            body = String(
                localized: "review.insight.effort.body_positive_\(highMedian)_\(otherMedian)_\(highCount)_\(otherCount)"
            )
        } else {
            return .hidden
        }

        let score = InsightEngine.score(normalizedEffect: effect, sampleCount: n, minSample: minSample)
        return .fired(
            InsightResult(
                id: id,
                strength: InsightEngine.strength(score: score, sampleCount: n, minSample: minSample),
                tone: tone,
                headline: headline,
                body: body,
                viz: .effortOrdering(
                    highDays: highMedian,
                    otherDays: otherMedian,
                    highCount: highCount,
                    otherCount: otherCount
                ),
                sampleNote: String(localized: "review.insight.effort.sample_note_\(highCount)_\(otherCount)"),
                score: score,
                // improving 取负,统一「越大越糟」的冷却语义(见类型注释)。
                // score 已在上面用正值算好,不受影响。
                effectSize: tone == .improving ? -effect : effect,
                sampleCount: n
            )
        )
    }

    /// 一组事件的「记下→做完」用户日跨度中位数(偶数个取中间两数均值向下取整)。
    private static func medianDays(_ events: [InsightCompletedEvent], calendar: Calendar) -> Int {
        let spans = events.map { event -> Int in
            let createdDay = DayClock.startOfUserDay(for: event.createdAt, calendar: calendar)
            let completedDay = DayClock.startOfUserDay(for: event.completedAt, calendar: calendar)
            return calendar.dateComponents([.day], from: createdDay, to: completedDay).day ?? 0
        }.sorted()
        let mid = spans.count / 2
        if spans.count % 2 == 1 { return spans[mid] }
        return (spans[mid - 1] + spans[mid]) / 2
    }
}
