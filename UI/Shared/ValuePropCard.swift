import SwiftUI

/// 可复用的「价值主张卡片」:emoji 圆 + 标题 + 描述。
///
/// 用于在多个入口(Onboarding 欢迎页、Paywall 价值主张区等)统一展示产品价值,
/// 保证设计语言一致。视觉规格对齐 `WarmTheme` / `WarmFont`,布局遵循项目
/// 文本规则(`lineLimit` + `minimumScaleFactor`、`HStack` 主文本 `layoutPriority(1)`)。
struct ValuePropCard: View {
    let emoji: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: WarmSpacing.md) {
            // Emoji 圆圈
            Text(emoji)
                .font(.system(size: 28))
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(WarmTheme.cardBackground)
                        .shadow(color: WarmTheme.sketch.opacity(0.1), radius: 4, y: 2)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(title)
                    .font(WarmFont.headline(18))
                    .foregroundColor(WarmTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)

                Text(description)
                    .font(WarmFont.caption(15))
                    .foregroundColor(WarmTheme.sketch)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
        .padding(WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.sketch.opacity(0.08), radius: 8, y: 4)
        )
        .overlay(
            // 手绘边框效果(对齐 OnboardingView 既有风格)
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .stroke(WarmTheme.sketch.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview("ValuePropCard") {
    VStack(spacing: 12) {
        ValuePropCard(
            emoji: "🎯",
            title: "Higher daily quota",
            description: "From 100 to unlimited voice extractions per day"
        )
        ValuePropCard(
            emoji: "🎁",
            title: "3-day free trial",
            description: "Continue only if you love it — cancel anytime"
        )
    }
    .padding()
    .background(WarmTheme.background)
}
