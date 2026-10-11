import Foundation

/// 洞察 05「精力窗口:好时段在上午,重要的事排在深夜」(2026-08-23 拍板启用,原 v1 预留)。
///
/// 组合信号,两个半句都要成立才触发(组合洞察宁可漏报不误报):
///   1. 完成高峰落在上午(5–11 点)——完成时刻直方图的最大桶;
///   2. 带钟点的重要任务里 ≥50% 排在 22 点后(dueDate 的钟点)。
///
/// v5 拍板 1·3-lite:单腿信号不再整条沉默,降为一行事实(`.fact`)——
/// 完成记录 ≥3 条即可报峰值小时(「完成高峰在 N 点」,扫描 0...23,E3);
/// 带钟点高优 ≥2 件时可报深夜占比(分母与 fired 同,E2)。两腿同时成立
/// 仍走 `.fired` 警示;n<3 才 `.placeholder`。
///
/// fired 样本口径:完成时刻条数走降级阶梯 full 档(minSample = 15,与 03
/// 同级);confidence/strength 用**稀缺腿**(带钟点的重要任务数)——它天然
/// 稀少,本规则长期挂「数据偏少」标签是诚实表现(demo 即如此标)。
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
        // v5 拍板 1·3-lite 事实阈值(C1):峰值腿 ≥3 条完成记录即可出事实;
        // n<3 时两腿素材都出不了 → 占位行兜底(距 fired 15 条的口径不变)。
        guard events.count >= 3 else {
            return .placeholder(needMore: minSample - events.count)
        }

        // 完成时刻直方图。两把扫描窗(E3):fired 的晨型判定沿用 5...23
        // (0–4 点不算「上午」);事实峰值扫描 0...23——凌晨重度用户的真实
        // 峰值必须可见,「说出来不误导」优先。
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
        var factPeakHour = 0
        var factPeakCount = 0
        for hour in 0...23 where hourCounts[hour] > factPeakCount {
            factPeakHour = hour
            factPeakCount = hourCounts[hour]
        }

        // 带钟点的重要任务的排期钟点(稀缺腿;fact 与 fired 同分母,E2)。
        let highTimed = events.filter { $0.priority == .high && $0.hasDueTime && $0.dueDate != nil }
        let lateFactPossible = highTimed.count >= Self.minHighTimed
        let highDueHours = highTimed.compactMap { event in
            event.dueDate.map { calendar.component(.hour, from: $0) }
        }
        let lateCount = highDueHours.filter { $0 >= Self.lateStartHour }.count
        let lateRatio = highDueHours.isEmpty ? 0.0 : Double(lateCount) / Double(highDueHours.count)

        // fired:两腿同时成立(原判定不动)。
        if events.count >= minSample, peakCount > 0,
           peakHour <= Self.morningEndHour, lateFactPossible, lateRatio >= Self.lateRatioTrigger {
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

        // 单腿事实(v5 3-lite)。优先深夜腿(带钟点高优排期,与 fired 同分母
        // 同语义——两档数字可直接对照);否则峰值腿。样本量随文案(F5:n<5
        // 时数字旁即样本数,不呈现无标注的精确钟点)。
        if lateFactPossible {
            return .fact(InsightFactLine(
                id: id,
                text: String(
                    localized: "review.insight.energy.fact_late_\(lateCount)_\(highDueHours.count)"
                ),
                signature: "energyWindow.late|\(lateCount)|\(highDueHours.count)"
            ))
        }
        return .fact(InsightFactLine(
            id: id,
            text: String(
                localized: "review.insight.energy.fact_peak_\(factPeakHour)_\(events.count)"
            ),
            signature: "energyWindow.peak|\(factPeakHour)|\(events.count)"
        ))
    }
}
