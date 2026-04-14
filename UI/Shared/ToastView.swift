import SwiftUI

/// Toast 样式 - 温暖主题
enum ToastStyle {
    case info
    case success
    case warning

    var iconColor: Color {
        switch self {
        case .info:
            return Color(hex: "6B8FE8")
        case .success:
            return WarmTheme.success
        case .warning:
            return WarmTheme.warning
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

    /// 当前自动隐藏的定时器
    @State private var dismissTask: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isPresented {
                    ToastView(message: message, style: style)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .scale(scale: 0.9)),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                        .onAppear {
                            scheduleDismiss()
                        }
                        .onChange(of: message) { _, _ in
                            scheduleDismiss()
                        }
                        .padding(.top, 50)
                        .zIndex(1)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPresented)
    }

    /// 调度自动隐藏（取消旧定时器，启动新定时器）
    private func scheduleDismiss() {
        dismissTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isPresented = false
            }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + UIConfig.toastDuration, execute: task)
    }
}

/// 轻量级提示组件 - 温暖友好风格
/// 从顶部滑入，2秒后自动消失
struct ToastView: View {
    let message: String
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                Circle()
                    .fill(style.iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: style.iconName)
                    .foregroundColor(style.iconColor)
                    .font(.system(size: 18))
            }

            // 文字
            Text(message)
                .font(.custom("Avenir Next", size: 15))
                .fontWeight(.medium)
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowMedium, radius: 16, x: 0, y: 8)
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
    .background(WarmTheme.background)
}
