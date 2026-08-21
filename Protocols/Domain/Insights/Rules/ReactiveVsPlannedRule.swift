import Foundation

/// 洞察 03「计划 vs 救火」(v1 两条规则之一,拍板 2)。
///
/// 在一次性任务上(`InsightContext.completedEvents` 原料天然只含一次性任务,
/// 规律任务被拍板 4 排除):「记下当天就完成」= 救火。
/// 「当天」是**用户日**(`DayClock`),不是自然日——凌晨 1:30 干完的活,
/// 对 startHour=3 的用户仍算「昨天记下的那天的活」。
///
/// ratio = 救火数 / 总完成数。三个阈值(规格文档不在仓库,从
/// docs/todo-review-flow-design.md「验证」节用例反推):
/// - **触发上界 ratio ≥ 0.50** → 救火式,警示文案。依据:03-A(0.62 触发)、
///   03-C(0.40 不触发)夹出的开区间;0.5 取「完成的事里一半以上是当场记当场做」
///   这个语义自然线。
/// - **正向下界 ratio ≤ 0.20** → 计划式,**用好转文案**(复盘只报坏消息,用户会
///   停止复盘,§2.4)。依据:03-B(0.18 是正向信号);0.2 取「五件里至多一件救火」。
/// - **0.20 < ratio < 0.50** → 隐藏。中间地带没有可行动的信号。
///
/// `minSample = 15`:降级阶梯规定 ≥15 条完成记录才跑 03(§2.3)。
/// 满分效应量:警示方向 = ratio / 0.80(80% 救火即封顶,100% 留给「全是救火」的
/// 病态场景做归一余量);正向方向 = (0.50 − ratio) / 0.50(离救火线越远越强)。
struct ReactiveVsPlannedRule: InsightRule {
    let id = InsightID.reactiveVsPlanned
    let minSample = 15

    /// ratio ≥ 此值触发警示文案。
    static let triggerRatio = 0.5
    /// ratio ≤ 此值走正向(好转)文案。
    static let positiveRatio = 0.2
    /// 警示方向的满分效应量对应 ratio。
    static let fullEffectRatio = 0.8

    func evaluate(_ ctx: InsightContext, calendar: Calendar) -> InsightAvailability {
        let events = ctx.completedEvents
        let n = events.count
        guard n >= minSample else { return .placeholder(needMore: minSample - n) }

        // 「记下当天(用户日)就完成」= 救火
        let reactive = events.filter {
            DayClock.isSameUserDay($0.createdAt, $0.completedAt, calendar: calendar)
        }.count
        let ratio = Double(reactive) / Double(n)

        let score: Double
        let effect: Double
        let tone: InsightTone
        let headline: String
        let body: String
        let percent = Int((ratio * 100).rounded())

        if ratio >= Self.triggerRatio {
            tone = .observation
            effect = min(1.0, ratio / Self.fullEffectRatio)
            score = InsightEngine.score(normalizedEffect: effect, sampleCount: n, minSample: minSample)
            // 文案走 xcstrings 参数化格式(%lld / %%),不在 Swift 里拼接(§本地化)。
            headline = String(localized: "review.insight.reactive.headline_\(percent)")
            body = String(localized: "review.insight.reactive.body_\(percent)_\(n)")
        } else if ratio <= Self.positiveRatio {
            tone = .improving
            // 正向信号:离救火线越远,效应越强。
            effect = min(1.0, (Self.triggerRatio - ratio) / Self.triggerRatio)
            score = InsightEngine.score(normalizedEffect: effect, sampleCount: n, minSample: minSample)
            // 好转文案——复盘不能只报坏消息(§2.4)。
            headline = String(localized: "review.insight.reactive.headline_positive_\(percent)")
            body = String(localized: "review.insight.reactive.body_positive_\(percent)_\(n)")
        } else {
            // 0.20 < ratio < 0.50:中间地带,无可行动信号,不显示。
            return .hidden
        }

        return .fired(
            InsightResult(
                id: id,
                strength: InsightEngine.strength(score: score, sampleCount: n, minSample: minSample),
                tone: tone,
                headline: headline,
                body: body,
                viz: .reactiveVsPlanned(ratio: ratio, sampleCount: n),
                suggestedRule: nil, // v1 只存储规则(阶段 3 UI 决定)
                // 样本口径必须写明「不含规律任务」(§2.2)——否则用户会发现
                // 第 1 步成绩单和第 3 步观察的条数对不上。
                sampleNote: String(localized: "review.insight.reactive.sample_note_\(n)"),
                score: score,
                effectSize: effect,
                sampleCount: n
            )
        )
    }
}
