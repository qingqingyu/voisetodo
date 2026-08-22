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
