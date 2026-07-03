import SwiftUI
import UIKit

/// UIKit UITextView 包装，用于在 SwiftUI sheet 里**强制可靠地自动聚焦**。
///
/// 为什么不用 SwiftUI `TextEditor` + `@FocusState`：
/// SwiftUI `TextEditor` 的 `.focused()` 在 sheet 里调用 `isInputFocused = true`
/// 经常被吞掉（sheet 完成 present 之前 .task 已执行）。改用 UIKit
/// `becomeFirstResponder()` 是 100% 可靠的方式，绕过 SwiftUI focus 系统的时机问题。
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
        let textView = UITextView()
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

        // 关键：在 view 加入窗口层级之后再 becomeFirstResponder。
        // DispatchQueue.main.async 让它在下一 runloop 执行，确保 view 已 attached。
        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
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
