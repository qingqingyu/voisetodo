import SwiftUI

// MARK: - 洞察 02 · 腐烂任务列表

/// 腐烂任务列表(v1 两图之一)。行可点击 → 跳回第 2 步对应卡片
/// (§阶段 3:指出腐烂却不给处理入口是最糟的设计)。
struct RottingTaskListView: View {
    let items: [RottingVizItem]
    var onOpenTask: ((UUID) -> Void)?

    /// 列表截断:前 5 条 + 「还有 N 条在第 2 步等处理」。
    private static let maxVisible = 5

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.todoId) { index, item in
                row(item, isLast: index == visibleItems.count - 1 && !hasOverflow)
            }
            if hasOverflow {
                Text(String(localized: "review.flow.rotting.more_\(items.count - Self.maxVisible)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleItems: [RottingVizItem] {
        Array(items.prefix(Self.maxVisible))
    }

    private var hasOverflow: Bool {
        items.count > Self.maxVisible
    }

    @ViewBuilder
    private func row(_ item: RottingVizItem, isLast: Bool) -> some View {
        Button {
            onOpenTask?(item.todoId)
        } label: {
            HStack(spacing: WarmSpacing.sm) {
                Text(item.title)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Spacer(minLength: WarmSpacing.xs)

                if item.deferCount > 0 {
                    Text(verbatim: String(repeating: "∕∕ ", count: min(item.deferCount, 5)))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.urgentText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(String(localized: "review.flow.triage.deferred_a11y_\(item.deferCount)"))
                } else {
                    Text(String(localized: "review.flow.rotting.age_\(item.ageDays)"))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WarmTheme.textMuted.opacity(0.6))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.vertical, WarmSpacing.xxs)
        }
        .buttonStyle(.plain)
        if !isLast {
            Rectangle()
                .fill(WarmTheme.rowHairline)
                .frame(height: 1)
        }
    }
}

// MARK: - 洞察 03 · 救火比率条

/// 救火占比横条(v1 两图之一)。一段式比率条 + 两端图例:
/// 填充段 = 救火(ratio),余段 = 计划。SwiftUI 原生绘制,不引 Swift Charts。
struct ReactiveRatioBarView: View {
    let ratio: Double
    let sampleCount: Int

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            GeometryReader { proxy in
                // RTL:用 alignment 而非绝对 x 坐标,SwiftUI 自动镜像。
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(WarmTheme.subtleControlBackground)
                    Capsule()
                        .fill(WarmTheme.primary.opacity(0.85))
                        .frame(width: max(proxy.size.width * min(max(ratio, 0), 1), 8))
                }
            }
            .frame(height: 12)

            HStack(spacing: WarmSpacing.md) {
                legendDot(color: WarmTheme.primary.opacity(0.85), label: String(localized: "review.flow.reactive.legend.reactive"))
                legendDot(color: WarmTheme.subtleControlBackground, label: String(localized: "review.flow.reactive.legend.planned"))
                Spacer(minLength: 0)
                Text(verbatim: "\(sampleCount)")
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: WarmSpacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - 洞察 01 · 中位时长对比条(2026-08-23 启用)

/// 高优 vs 其他的「记下→做完」中位天数对比(viz 形状对齐已批 demo:
/// 两行横条 + 数值;条宽相对较大中位数归一,较短那条保留最小可见宽度)。
/// SwiftUI 原生绘制,不引 Swift Charts。
struct EffortOrderingBarsView: View {
    let highDays: Int
    let otherDays: Int
    let highCount: Int
    let otherCount: Int

    /// 短条的最小可见宽度比例(0 天也能看到一小截)。
    private static let minBarRatio = 0.06

    var body: some View {
        let maxDays = max(highDays, otherDays, 1)
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            row(
                label: String(localized: "review.insight.effort.row.high_\(highCount)"),
                days: highDays,
                ratio: barRatio(highDays, max: maxDays),
                color: WarmTheme.primary
            )
            row(
                label: String(localized: "review.insight.effort.row.other_\(otherCount)"),
                days: otherDays,
                ratio: barRatio(otherDays, max: maxDays),
                color: WarmTheme.textMuted.opacity(0.55)
            )

            Text(String(localized: "review.insight.effort.viz_note"))
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func barRatio(_ days: Int, max maxValue: Int) -> Double {
        max(Double(days) / Double(maxValue), Self.minBarRatio)
    }

    private func row(label: String, days: Int, ratio: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Spacer(minLength: WarmSpacing.xs)

                Text(String(localized: "review.insight.effort.median_days_\(days)"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            GeometryReader { proxy in
                // RTL:alignment 写 .leading,SwiftUI 自动镜像,不碰绝对坐标。
                ZStack(alignment: .leading) {
                    Capsule().fill(WarmTheme.subtleControlBackground)
                    Capsule()
                        .fill(color)
                        .frame(width: max(proxy.size.width * ratio, 6))
                }
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 洞察 05 · 完成时段直方图(2026-08-23 启用)

/// 完成时刻直方图(5–23 点)+ 重要任务排期钟点 ▲ 标记(viz 形状对齐已批 demo:
/// 峰值段绿标、深夜 ▇ 上方红 ▲;不引 Swift Charts)。
struct EnergyWindowBarsView: View {
    /// 24 小时计数(下标 = 小时;0–4 点不画,夜间极少数完成不构成信号)。
    let hourCounts: [Int]
    /// 带钟点的重要任务排的钟点(▲ 标记)。
    let highDueHours: [Int]
    /// 完成高峰小时(绿标)。
    let peakHour: Int

    private static let barMaxHeight: CGFloat = 84
    /// ▲ 标记命中同一小时的堆叠上限(超过 3 个显示 3+ 计数,防撑爆行高)。
    private static let markCap = 3

    private var maxCount: Int {
        max((Self.firstHour...Self.lastHour).map { hourCounts[$0] }.max() ?? 0, 1)
    }

    private static let firstHour = 5
    private static let lastHour = 23
    /// 轴标签:与 19 根等宽柱按列对齐(5→第 0 列、12→第 7、18→第 13、23→第 18)。
    /// 不用等分 Spacer——那样 12/18 会偏离真实柱位。
    private static let axisLabels: [Int: String] = [firstHour: "5", 12: "12", 18: "18", lastHour: "23"]

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Self.firstHour...Self.lastHour, id: \.self) { hour in
                    bar(for: hour)
                }
            }
            .frame(height: Self.barMaxHeight + 16, alignment: .bottom)

            HStack(spacing: 3) {
                ForEach(Self.firstHour...Self.lastHour, id: \.self) { hour in
                    Text(verbatim: Self.axisLabels[hour] ?? "")
                        .font(WarmFont.caption(10))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: WarmSpacing.md) {
                HStack(spacing: WarmSpacing.xxs) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(WarmTheme.success)
                        .frame(width: 9, height: 9)
                    Text(String(localized: "review.insight.energy.legend.peak"))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 8))
                        .foregroundColor(WarmTheme.urgentText)
                        .flipsForRightToLeftLayoutDirection(true)
                    Text(String(localized: "review.insight.energy.legend.mark"))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func bar(for hour: Int) -> some View {
        let count = hourCounts[hour]
        let height = Self.barMaxHeight * CGFloat(count) / CGFloat(maxCount)
        let marks = highDueHours.filter { $0 == hour }.count

        VStack(spacing: 2) {
            if marks > 0 {
                Text(verbatim: marks > Self.markCap ? "3↑" : String(repeating: "▲", count: min(marks, Self.markCap)))
                    .font(WarmFont.caption(9))
                    .foregroundColor(WarmTheme.urgentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(verbatim: " ")
                    .font(WarmFont.caption(9))
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(hour == peakHour ? WarmTheme.success : WarmTheme.divider)
                .frame(height: max(height, count > 0 ? 3 : 1.5))
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
