import SwiftUI

/// 通用空状态组件 [v2 新增]
/// 用于 HomeView 和 Widget 无待办时的展示
struct EmptyStateView: View {
    let icon: String
    let message: String
    var iconSize: CGFloat = 60
    var opacity: Double = 0.65

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .light))
                .foregroundColor(.primary.opacity(opacity))

            Text(message)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.primary.opacity(opacity))
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
            icon: "checkmark.circle",
            message: "暂无待办，按下 Action Button 开始录入",
            iconSize: 60,
            opacity: 0.65
        )
    }

    /// Widget 空状态（水印风格）
    static func widgetEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.circle",
            message: "暂无待办",
            iconSize: 40,
            opacity: 0.4
        )
    }

    /// 锁屏 Widget 空状态
    static func lockscreenEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.circle",
            message: "VoiceTodo",
            iconSize: 24,
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
            .background(Color(.systemBackground))

        // Widget 空状态
        EmptyStateView.widgetEmpty()
            .frame(width: 300, height: 150)
            .background(Color(.systemBackground))

        // 锁屏 Widget 空状态
        EmptyStateView.lockscreenEmpty()
            .frame(width: 150, height: 80)
            .background(Color(.systemBackground))
    }
}
