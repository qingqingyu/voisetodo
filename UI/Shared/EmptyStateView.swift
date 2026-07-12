import SwiftUI

struct ProductEmptyStateAction: Sendable {
    let title: String
    let systemImage: String?
    let action: @Sendable () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        action: @Sendable @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

/// 产品化空状态组件 - 用于首页和确认页的引导卡片
struct ProductEmptyStateView: View {
    let icon: String
    let title: String
    var message: String?
    var primaryAction: ProductEmptyStateAction?
    var secondaryAction: ProductEmptyStateAction?
    /// 去掉白色卡片容器，让内容直接坐在背景上（首页空状态用 true）。
    var cardless: Bool = false

    @State private var sparkleAnimating = false

    var body: some View {
        content
            .padding(WarmSpacing.lg)
            .frame(maxWidth: .infinity)
            .background(cardless ? nil : background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ProductEmptyState")
    }

    private var content: some View {
        VStack(spacing: WarmSpacing.md) {
            iconBadge

            VStack(spacing: WarmSpacing.xs) {
                Text(title)
                    .font(WarmFont.headline(18))
                    .foregroundColor(WarmTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let message {
                    Text(message)
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actionButtons
        }
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(WarmTheme.primary.opacity(0.12))
                .frame(width: 72, height: 72)

            Circle()
                .fill(WarmTheme.primaryLight.opacity(0.22))
                .frame(width: 48, height: 48)

            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(WarmTheme.primary)
        }
        .opacity(sparkleAnimating ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: sparkleAnimating)
        .onAppear { sparkleAnimating = true }
        .onDisappear { sparkleAnimating = false }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if primaryAction != nil || secondaryAction != nil {
            HStack(spacing: WarmSpacing.xs) {
                if let secondaryAction {
                    Button(action: secondaryAction.action) {
                        actionLabel(secondaryAction)
                            .foregroundColor(WarmTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: WarmSize.touch)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.9))
                                    .overlay(
                                        Capsule()
                                            .stroke(WarmTheme.primary.opacity(0.22), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ProductEmptySecondaryButton")
                }

                if let primaryAction {
                    Button(action: primaryAction.action) {
                        actionLabel(primaryAction)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: WarmSize.touch)
                            .background(
                                Capsule()
                                    .fill(WarmTheme.primary)
                                    .shadow(color: WarmTheme.shadowMedium, radius: 8, x: 0, y: 4)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ProductEmptyPrimaryButton")
                }
            }
            .padding(.top, 2)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
            .fill(Color.white.opacity(0.93))
            .overlay(
                RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                    .stroke(WarmTheme.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: WarmTheme.shadowLight, radius: 10, x: 0, y: 5)
    }

    private func actionLabel(_ action: ProductEmptyStateAction) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            if let systemImage = action.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(action.title)
                .font(WarmFont.headline(15))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, WarmSpacing.sm)
    }
}

/// 通用空状态组件 - 温暖友好风格
/// 用于 HomeView 和 Widget 无待办时的展示
struct EmptyStateView: View {
    let icon: String
    let message: String
    var iconSize: CGFloat = 60
    var opacity: Double = 0.65

    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            ZStack {
                Circle()
                    .fill(WarmTheme.primaryLight.opacity(0.3))
                    .frame(width: iconSize * 2, height: iconSize * 2)

                Circle()
                    .fill(WarmTheme.primaryLight.opacity(0.5))
                    .frame(width: iconSize * 1.4, height: iconSize * 1.4)

                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundColor(WarmTheme.primary)
            }

            Text(message)
                .font(.custom("Avenir Next", size: 17))
                .fontWeight(.medium)
                .foregroundColor(WarmTheme.textPrimary.opacity(opacity))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Convenience Initializers

extension EmptyStateView {
    /// HomeView 空状态
    static func homeEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "sparkles",
            message: String(localized: "empty.home"),
            iconSize: 44,
            opacity: 0.7
        )
    }

    /// Widget 空状态（水印风格）
    static func widgetEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.circle",
            message: String(localized: "empty.widget"),
            iconSize: 28,
            opacity: 0.4
        )
    }

    /// 锁屏 Widget 空状态
    static func lockscreenEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.circle",
            message: "VoiceTodo",
            iconSize: 20,
            opacity: 0.4
        )
    }
}

// MARK: - Preview

#Preview {
    Group {
        // HomeView 空状态
        EmptyStateView.homeEmpty()
            .frame(height: 400)
            .background(WarmTheme.background)

        // Widget 空状态
        EmptyStateView.widgetEmpty()
            .frame(width: 300, height: 150)
            .background(WarmTheme.background)

        // 锁屏 Widget 空状态
        EmptyStateView.lockscreenEmpty()
            .frame(width: 150, height: 80)
            .background(Color.black)
    }
}
