import SwiftUI

/// 时间标签 chip —— Today 页"时间标签本身是入口"的视觉载体(HTML 设计稿 line 150-176)。
///
/// 四种样式按时间确定度递增:
/// - `.solid`:精确钟点(18:00),彩色底 + 分类色文字,最强
/// - `.soft`:今日的模糊时段(下午),灰底 + 次级文字色,弱一档
/// - `.loose`:待定日期组的模糊时段(下午 · 未定哪天),灰底 + 更轻字重,最弱
/// - `.late`:已过时间状态标签(不可点,不带 dot)
///
/// `onTap != nil` 时包成 `Button`,末尾追加 5pt 圆点作"可点"暗示
/// (HTML `button.chip::after` 的 `opacity:.32`)。
/// **不加独立按钮** —— chip 本身就是入口,宽度零增长,也没有"这里缺东西"的暗示。
///
/// 内层 ChipView 的 Button 与外层卡片 Button 共存:SwiftUI 分派规则最内层 wins,
/// 与 `WarmTodoCard` 的 checkbox Button 同理(line 199-227)。
struct ChipView: View {
    enum Style {
        /// 精确钟点。彩色底 + 分类色文字。
        case solid
        /// 今日有时段无时刻。灰底 + 次级文字色。
        case soft
        /// 待定日期组的模糊时段。灰底 + 更轻字重。
        case loose
        /// 已过时间状态。琥珀底 + 红字。不可点。
        case late
    }

    let text: String
    var style: Style = .solid
    /// 背景色。nil 时按 style 默认推导。
    var tint: Color? = nil
    /// 文字 + dot 色。nil 时按 style 默认推导。
    var accent: Color? = nil
    /// 可点入口。nil 时纯展示(不可点不显示 dot)。
    var onTap: (() -> Void)? = nil
    /// VoiceOver hint,仅在 onTap 非空时使用。
    var accessibilityHintText: String? = nil

    private var resolvedTint: Color {
        if let tint { return tint }
        switch style {
        case .solid:
            return (accent ?? WarmTheme.textSecondary).opacity(0.16)
        case .soft, .loose:
            return WarmTheme.sketch.opacity(0.18)
        case .late:
            return WarmTheme.urgent.opacity(0.15)
        }
    }

    private var resolvedAccent: Color {
        if let accent { return accent }
        switch style {
        case .solid:
            return WarmTheme.textPrimary
        case .soft:
            return WarmTheme.textSecondary
        case .loose:
            return WarmTheme.textMuted
        case .late:
            return WarmTheme.urgent
        }
    }

    private var labelFont: Font {
        switch style {
        case .solid: return WarmFont.caption(12.5)
        case .soft:  return WarmFont.caption(12)
        case .loose: return WarmFont.caption(11.5)
        case .late:  return WarmFont.caption(11)
        }
    }

    var body: some View {
        Group {
            if let onTap {
                Button { onTap() } label: { label }
                    .buttonStyle(.plain)
                    .modifier(OptionalHintModifier(hint: accessibilityHintText))
            } else {
                label
            }
        }
    }

    /// 仅在 hint 非空时挂 `.accessibilityHint`,避免空串在某些 VO 版本上被朗读为空提示。
    private struct OptionalHintModifier: ViewModifier {
        let hint: String?
        func body(content: Content) -> some View {
            if let hint, !hint.isEmpty {
                content.accessibilityHint(hint)
            } else {
                content
            }
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(labelFont)
                .fixedSize(horizontal: true, vertical: false)
            if onTap != nil {
                Circle()
                    .fill(resolvedAccent)
                    .frame(width: 5, height: 5)
                    .opacity(0.32)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(resolvedTint)
        )
        .foregroundColor(resolvedAccent)
        .accessibilityElement(children: .ignore)
    }
}
