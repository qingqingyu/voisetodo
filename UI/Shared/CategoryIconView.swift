import SwiftUI

/// 分类图标圆 —— 卡片左侧的分类色 SF Symbol 视觉标识。
///
/// 抽出来作为共享组件:`WarmTodoCard` 和 `PendingDateTodoRow` 都需要这个视觉元素,
/// 但后者不想直接复用整个 `WarmTodoCard`(配置参数太多,语义也不一样)。
/// 单一来源避免两处样式分叉——后续改图标样式只改这里。
///
/// **视觉规则**:
/// - 圆底色:分类色 @ 16% 不透明度(已完成态切到 textMuted 灰)
/// - 图标:`category.sfSymbolName`,12pt semibold,分类色(已完成态切到 textSecondary)
/// - 尺寸跟随 Dynamic Type(`.body` relativeTo),避免 AX5 字变大图标不变
struct CategoryIconView: View {
    let category: TodoCategory
    var isCompleted: Bool = false

    /// 圆背景尺寸。基准 28pt,跟标题字号(WarmFont.body(15) → .body textStyle)同步缩放。
    /// 用户原话:「任务卡片的分类图标用 @ScaledMetric 定尺寸」。
    @ScaledMetric(relativeTo: .body) private var iconCircleSize: CGFloat = 28
    /// SF Symbol 字号。基准 12pt,同步跟随 .body 缩放。
    @ScaledMetric(relativeTo: .body) private var iconFontSize: CGFloat = 12

    private var categoryColor: Color {
        WarmTheme.color(for: category)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isCompleted ? WarmTheme.textMuted.opacity(0.16) : categoryColor.opacity(0.16))
                .frame(width: iconCircleSize, height: iconCircleSize)

            Image(systemName: category.sfSymbolName)
                .font(.system(size: iconFontSize, weight: .semibold))
                .foregroundColor(isCompleted ? WarmTheme.textSecondary : categoryColor)
        }
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
