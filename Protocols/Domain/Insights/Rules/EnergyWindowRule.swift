import Foundation

/// 洞察 05「精力窗口:好时段在上午,重要的事排在深夜」(2026-08-23 拍板启用,原 v1 预留)。
///
/// 组合信号,两个半句都要成立才触发(组合洞察宁可漏报不误报):
///   1. 完成高峰落在上午(5–11 点)——完成时刻直方图的最大桶;
///   2. 带钟点的重要任务里 ≥50% 排在 22 点后(dueDate 的钟点)。
/// 任一半句不成立、或带钟点的重要任务 <2 件 → hidden。
///
/// 样本口径:完成时刻条数走降级阶梯 full 档(minSample = 15,与 03 同级);
/// confidence/strength 用**稀缺腿**(带钟点的重要任务数)——它天然稀少,
/// 本规则长期挂「数据偏少」标签是诚实表现(demo 即如此标)。
///
/// 时段口径:直接用完成时刻/排期钟点的小时数,不做用户日起始小时换算——
/// 小时分布是生理节律信号,与「哪天」的用户日边界无关。
struct EnergyWindowRule: InsightRule {
    let id = InsightID.energyWindow
    let minSample = 15

    /// 「上午」上限(含):5...11 点。
    static let morningEndHour = 11
    /// 「深夜」起点(含):22/23 点。
    static let lateStartHour = 22
    /// 带钟点的重要任务至少几件才谈「排在深夜」。
    static let minHighTimed = 2
    /// 深夜占比触发线。
    static let lateRatioTrigger = 0.5
    /// 直方图统计的小时范围下界(与 viz 视图 5...23 对齐)。
    static let firstHour = 5
    static let lastHour = 23

    func evaluate(_ ctx: InsightContext, calendar: Calendar) -> InsightAvailability {
        let events = ctx.completedEvents
        guard events.count >= minSample else {
            return .placeholder(needMore: minSample - events.count)
        }

        // 完成高峰小时:升序扫描 + 严格大于 → 平手时更早的小时胜出(保守)。
        var hourCounts = Array(repeating: 0, count: 24)
        for event in events {
            hourCounts[calendar.component(.hour, from: event.completedAt)] += 1
        }
        var peakHour = Self.firstHour
        var peakCount = 0
        for hour in Self.firstHour...Self.lastHour where hourCounts[hour] > peakCount {
            peakHour = hour
            peakCount = hourCounts[hour]
        }
        guard peakCount > 0 else { return .hidden }

        // 带钟点的重要任务的排期钟点(稀缺腿)。
        let highTimed = events.filter { $0.priority == .high && $0.hasDueTime && $0.dueDate != nil }
        guard highTimed.count >= Self.minHighTimed else { return .hidden }
        let highDueHours = highTimed.compactMap { event in
            event.dueDate.map { calendar.component(.hour, from: $0) }
        }
        let lateCount = highDueHours.filter { $0 >= Self.lateStartHour }.count
        let lateRatio = Double(lateCount) / Double(highDueHours.count)

        guard peakHour <= Self.morningEndHour, lateRatio >= Self.lateRatioTrigger else {
            return .hidden
        }

        // 满分效应量 = 重要任务全部排深夜。
        let effect = min(1.0, lateRatio)
        let n = highTimed.count
        let score = InsightEngine.score(normalizedEffect: effect, sampleCount: n, minSample: minSample)

        return .fired(
            InsightResult(
                id: id,
                strength: InsightEngine.strength(score: score, sampleCount: n, minSample: minSample),
                tone: .observation,
                headline: String(localized: "review.insight.energy.headline"),
                body: String(
                    localized: "review.insight.energy.body_\(peakHour)_\(lateCount)_\(highDueHours.count)"
                ),
                viz: .energyWindow(hourCounts: hourCounts, highDueHours: highDueHours, peakHour: peakHour),
                sampleNote: String(
                    localized: "review.insight.energy.sample_note_\(events.count)_\(highTimed.count)"
                ),
                score: score,
                effectSize: effect,
                sampleCount: n
            )
        )
    }
}
