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
/// **Layout 协议契约**:SwiftUI 保证 `placeSubviews` 之前 `sizeThatFits` 一定被
/// 调用过,所以 cache 在 placeSubviews 时已填好——`compute` 逻辑只在
/// `sizeThatFits` 里跑一次,结果缓存供 `placeSubviews` 复用,避免重复计算。
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    /// layout 计算结果缓存。`LayoutSubviews.Element` 是 struct(持有 index +
    /// 父 Subviews 引用),不涉及 class 循环引用。
    struct RowCache {
        var rows: [[(subview: LayoutSubviews.Element, size: CGSize)]]
        var totalHeight: CGFloat
    }

    func makeCache(subviews: Subviews) -> RowCache {
        RowCache(rows: [], totalHeight: 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout RowCache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = compute(maxWidth: maxWidth, subviews: subviews)
        cache = result
        return CGSize(width: proposal.width ?? 0, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout RowCache) {
        var y = bounds.minY
        for row in cache.rows {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            var x = bounds.minX
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

        return RowCache(rows: rows, totalHeight: totalHeight)
    }
}
