import SwiftUI

/// 分组卡片的公共部件 —— 把一个 `List` Section 内的若干行拼成**一张**白色圆角卡。
///
/// 背景:Today 列表原来是「每条待办一张独立白卡 + 4pt 间隙」。条目一多,屏幕上就是
/// 十几张漂浮的小卡片,用户 2026-08-08 反馈「杂乱」。改成设计稿的做法——同一分组
/// 合成一张卡,条目之间用一条淡发丝线隔开,线的左端与分类图标对齐。
///
/// 实现走 `listRowBackground` 而不是 `LazyVStack`:Today 列表依赖 `List` 的
/// `swipeActions`(左滑删除)、`onMove`(「稍后」分区拖拽排序)和行级 a11y,
/// 换成自绘容器这些全要重写。这里只接管**行的外观**,List 的行为一律不动。
///
/// 用法:
/// ```swift
/// ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
///     row(item)
///         .groupedCardRow(GroupedRowPosition(index: idx, count: items.count), height: .compact)
/// }
/// ```
enum GroupedRowPosition {
    /// 分组内第一行:圆上面两个角。
    case first
    /// 中间行:四个角都是直角。
    case middle
    /// 分组内最后一行:圆下面两个角,且不画底部发丝线。
    case last
    /// 分组只有这一行:四个角全圆。
    case only

    /// 从「第几行 / 共几行」推导位置。调用方通常只有 index 和 count,
    /// 让每个 Section 各自写一遍 if-else 容易写歪(尤其 count==1 的退化情况)。
    init(index: Int, count: Int) {
        switch (index == 0, index == count - 1) {
        case (true, true): self = .only
        case (true, false): self = .first
        case (false, true): self = .last
        case (false, false): self = .middle
        }
    }

    var isTop: Bool { self == .first || self == .only }
    var isBottom: Bool { self == .last || self == .only }
}

/// 设计稿只允许的几档行高。用枚举而不是裸 CGFloat,免得调用点随手传出第三档。
enum GroupedRowHeight {
    /// 56pt:只有一行标题。
    case compact
    /// 76pt:标题 + 副行(钟点 / 「每两周」/ 「选日期」按钮)。
    case tall
    /// 28pt:卡内 tier 小标题条。
    case subhead
}

extension View {
    /// 把本行渲染成分组卡片的一段。
    ///
    /// - Parameters:
    ///   - position: 本行在分组内的位置,决定圆角落在哪几个角。
    ///   - height: 行高档位(最小高度,内容更高时照常撑开)。
    ///   - fill: 行底色,默认白卡;tier 小标题条传 `WarmTheme.subheadBackground`。
    ///   - showsHairline: 底部发丝线。默认按 `position` 自动决定(最后一行不画);
    ///     传 false 可强制关掉——下一行是 tier 灰条时用,灰条本身已经是分隔带,
    ///     再叠一条线会显脏。
    func groupedCardRow(
        _ position: GroupedRowPosition,
        height: GroupedRowHeight = .compact,
        fill: Color? = nil,
        showsHairline: Bool = true
    ) -> some View {
        modifier(
            GroupedCardRowModifier(
                position: position,
                height: height,
                fill: fill,
                showsHairline: showsHairline
            )
        )
    }
}

private struct GroupedCardRowModifier: ViewModifier {
    let position: GroupedRowPosition
    let height: GroupedRowHeight
    let fill: Color?
    let showsHairline: Bool

    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = WarmSize.rowCompact
    @ScaledMetric(relativeTo: .body) private var tallHeight: CGFloat = WarmSize.rowTall
    @ScaledMetric(relativeTo: .caption2) private var subheadHeight: CGFloat = WarmSize.rowSubhead
    @ScaledMetric(relativeTo: .body) private var hairlineLeading: CGFloat = WarmSize.rowContentLeading

    private var minHeight: CGFloat {
        switch height {
        case .compact: return compactHeight
        case .tall: return tallHeight
        case .subhead: return subheadHeight
        }
    }

    private var cornerRadius: CGFloat { WarmRadius.section }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsHairline && !position.isBottom {
                    Rectangle()
                        .fill(WarmTheme.rowHairline)
                        // 0.5pt 而不是 1pt:1pt 在 3x 屏上是 3 个物理像素,在白卡上读起来像"切割"。
                        .frame(height: 0.5)
                        .padding(.leading, hairlineLeading)
                        .padding(.trailing, WarmSpacing.md)
                }
            }
            // 卡片左右各留 lg(20) 页边距。listRowInsets 归零后由这里接管——
            // 因为 listRowBackground 填的是**整个 row cell**(不受 listRowInsets 影响),
            // 想让卡片也内缩,只能让背景形状自己带同样的 padding(见下方)。
            .padding(.horizontal, WarmSpacing.lg)
            .listRowInsets(EdgeInsets())
            // 系统分隔线一律关掉,发丝线由上面的 overlay 自绘:
            // 系统线的 inset 只能靠 alignmentGuide 调,且不跟随卡片圆角收口。
            .listRowSeparator(.hidden)
            .listRowBackground(
                UnevenRoundedRectangle(
                    topLeadingRadius: position.isTop ? cornerRadius : 0,
                    bottomLeadingRadius: position.isBottom ? cornerRadius : 0,
                    bottomTrailingRadius: position.isBottom ? cornerRadius : 0,
                    topTrailingRadius: position.isTop ? cornerRadius : 0
                )
                .fill(fill ?? WarmTheme.cardBackground)
                .padding(.horizontal, WarmSpacing.lg)
            )
    }
}

/// 分组卡片内部的 tier 小标题条(设计稿 HTML 的 `.subhead`)。
///
/// Today 分区内部还有「整天 / 上午 / 下午 / 晚上 / 按时间」几档。原来这些标签是卡片
/// **外面**的独立文字行,靠上下不对称留白分组;卡片合并之后,标签必须收进卡内,
/// 否则一张卡会被文字行切成好几段、失去"一整块"的观感。
///
/// 不挂 a11y —— tier 语义已由每行卡片自己的时间信息承载,VoiceOver 再读一遍标签是噪音。
struct GroupedCardSubheadRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(WarmFont.caption(11))
            .tracking(0.8)
            .foregroundColor(WarmTheme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, WarmSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: - Preview

#if DEBUG

/// 一张卡里混排:tier 灰条 + 56pt 行 + 76pt 行 + 首/中/尾圆角。
/// 这是本次改版最容易出问题的组合——圆角只该出现在整组的头尾,
/// 发丝线只该出现在两条内容行之间(灰条上下不画)。
#Preview("GroupedCardRow — 混排行高与圆角") {
    List {
        Section {
            GroupedCardSubheadRow(text: "上午")
                .groupedCardRow(.first, height: .subhead, fill: WarmTheme.subheadBackground, showsHairline: false)

            Text(verbatim: "改江西批次号")
                .font(WarmFont.body(15))
                .padding(.leading, WarmSize.rowContentLeading)
                .groupedCardRow(.middle, height: .compact)

            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(verbatim: "做大扫除")
                    .font(WarmFont.body(15))
                Text(verbatim: "每两周一次 · 上次 7 月 25 日")
                    .font(WarmFont.caption(10))
                    .foregroundColor(WarmTheme.textSecondary)
            }
            .padding(.leading, WarmSize.rowContentLeading)
            .groupedCardRow(.middle, height: .tall, showsHairline: false)

            GroupedCardSubheadRow(text: "下午")
                .groupedCardRow(.middle, height: .subhead, fill: WarmTheme.subheadBackground, showsHairline: false)

            Text(verbatim: "对账复盘会")
                .font(WarmFont.body(15))
                .padding(.leading, WarmSize.rowContentLeading)
                .groupedCardRow(.last, height: .compact)
        }

        Section {
            Text(verbatim: "只有一行的分组(四角全圆)")
                .font(WarmFont.body(15))
                .padding(.leading, WarmSize.rowContentLeading)
                .groupedCardRow(.only, height: .compact)
        }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WarmTheme.background)
}

#Preview("GroupedCardRow — AX5 字号") {
    List {
        Section {
            Text(verbatim: "整理并测试陕西外联改动,这条标题足够长以至于会换行")
                .font(WarmFont.body(15))
                .padding(.leading, WarmSize.rowContentLeading)
                .groupedCardRow(.first, height: .compact)

            Text(verbatim: "还钱")
                .font(WarmFont.body(15))
                .padding(.leading, WarmSize.rowContentLeading)
                .groupedCardRow(.last, height: .compact)
        }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WarmTheme.background)
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#endif
