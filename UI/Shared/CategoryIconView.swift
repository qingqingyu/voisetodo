import SwiftUI

/// 分类图标 —— 列表行左侧的分类色 SF Symbol 视觉标识。
///
/// 抽出来作为共享组件:`WarmTodoCard` 和 `PendingDateTodoRow` 都需要这个视觉元素,
/// 但后者不想直接复用整个 `WarmTodoCard`(配置参数太多,语义也不一样)。
/// 单一来源避免两处样式分叉——后续改图标样式只改这里。
///
/// **视觉规则**:
/// - 无底色。历史上是「分类色圆底 @16% + 实心 symbol」,在分组卡片里每行都顶出一个色圆,
///   十几行排下来像一列徽章,压过了标题本身。用户 2026-08-08 反馈:
///   「不是那种有一个圆环凸出来的,而是线性的图标」。
/// - 图标:`category.outlineSymbolName`(线性变体),16pt regular,分类色;
///   已完成态切到 textMuted 灰。
/// - 外层固定方形 frame:7 个分类的 symbol 天然宽度不等(`person.2` 比 `tag` 宽一截),
///   不锁宽的话每行标题的左边缘会参差。锁死后一列标题对齐成一条线。
/// - 尺寸跟随 Dynamic Type(`.body` relativeTo),避免 AX5 字变大图标不变。
struct CategoryIconView: View {
    let category: TodoCategory
    var isCompleted: Bool = false

    /// 图标占位方框边长。基准 24pt,跟标题字号(WarmFont.body(15) → .body textStyle)同步缩放。
    /// 取 24 而非贴着字号的 16:最宽的 `person.2` 在 16pt 下约 22pt 宽,方框留出余量才不会
    /// 被挤到贴边。用户原话:「任务卡片的分类图标用 @ScaledMetric 定尺寸」。
    @ScaledMetric(relativeTo: .body) private var iconBoxSize: CGFloat = 24
    /// SF Symbol 字号。基准 16pt,同步跟随 .body 缩放。
    @ScaledMetric(relativeTo: .body) private var iconFontSize: CGFloat = 16

    private var categoryColor: Color {
        WarmTheme.color(for: category)
    }

    var body: some View {
        Image(systemName: category.outlineSymbolName)
            .font(.system(size: iconFontSize, weight: .regular))
            .foregroundColor(isCompleted ? WarmTheme.textMuted : categoryColor)
            // 定宽方框 + 居中:窄 symbol(tag)两侧留白,宽 symbol(person.2)也不越界,
            // 占位宽度恒等于 iconBoxSize → 一列标题的左边缘对齐成一条线。
            .frame(width: iconBoxSize, height: iconBoxSize)
    }
}

// MARK: - Preview

#if DEBUG

#Preview("CategoryIconView — 所有分类 × 完成态") {
    VStack(spacing: WarmSpacing.md) {
        // 未完成:分类色底 + 分类色图标
        HStack(spacing: WarmSpacing.md) {
            ForEach(TodoCategory.allCases, id: \.self) { cat in
                CategoryIconView(category: cat)
            }
        }
        // 已完成:灰底 + 灰图标
        HStack(spacing: WarmSpacing.md) {
            ForEach(TodoCategory.allCases, id: \.self) { cat in
                CategoryIconView(category: cat, isCompleted: true)
            }
        }
    }
    .padding()
    .background(WarmTheme.background)
}

#endif
