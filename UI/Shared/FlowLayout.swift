import SwiftUI

/// 横向流式布局:子视图按 intrinsic 宽度从左到右排列,装不下时换行。
/// 类似 CSS `flex-wrap: wrap` / Flutter `Wrap`。
///
/// **用途**:chip 组等需要"完美容纳"的场景——任何 Dynamic Type 档位(含 AX1-AX5)
/// 或任何语言(中/英/德长词)下,所有 chip 完整可见,不滚动、不缩字、不截断。
/// 默认档位 4 chip 一行;AX5 / 长词撑破屏宽时自动换行到 2 行 / 3 行。
///
/// **要求**:子视图必须暴露稳定的 intrinsic size(对 Text 用 `fixedSize` 或确保
/// 有内在宽度);否则 layout 计算会得到错误结果。
///
/// **Layout 协议契约**:`sizeThatFits` 跑一次 `compute` 把结果缓存供 `placeSubviews`
/// 复用,避免重复计算。但 SwiftUI 在试探阶段可能用 0/nil/极小宽度 proposal 调
/// `sizeThatFits`,产生竖排退化的 cache,被 `placeSubviews` 直接复用就渲染成竖排。
/// 防御:`sizeThatFits` 把 < 1pt 视为「父未决定宽度」按 .infinity 算横排候选 cache;
/// `placeSubviews` 检测 cache 与 bounds 宽度不一致时用 bounds 重算,双保险。
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    /// 每行在 bounds 内的水平对齐:.leading(默认,保持旧行为) / .center / .trailing。
    /// 仅影响 placeSubviews 的行内起点;sizeThatFits 仍回填 proposal.width(填满父宽),
    /// 所以多行时各行按同一对齐方式独立排布。用于图例等需要居中展示的场景。
    var alignment: HorizontalAlignment

    init(
        horizontalSpacing: CGFloat = 8,
        verticalSpacing: CGFloat = 8,
        alignment: HorizontalAlignment = .leading
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.alignment = alignment
    }

    /// layout 计算结果缓存。`LayoutSubviews.Element` 是 struct(持有 index +
    /// 父 Subviews 引用),不涉及 class 循环引用。
    ///
    /// `sourceMaxWidth` 记录算 cache 时使用的原始 maxWidth(可能是 .infinity)。
    /// placeSubviews 用它跟 bounds.width 对比,不一致就重算 cache —— 防御 SwiftUI
    /// Layout 协议在试探阶段用 0/nil proposal 算的 cache 被 place 阶段直接复用、
    /// 不会自动用真实 bounds.width 刷新的陷阱。
    struct RowCache {
        var rows: [[(subview: LayoutSubviews.Element, size: CGSize)]]
        var totalHeight: CGFloat
        var sourceMaxWidth: CGFloat
    }

    func makeCache(subviews: Subviews) -> RowCache {
        // -.infinity 是不可能的 maxWidth 值,保证 placeSubviews 第一次进来时
        // 一定走重算路径(即使 sizeThatFits 没被调用过)。
        RowCache(rows: [], totalHeight: 0, sourceMaxWidth: -.infinity)
    }

    /// SwiftUI 的真实可用宽度不会 < 1pt;任何更小的 proposal 都是 Layout 协议
    /// 试探产物(HStack → Button → label: VStack 深嵌套链路下的 sizing 探测)。
    /// 把它视为「父未决定宽度」,按 .infinity 算横排候选 cache。
    private static let invalidProposalThreshold: CGFloat = 1

    /// 浮点比较容差:SwiftUI 在 sizeThatFits 与 placeSubviews 之间做坐标取整,
    /// 同一逻辑宽度可能差几个小数位。0.5pt 是 SwiftUI 自身 layout 取整的常见步长。
    private static let widthComparisonTolerance: CGFloat = 0.5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout RowCache) -> CGSize {
        let proposed = proposal.width ?? 0
        // SwiftUI Layout 协议陷阱:试探阶段 HStack → Button → label: VStack 这种
        // 深嵌套链路下,VStack 可能给 FlowLayout 一个 0/nil/极小宽度的 proposal。FlowLayout
        // 在该宽度下判断「neededWidth > maxWidth 永远成立」会把每个子换到新行,cache 退化成
        // 竖排单列,placeSubviews 复用此 cache 就渲染成竖排。
        // 把 < invalidProposalThreshold 视为「父未决定宽度」按 .infinity 处理,cache 永远是
        // 横排候选;place 时 bounds.width 不同的话 placeSubviews 会用 bounds.width 重算。
        let maxWidth = proposed < Self.invalidProposalThreshold ? .infinity : proposed
        let result = compute(maxWidth: maxWidth, subviews: subviews)
        cache = result
        return CGSize(width: proposal.width ?? 0, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout RowCache) {
        // 防御 cache 复用陷阱:sizeThatFits 试探阶段用 .infinity 算的 cache(所有点一行)
        // 在 place 阶段若被直接复用,会让一行点数超过 bounds.width 溢出到隔壁 cell。
        // 检测 cache.sourceMaxWidth 与 bounds.width 不一致时,用 bounds.width 重算 cache。
        // 注意:bounds.width 为 0/负数时 SwiftUI 是「无可用宽度」试探(不是真实布局尺寸),
        // compute(.infinity) 已保证横排候选,无需也无意义在此重算。
        if bounds.width > Self.invalidProposalThreshold
            && abs(cache.sourceMaxWidth - bounds.width) > Self.widthComparisonTolerance {
            cache = compute(maxWidth: bounds.width, subviews: subviews)
        }
        var y = bounds.minY
        for row in cache.rows {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            let rowWidth = row.reduce(CGFloat(0)) { partial, item in
                partial + item.size.width
            } + CGFloat(max(0, row.count - 1)) * horizontalSpacing
            let startX: CGFloat
            switch alignment {
            case .center:
                startX = bounds.minX + (bounds.width - rowWidth) / 2
            case .trailing:
                startX = bounds.maxX - rowWidth
            default:
                startX = bounds.minX
            }
            var x = startX
            for (subview, size) in row {
                // 同行内 chip 垂直居中,高度对齐到行最高
                subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    /// layout 算法:贪婪分组——按子视图顺序累计行宽,超过 maxWidth 就开新行。
    /// 单个 chip 自身宽度已超过 maxWidth 时,该 chip 独占一行(layout 不会无限循环,
    /// 因为永远只放 1 个 chip,下一个 chip 仍按同一规则开新行)。
    private func compute(maxWidth: CGFloat, subviews: Subviews) -> RowCache {
        // .infinity 提议(无宽度约束)时用足够大值兜底,避免 CGFloat 溢出比较异常
        let effectiveMaxWidth = maxWidth == .infinity ? Double.greatestFiniteMagnitude : maxWidth

        var rows: [[(subview: LayoutSubviews.Element, size: CGSize)]] = []
        var currentRow: [(subview: LayoutSubviews.Element, size: CGSize)] = []
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // 加入当前行后需要的总宽度(含前缀 spacing)
            let addition = currentRow.isEmpty ? 0 : horizontalSpacing
            let neededWidth = currentRowWidth + addition + size.width

            if neededWidth > effectiveMaxWidth && !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = [(subview, size)]
                currentRowWidth = size.width
            } else {
                currentRow.append((subview, size))
                currentRowWidth = neededWidth
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        let rowHeights = rows.map { $0.map { $0.size.height }.max() ?? 0 }
        let totalHeight = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * verticalSpacing

        return RowCache(rows: rows, totalHeight: totalHeight, sourceMaxWidth: maxWidth)
    }
}
