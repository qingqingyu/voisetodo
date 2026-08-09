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
    /// Toast 显示位置。默认 `.top`(现有 TodoDetailView / VoiceTodoApp 调用不动),
    /// 流式期间点击卡片的反馈用 `.bottom` —— 落在 sheet 安全区上方,
    /// 不遮卡片内容,且语义上是「响应操作的临时提示」而非「常驻状态」。
    enum Position {
        case top, bottom

        /// overlay 对齐方向(供 SwiftUI .overlay(alignment:) 用)。
        var alignment: Alignment {
            switch self {
            case .top:    return .top
            case .bottom: return .bottom
            }
        }

        /// transition 滑入边缘(供 .move(edge:) 用)。
        var edge: Edge {
            switch self {
            case .top:    return .top
            case .bottom: return .bottom
            }
        }

        /// overlay 内的 padding 方向(供 .padding(_:, _) 用)。
        var edgeInsets: Edge.Set {
            switch self {
            case .top:    return .top
            case .bottom: return .bottom
            }
        }
    }

    let message: String
    let style: ToastStyle
    @Binding var isPresented: Bool
    var position: Position = .top
    var actionTitle: String?
    var action: (() -> Void)?
    /// 重展示令牌:调用方每次想"重新触发完整 dismiss 计时"时递增。
    /// 解决 isPresented 已为 true 时再次 true→true 不触发 onChange 的问题
    /// (SwiftUI @State 同帧合并 → 只保留终值 → onChange 不发)。
    /// 用独立 token 绕开 isPresented 的去重,保证连点连触发都能重置定时器。
    var presentationToken: Int = 0
    /// 底部 toast 距容器底的额外间距(覆盖默认 `WarmSpacing.xxxl`)。
    /// 仅 `.bottom` 位置需要避让 VoiceFAB 等 overlay 控件时由调用方传入;
    /// 默认 nil → 沿用 `WarmSpacing.xxxl`,现有调用方零影响。
    var bottomPadding: CGFloat? = nil

    /// 当前自动隐藏的定时器
    @State private var dismissTask: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: position.alignment) {
                if isPresented {
                    ToastView(message: message, style: style, actionTitle: actionTitle, action: action)
                        .transition(.asymmetric(
                            insertion: .move(edge: position.edge).combined(with: .scale(scale: 0.9)),
                            removal: .move(edge: position.edge).combined(with: .opacity)
                        ))
                        .padding(position.edgeInsets, bottomPadding ?? WarmSpacing.xxxl)
                        // 无 action 的 toast 不需要接收点击,关掉 hit testing
                        // 避免底部 toast 期间遮住悬浮 FAB(成功 toast 寿命 2s,
                        // 恰好是用户最可能想立刻再录一条的时刻)。
                        .allowsHitTesting(action != nil)
                        .zIndex(1)
                }
            }
            .animation(WarmAnimation.springSlow, value: isPresented)
            // 自动消失定时器挂在 isPresented 的变化上,而不是 ToastView.onAppear。
            // 原因:ToastView 是 `if isPresented` 条件渲染,只要 content 重渲染(用户改字段
            // 触发 store 变化 → view tree 重渲染),ToastView 就被销毁重建,.onAppear
            // 会反复触发,cancel + 重启 2s 定时器 → toast 在用户持续操作期间永不消失。
            // 改用 onChange(of: isPresented) 只在 false→true 瞬间调度一次,重渲染不会重启。
            .onChange(of: isPresented) { _, presented in
                if presented {
                    scheduleDismiss()
                }
            }
            // presentationToken 变化时(调用方连续触发同一条 toast):
            // isPresented 可能已经为 true → true→true 不触发 onChange,
            // 用 token 这个单调递增计数器绕过去重,每次点击都重新调度 dismiss,
            // 让后续触发的 toast 仍享完整 duration,不被前一次的剩余计时截断。
            .onChange(of: presentationToken) { _, token in
                guard token > 0 else { return }
                scheduleDismiss()
            }
            // message 变化(用户连续触发不同文案的 toast)时重置定时器,
            // 让最新一条 toast 仍按完整 duration 显示。
            .onChange(of: message) { _, _ in
                if isPresented {
                    scheduleDismiss()
                }
            }
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
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(WarmFont.headline(13))
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
        .accessibilityIdentifier("Toast")
    }
}

// MARK: - View Extension

extension View {
    /// 显示 Toast 提示
    /// - Parameters:
    ///   - position: `.top` 从顶部滑入(默认,现有调用),`.bottom` 从底部滑入
    ///     (流式点击反馈等"响应用户操作的临时提示",不遮卡片内容)。
    ///   - presentationToken: 调用方递增此值可在 isPresented 已为 true 时强制重置 dismiss 计时,
    ///     用于"连续点击不同卡片但 toast 文案相同"的场景。默认 0 = 不参与重置。
    func toast(
        message: String,
        style: ToastStyle = .info,
        isPresented: Binding<Bool>,
        position: ToastModifier.Position = .top,
        presentationToken: Int = 0,
        bottomPadding: CGFloat? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(ToastModifier(
            message: message,
            style: style,
            isPresented: isPresented,
            position: position,
            actionTitle: actionTitle,
            action: action,
            presentationToken: presentationToken,
            bottomPadding: bottomPadding
        ))
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
