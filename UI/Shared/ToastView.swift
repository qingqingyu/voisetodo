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
    var actionTitle: String?
    var action: (() -> Void)?

    /// 当前自动隐藏的定时器
    @State private var dismissTask: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isPresented {
                    ToastView(message: message, style: style, actionTitle: actionTitle, action: action)
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
                        .padding(.top, WarmSpacing.xxxl)
                        .zIndex(1)
                }
            }
            .animation(WarmAnimation.springSlow, value: isPresented)
    }

    /// 调度自动隐藏（取消旧定时器，启动新定时器）
    private func scheduleDismiss() {
        dismissTask?.cancel()
        let duration = action != nil ? UIConfig.toastDuration * 2 : UIConfig.toastDuration
        let task = DispatchWorkItem {
            withAnimation(WarmAnimation.springStandard) {
                isPresented = false
            }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

/// 轻量级提示组件 - 温暖友好风格
/// 从顶部滑入，自动消失（有按钮时展示更久）
struct ToastView: View {
    let message: String
    let style: ToastStyle
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            ZStack {
                Circle()
                    .fill(style.iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: style.iconName)
                    .foregroundColor(style.iconColor)
                    .font(.system(size: 18))
            }

            Text(message)
                .font(.custom("Avenir Next", size: 15))
                .fontWeight(.medium)
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.custom("Avenir Next", size: 13))
                        .fontWeight(.semibold)
                        .foregroundColor(style.iconColor)
                        .padding(.horizontal, WarmSpacing.sm)
                        .padding(.vertical, WarmSpacing.xs)
                        .background(
                            Capsule()
                                .fill(style.iconColor.opacity(0.12))
                        )
                }
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.sheet)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowMedium, radius: 16, x: 0, y: 8)
        )
        .padding(.horizontal, WarmSpacing.md)
    }
}

// MARK: - View Extension

extension View {
    /// 显示 Toast 提示
    func toast(message: String, style: ToastStyle = .info, isPresented: Binding<Bool>, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        modifier(ToastModifier(message: message, style: style, isPresented: isPresented, actionTitle: actionTitle, action: action))
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
