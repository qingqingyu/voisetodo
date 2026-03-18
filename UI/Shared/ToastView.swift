import SwiftUI

/// Toast 样式
enum ToastStyle {
    case info
    case success
    case warning

    var iconColor: Color {
        switch self {
        case .info:
            return .blue
        case .success:
            return Color(red: 0.067, green: 0.725, blue: 0.506) // #10B981
        case .warning:
            return .orange
        }
    }

    var iconName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
}

/// Toast 修饰符
struct ToastModifier: ViewModifier {
    let message: String
    let style: ToastStyle
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isPresented {
                    ToastView(message: message, style: style)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + UIConfig.toastDuration) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isPresented = false
                                }
                            }
                        }
                        .padding(.top, 50)
                        .zIndex(1)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPresented)
    }
}

/// 轻量级提示组件 [v2 新增]
/// 从顶部滑入，2秒后自动消失
struct ToastView: View {
    let message: String
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.iconName)
                .foregroundColor(style.iconColor)
                .font(.system(size: 20))

            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - View Extension

extension View {
    /// 显示 Toast 提示
    func toast(message: String, style: ToastStyle = .info, isPresented: Binding<Bool>) -> some View {
        modifier(ToastModifier(message: message, style: style, isPresented: isPresented))
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ToastView(message: ErrorMessages.noTodosFound, style: .info)
        ToastView(message: ErrorMessages.addedSuccess, style: .success)
        ToastView(message: ErrorMessages.savedOffline, style: .warning)
    }
    .padding()
}
