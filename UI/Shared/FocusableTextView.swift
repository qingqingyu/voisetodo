import SwiftUI
import UIKit

/// UIKit UITextView 包装，用于在 SwiftUI sheet 里**强制可靠地自动聚焦**。
///
/// 为什么不用 SwiftUI `TextEditor` + `@FocusState`：
/// SwiftUI `TextEditor` 的 `.focused()` 在 sheet 里调用 `isInputFocused = true`
/// 经常被吞掉（sheet 完成 present 之前 .task 已执行）。
///
/// 为什么先用 `didMoveToWindow`：
/// sheet 的 present 动画有 200-300ms，而 `DispatchQueue.main.async` 只延迟一个
/// runloop（~1ms），此时 view 还没 attach 到 window，`becomeFirstResponder()`
/// 会被系统拒绝。`didMoveToWindow` 是 UIKit 保证 view 加到 window 后才调的回调，
/// 时机最准；如果 attach 后系统仍暂时拒绝焦点，再做少量短延迟重试。
struct FocusableTextView: UIViewRepresentable {
    @Binding var text: String

    /// 基础字体（Avenir Next Medium，未缩放）。缩放交给系统：
    /// `adjustsFontForContentSizeCategory = true` 会基于 traitCollection 自动按
    /// UIFontMetrics 缩放当前 font，无需（也不应）手动 scaledFont——否则会双重缩放。
    ///
    /// 不变量：baseFont 在 init 后不可变（let）。fontSize 是 struct 的不可变配置，
    /// 调用方若需换字号必须销毁重建 FocusableTextView，而非依赖 updateUIView 同步——
    /// 因为 updateUIView 不再同步 font（避免与系统 Dynamic Type 缩放冲突）。
    /// 当前唯一调用方 BottomInputPanelView 传常量 fontSize，符合此契约。
    private let baseFont: UIFont
    /// 文字颜色（对齐 WarmTheme.textPrimary 浅色模式 #3D3A38）
    private let textColor: UIColor

    init(text: Binding<String>, fontSize: CGFloat = 17) {
        self._text = text
        self.baseFont = UIFont(name: "AvenirNext-Medium", size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .medium)
        // #3D3A38 — WarmTheme.textPrimary 浅色模式值；UIUserInterfaceStyle 锁 Light
        self.textColor = UIColor(red: 0x3D / 255.0, green: 0x3A / 255.0, blue: 0x38 / 255.0, alpha: 1.0)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = FocusableUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        // P0: set 未缩放的 baseFont + 打开 adjustsFontForContentSizeCategory，
        // 系统会在 category 变化时用 UIFontMetrics 自动缩放，单一职责。
        textView.font = baseFont
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = textColor
        // 去掉 UITextView 默认内边距，让文字对齐 SwiftUI 视图布局
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .yes
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.text = text
        // 同步初始 uiText 到 coordinator，避免首次 updateUIView 误判"用户刚改过未同步"。
        context.coordinator.lastKnownUIText = text
        // autoFocus 在 didMoveToWindow 里触发，无需此处主动 becomeFirstResponder
        textView.autoFocusOnAttach = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // 守卫 1：IME 组字期间（存在 marked text）绝不回写 .text：否则会清掉未提交的拼音/候选，
        // 导致中文（搜狗/系统拼音）打不出字、光标跳动。组字提交后 textViewDidChange 同步最终文本。
        // 守卫 2：uiView 刚被用户改过（粘贴/输入）但 binding 异步同步尚未完成时，绝不回写——
        // 否则 updateUIView 会用滞后 binding 把刚粘贴的内容清空（"粘贴不进去"bug）。
        // 通过对比 coordinator.lastKnownUIText 判断 uiView 是否处于"用户改过未同步"状态。
        if uiView.markedTextRange == nil,
           uiView.text == context.coordinator.lastKnownUIText,
           uiView.text != text {
            uiView.text = text
        }
        // 颜色变化时同步（baseFont 不变，Dynamic Type 缩放由系统自动处理）
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        /// 同步 uiView.text 的最新已知值。textViewDidChange 立即更新此字段；
        /// updateUIView 用它判断"text binding 滞后于 uiView"的竞态窗口。
        var lastKnownUIText: String = ""

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            // 仅在非 IME 组字期同步 lastKnownUIText。
            // 组字期 markedTextRange != nil，textView.text 含未提交候选；
            // 此时若写入 lastKnownUIText，组字提交后会因 uiView.text != lastKnownUIText
            // 阻塞合法的外部 reset/clear，并可能误判用户输入。
            if textView.markedTextRange == nil {
                lastKnownUIText = textView.text
            }
            // 防止光标跳动：只有内容真的变了才更新 binding
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }
    }
}

/// UITextView 子类：在 view attach 到 window 后请求焦点，并在失败时有限重试。
private final class FocusableUITextView: UITextView {
    private static let maxFocusAttempts = 3
    private static let focusRetryDelay: TimeInterval = 0.05

    /// 控制位：true 时 didMoveToWindow 会触发 becomeFirstResponder。
    /// 避免后续 view 重 attach（比如从背景回前台）反复抢焦点。
    var autoFocusOnAttach = false
    private var focusAttemptCount = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestFocusIfNeeded()
    }

    private func requestFocusIfNeeded() {
        // window nil = 被移除，不需要处理。
        guard window != nil, autoFocusOnAttach else { return }

        if isFirstResponder {
            focusAttemptCount = 0
            autoFocusOnAttach = false
            return
        }

        guard focusAttemptCount < Self.maxFocusAttempts else {
            autoFocusOnAttach = false
            return
        }

        focusAttemptCount += 1
        if becomeFirstResponder() {
            focusAttemptCount = 0
            autoFocusOnAttach = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRetryDelay) { [weak self] in
            self?.requestFocusIfNeeded()
        }
    }
}
