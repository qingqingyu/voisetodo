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

    /// 字体（Avenir Next Medium，对齐 WarmFont.body）
    private let font: UIFont
    /// 文字颜色（对齐 WarmTheme.textPrimary 浅色模式 #3D3A38）
    private let textColor: UIColor

    init(text: Binding<String>, fontSize: CGFloat = 17) {
        self._text = text
        self.font = UIFont(name: "AvenirNext-Medium", size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .medium)
        // #3D3A38 — WarmTheme.textPrimary 浅色模式值；UIUserInterfaceStyle 锁 Light
        self.textColor = UIColor(red: 0x3D / 255.0, green: 0x3A / 255.0, blue: 0x38 / 255.0, alpha: 1.0)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = FocusableUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = font
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
        // autoFocus 在 didMoveToWindow 里触发，无需此处主动 becomeFirstResponder
        textView.autoFocusOnAttach = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // 防止循环：只有外部 text 与当前不一致才更新
        if uiView.text != text {
            uiView.text = text
        }
        // 字体/颜色变化时同步
        if uiView.font !== font {
            uiView.font = font
        }
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
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
