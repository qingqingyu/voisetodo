import SwiftUI

/// 读取当前 window 的底部 safe area inset（home indicator 高度，≈34pt on notched devices）。
/// 用于 `inputPanelOverlay` 在 `.ignoresSafeArea(edges: .bottom)`（等同 .all region）后、
/// 键盘未弹起时给 `BottomInputPanelView` 补一段 padding，避免面板内容侵入 home indicator 区域。
///
/// 实现选择：用 SwiftUI 原生 GeometryReader 而不是直接读 UIApplication.shared.connectedScenes。
/// 原因：GeometryReader 的 safeAreaInsets 是 SwiftUI 依赖图的一等公民，横竖屏切换 / 分屏
/// 改变 bottom safe area 时会自动 invalidate body；直接读 UIWindow.safeAreaInsets 绕过依赖图，
/// 可能停在旧值。GeometryReader 返回 Color.clear 不占布局空间，避免影响外层布局。
struct BottomSafeAreaReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.safeAreaInsets.bottom) }
                .onChange(of: proxy.safeAreaInsets.bottom) { _, newValue in
                    onChange(newValue)
                }
        }
        .frame(width: 0, height: 0)
    }
}

// MARK: - HomeView

