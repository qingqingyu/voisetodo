import SwiftUI
import UIKit

/// UIKit UITextView 包装，用于在 SwiftUI sheet 里**强制可靠地自动聚焦**，
/// 以及**编辑期间光标稳定**的多行文本编辑。
///
/// 为什么不用 SwiftUI `TextEditor` + `@FocusState`：
/// SwiftUI `TextEditor` 的 `.focused()` 在 sheet 里调用 `isInputFocused = true`
/// 经常被吞掉（sheet 完成 present 之前 .task 已执行）。
///
/// 为什么不用 SwiftUI `TextField(axis: .vertical)`（详情页标题/备注的教训）：
/// 详情页编辑期间高频重渲染（每次 keystroke 写 @State、keyboardWillShow 翻状态、
/// 防抖保存回写基准 + toast），原生多行 TextField 会在这些 SwiftUI 更新中重铺文本，
/// 把光标重置到末尾——用户在中间插字，光标瞬跳最后。UITextView 只要不在编辑期
/// 重设 `.text`（updateUIView 的组字/竞态守卫保证）就天然保留选区。
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
    /// 不变量：baseFont 在 init 后不可变（let）。fontName/fontSize 是 struct 的不可变配置，
    /// 调用方若需换字体/字号必须销毁重建 FocusableTextView，而非依赖 updateUIView 同步——
    /// 因为 updateUIView 不再同步 font（避免与系统 Dynamic Type 缩放冲突）。
    /// 当前调用方(BottomInputPanelView / UnparsedTranscriptEditSheet / TodoDetailView /
    /// ReviewStepTriage)均传常量 fontName/fontSize，符合此契约。
    private let baseFont: UIFont
    /// 文字颜色（默认 #3D3A38 为冷化前历史值，仅最早两个调用方沿用；不等于当前
    /// WarmTheme.textPrimary）。
    /// 支持动态值：updateUIView 每次对比并同步，调用方可随状态传不同色
    /// （复盘拆分行随勾选态切 textPrimary/textMuted）。
    private let textColor: UIColor
    /// a11y 标识。默认值保持最早调用方(BottomInputPanelView / 既有 UI 测试)零改动。
    private let accessibilityID: String
    /// attach 后是否自动抢焦点。输入面板/编辑 sheet 传 true（打开即打字）；
    /// 详情页标题/备注传 false（打开详情不该弹键盘，用户点哪个框聚焦哪个）。
    private let autoFocusOnAttach: Bool
    /// 是否随内容自适应增高（isScrollEnabled = false，UITextView 由此获得 intrinsic
    /// content size，按文本行数自尺寸）。
    /// - false（默认）：滚动开启、无 intrinsic size，调用方必须用 `.frame(minHeight:)`
    ///   撑高，超高后**框内滚动**——输入面板/编辑 sheet 的「封顶+内部滚动」形态。
    /// - true：滚动关闭、随行数增长，内容永不截断/不出滚动条——详情页标题/备注的
    ///   「全文可见」形态。滚动关闭后 keyboardDismissMode(.interactive) 在框内失效，
    ///   详情页收键盘有自己的通道（点空白 / 页面下滑手势的 keyboard-only 分支）。
    private let autoHeight: Bool

    init(
        text: Binding<String>,
        fontSize: CGFloat = 17,
        accessibilityIdentifier: String = "ManualInputTextView",
        /// Avenir Next 的 PostScript 名。 WarmFont 的 SwiftUI 侧对应：
        /// headline(.semibold) → "AvenirNext-DemiBold"；body(.medium) → "AvenirNext-Medium"（默认）。
        /// 字体缺失时 fallback 为 systemFont(.medium)，仅极端环境下降级，不区分传入字重。
        fontName: String = "AvenirNext-Medium",
        autoFocusOnAttach: Bool = true,
        autoHeight: Bool = false,
        /// 默认 #3D3A38 — 冷化前的历史值，为保持最早调用方(BottomInputPanelView /
        /// UnparsedTranscriptEditSheet)既有视觉零改动而保留；**不等于**当前
        /// WarmTheme.textPrimary 浅色值(#1E2A3A)。新调用方若需跟随设计系统应显式传
        /// `UIColor(WarmTheme.textPrimary)`。UIUserInterfaceStyle 锁 Light，无深色适配问题。
        textColor: UIColor = UIColor(red: 0x3D / 255.0, green: 0x3A / 255.0, blue: 0x38 / 255.0, alpha: 1.0)
    ) {
        self._text = text
        self.baseFont = UIFont(name: fontName, size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .medium)
        self.textColor = textColor
        self.accessibilityID = accessibilityIdentifier
        self.autoFocusOnAttach = autoFocusOnAttach
        self.autoHeight = autoHeight
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
        // autoHeight 决定滚动形态（见 autoHeight 文档）：滚动关闭才有 intrinsic content size，
        // 按行数自尺寸；滚动开启则调用方必须 frame(minHeight:) 撑高、超高框内滚动。
        textView.isScrollEnabled = !autoHeight
        textView.alwaysBounceVertical = false
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .yes
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.text = text
        textView.accessibilityIdentifier = accessibilityID
        // 同步初始 uiText 到 coordinator，避免首次 updateUIView 误判"用户刚改过未同步"。
        context.coordinator.lastKnownUIText = text
        // autoFocus 在 didMoveToWindow 里触发，无需此处主动 becomeFirstResponder
        textView.autoFocusOnAttach = autoFocusOnAttach
        return textView
    }

    /// 尺寸契约(autoHeight 形态):**宽度永远跟随提案,文本在提案宽度内换行**。
    ///
    /// 不实现 sizeThatFits 时,SwiftUI 落到 UITextView 的 intrinsicContentSize ——
    /// isScrollEnabled=false 后它的宽度是「未换行的单行全文宽度」:长文本会把宿主
    /// 容器撑到超屏宽,垂直 ScrollView 将超宽内容水平居中,整页坐标系左移
    /// (详情页实测:44 字标题把内容撑到 980pt,坐标系左移 289pt,safeAreaInset
    /// 里的自绘 header 随之变宽,leading overlay 的 chevron.down 关闭按钮被推出
    /// 屏幕外 —— 「不同 todo 详情页关闭按钮位置漂移」bug 的根因)。
    ///
    /// 仅 autoHeight 形态实现;滚动形态(autoHeight=false)无 intrinsic size、
    /// 由调用方 frame(minHeight:) 撑高,维持默认行为(nil = 用系统默认尺寸)。
    ///
    /// **方法名必须是 sizeThatFits(带 s)** —— SwiftUI 按协议要求分发;
    /// 早前笔误写成 sizeThatFit 不触发编译错误,只是永远不会被调用,修复静默失效。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard autoHeight else { return nil }
        // ideal 查询(width==nil)用已落位的 bounds 兜底;首帧 bounds 也为 0 时
        // 回退 nil 走默认,避免 0 宽度死锁。
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
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
