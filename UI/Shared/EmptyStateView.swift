import SwiftUI

/// 通用空状态组件 - 温暖友好风格
/// 用于 HomeView 和 Widget 无待办时的展示
struct EmptyStateView: View {
    let icon: String
    let message: String
    var iconSize: CGFloat = 60
    var opacity: Double = 0.65

    var body: some View {
        VStack(spacing: 16) {
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
