import SwiftUI

/// 洞察卡容器(阶段 3,§阶段 3 · 第 3 步;v6 A2 视觉改版)。
/// 布局约定(v6):标题在左(第一张规则卡一级 24pt,其余二级 19pt);强度
/// 不再是右上角胶囊——挪到底部样本说明行右侧的灰字 + 信号图标,不可点、
/// 看起来也不像按钮。正文不截断(§1.3)。
/// (2026-08-22 拍板:「存成规则」按钮移除——回访砍掉后规则只剩展示+计数,整链路删除。)
/// 入场动画复用 `CardEntranceModifier` 的 stagger 模式(滚动进入视野时播)。
struct InsightCardView: View {
    let result: InsightResult
    /// v6:第一张规则卡标题用一级字号(每步最多一个一级,§1.2)。
    var isLeadingCard: Bool = false
    /// 腐烂卡的任务点击 → 跳回第 2 步对应卡片(仅 rotting 卡传入非 nil)。
    var onOpenTask: ((UUID) -> Void)? = nil
    /// 腐烂卡任务行尾「不做了」当场动作(2026-09-01 v2,仅 rotting 卡传入)。
    var onAbandonTask: ((UUID) -> Void)? = nil

    @State private var appeared = false

    var body: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(result.headline)
                    .font(isLeadingCard ? WarmFont.title(24) : WarmFont.headline(19))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                // v6 §2 第 3 步:救火/计划卡不渲染 body——标题已有百分比,
                // 同页出现两次「61%」是重复;其余规则卡 body 照旧(不截断)。
                if result.id != .reactiveVsPlanned {
                    Text(result.body)
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                HStack(alignment: .firstTextBaseline) {
                    Text(result.sampleNote)
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: WarmSpacing.xs)

                    // 短标签固定宽度(不让长样本说明把它挤成省略号;长说明在
                    // 剩余宽度内自然换行)。
                    signalLabel.fixedSize()
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(WarmAnimation.springEntrance) { appeared = true }
        }
        .accessibilityIdentifier("ReviewFlowInsightCard_\(result.id.rawValue)")
    }

    // MARK: 强度(底部样本行右侧,v6)

    /// 灰字 + 信号图标(三档文案不变:信号强/中/数据偏少),一律 `textMuted`,
    /// 不可点——全局视觉规则 1:不可点的标签不用警示色作底/描边/文字。
    private var signalLabel: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "cellularbars")
                .font(.system(size: 11, weight: .semibold))
                .flipsForRightToLeftLayoutDirection(true)

            Text(strengthText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(WarmFont.caption(12))
        .foregroundColor(WarmTheme.textMuted)
        .accessibilityElement(children: .combine)
    }

    private var strengthText: String {
        switch result.strength {
        case .high: return String(localized: "review.flow.strength.high")
        case .medium: return String(localized: "review.flow.strength.medium")
        case .lowData: return String(localized: "review.flow.strength.low_data")
        }
    }

    // MARK: 图

    /// 图表用 SwiftUI 原生绘制(GeometryReader + RoundedRectangle),不引 Swift Charts
    /// (§阶段 3:现有分类图当初就从 SectorMark 换回了手写横条)。
    @ViewBuilder
    private var vizView: some View {
        switch result.viz {
        case .rotting(let items):
            RottingTaskListView(items: items, onOpenTask: onOpenTask, onAbandonTask: onAbandonTask)
        case .reactiveVsPlanned(let ratio, let sampleCount):
            // ratio = 救火/总数,两组件数由它精确还原(v6:图例带件数)。
            let reactive = Int((ratio * Double(sampleCount)).rounded())
            ReactiveRatioBarView(
                ratio: ratio,
                reactiveCount: reactive,
                plannedCount: sampleCount - reactive
            )
        case .effortOrdering(let highDays, let otherDays, let highCount, let otherCount):
            EffortOrderingBarsView(
                highDays: highDays,
                otherDays: otherDays,
                highCount: highCount,
                otherCount: otherCount
            )
        case .energyWindow(let hourCounts, let highDueHours, let peakHour):
            EnergyWindowBarsView(
                hourCounts: hourCounts,
                highDueHours: highDueHours,
                peakHour: peakHour
            )
        default:
            EmptyView()
        }
    }
}
