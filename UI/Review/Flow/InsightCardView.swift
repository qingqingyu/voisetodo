import SwiftUI

/// 洞察卡容器(阶段 3,§阶段 3 · 第 3 步)。
/// 布局约定:右上角信号强度标签、右下角样本量说明、底部规则按钮。
/// 入场动画复用 `CardEntranceModifier` 的 stagger 模式(滚动进入视野时播)。
struct InsightCardView: View {
    let result: InsightResult
    /// 规则按钮回调(suggestedRule 由本视图按 insightID 构造,v1 只存储)。
    let onSaveRule: (ReviewRule) -> Void
    /// 腐烂卡的任务点击 → 跳回第 2 步对应卡片(仅 rotting 卡传入非 nil)。
    var onOpenTask: ((UUID) -> Void)? = nil

    @State private var appeared = false
    /// 折叠机制保留但 v1 常空载(§阶段 3):强信号默认展开,其余折叠成「还有 N 个观察」。
    /// v1 只有两张卡,暂不启用折叠,字段留给规则扩到 4+ 条时接 A/B。
    @State private var expanded = true

    var body: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                HStack(alignment: .top, spacing: WarmSpacing.sm) {
                    Text(result.headline)
                        .font(WarmFont.headline(16))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: WarmSpacing.xs)

                    strengthBadge
                }

                Text(result.body)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                vizView

                // §2.4:冷却因「效应量变好」放行时换好转语气——复盘只报坏消息,
                // 用户会停止复盘。
                if result.tone == .improving {
                    // 方向敏感图标(RTL 规则 2):improving 箭头随布局方向翻转。
                    Label(String(localized: "review.flow.insights.improving"), systemImage: "arrow.down.right.circle.fill")
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.success)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .flipsForRightToLeftLayoutDirection(true)
                }

                HStack(alignment: .bottom) {
                    Text(result.sampleNote)
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)

                    Spacer(minLength: WarmSpacing.xs)
                }

                ruleButton
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(WarmAnimation.springEntrance) { appeared = true }
        }
        .accessibilityIdentifier("ReviewFlowInsightCard_\(result.id.rawValue)")
    }

    // MARK: 强度标签(右上)

    private var strengthBadge: some View {
        Text(strengthText)
            .font(WarmFont.caption(10))
            .foregroundColor(badgeColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, WarmSpacing.xs)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeColor.opacity(0.12)))
    }

    private var strengthText: String {
        switch result.strength {
        case .high: return String(localized: "review.flow.strength.high")
        case .medium: return String(localized: "review.flow.strength.medium")
        case .lowData: return String(localized: "review.flow.strength.low_data")
        }
    }

    private var badgeColor: Color {
        switch result.strength {
        case .high: return WarmTheme.urgentText
        case .medium: return WarmTheme.warningText
        case .lowData: return WarmTheme.textMuted
        }
    }

    // MARK: 图

    /// 图表用 SwiftUI 原生绘制(GeometryReader + RoundedRectangle),不引 Swift Charts
    /// (§阶段 3:现有分类图当初就从 SectorMark 换回了手写横条)。
    @ViewBuilder
    private var vizView: some View {
        switch result.viz {
        case .rotting(let items):
            RottingTaskListView(items: items, onOpenTask: onOpenTask)
        case .reactiveVsPlanned(let ratio, let sampleCount):
            ReactiveRatioBarView(ratio: ratio, sampleCount: sampleCount)
        default:
            EmptyView()
        }
    }

    // MARK: 规则按钮

    /// 「存下这条规则」:点了带到第 4 步「这次存下的规则」并计入最后的账(§阶段 3)。
    private var ruleButton: some View {
        Button {
            onSaveRule(ReviewRule(
                insightID: result.id,
                text: suggestedRuleText,
                createdAt: Date()
            ))
            HapticFeedback.light()
        } label: {
            Label(String(localized: "review.flow.insights.rule_button"), systemImage: "bookmark")
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xxs)
                .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// v1 规则文本按 insightID 给固定建议文案(用户阶段 4 可改;引擎 suggestedRule 恒 nil)。
    private var suggestedRuleText: String {
        switch result.id {
        case .rotting: return String(localized: "review.flow.rule.suggested.rotting")
        case .reactiveVsPlanned: return String(localized: "review.flow.rule.suggested.reactive")
        default: return result.headline
        }
    }
}
