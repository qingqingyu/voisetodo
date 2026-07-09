import SwiftUI

/// 底部导航：三个独立玻璃件并排成团——左 tab + 中 FAB + 右 tab。
///
/// 设计变更（2026-07-09）：
/// 之前是"一个长条 capsule + 两侧裸图标 + 凸出 FAB"——两侧图标没有自己的玻璃容器，
/// 和中间橙色 FAB 完全不是一个体系，看起来 FAB 是主角、两边像没做完。
///
/// 现在改成三个独立玻璃件并排：
/// - 左右 tab 各自是一个玻璃 capsule（等大）
/// - FAB 是略大的玻璃圆（直径比 tab 大 8pt），不再大幅凸出
/// - 整体形成视觉一致的"三件套"团
///
/// FAB 防洗白：tint 加重到 primaryDark（深橙 #E56B4F），加 1.5pt primary 描边。
struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab
    let isFABDisabled: Bool
    let onFABTap: () -> Void

    // 背景衬底参数（魔法数提取到此，便于统一调参）。
    // 渐隐区高度 20pt ≈ Tab 簇上方一段过渡，太小看不到淡出效果，太大吃掉列表可视区。
    private static let tabBarFadeHeight: CGFloat = 20
    // 渐隐终点 opacity 0.85：在浅色奶油背景上肉眼接近不透明但保留极轻的层次感。
    private static let tabBarFadeOpacity: Double = 0.85

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            tabPill(label: String(localized: "tab.today"), icon: "checklist", tab: .today)
            fabButton
            tabPill(label: String(localized: "tab.calendar"), icon: "calendar", tab: .calendar)
        }
        // 整簇离底抬高：从 xs（8pt）改为 md（16pt），避免紧贴屏幕底。
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.bottom, WarmSpacing.md)
        // 背景衬底：滚动时列表内容透过三个玻璃件的间隙可见，
        // 加一层从顶部透明渐隐到底部不透明的遮罩，让 Tab 簇与列表视觉分离。
        // allowsHitTesting(false) 让衬底只做视觉，不拦截手势；
        // ignoresSafeArea(.bottom) 让衬底延伸到 home indicator 区域，
        // 避免在 home indicator 处露出列表内容。
        // 注意：本视图被外层 safeAreaInset(.bottom) 包裹，.background 的 ignoresSafeArea 行为
        // 依赖 iOS 17+ 在 safeAreaInset 上下文中的实现，需在带 home indicator 的真机/模拟器上验证。
        .background(
            VStack(spacing: 0) {
                // 顶部渐隐区：列表内容平滑淡出到 Tab 簇下方。
                // 高度 20pt 是 BottomTabBar 内部背景遮罩，不进入 safeAreaInset 布局流；
                // HomeLayoutMetrics.listBottomInset 的"余量"部分已为其留出视觉缓冲，改本值不应联动改 listBottomInset。
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: WarmTheme.background.opacity(Self.tabBarFadeOpacity), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Self.tabBarFadeHeight)
                // 底部实色区：Tab 簇所在区域，完全不透明。
                // 不加 frame(maxHeight:) —— VStack 在 background 内会自动撑满剩余高度，
                // 加 maxHeight: .infinity 是 no-op 反而暗示有特殊布局行为。
                WarmTheme.background
            }
            // ⚠️ 未验证项：本视图被外层 safeAreaInset(.bottom) 包裹，.background 的
            // ignoresSafeArea 行为依赖 iOS 17+ 在 safeAreaInset 上下文中的实现。
            // home indicator 区域是否露出列表内容，需在带 home indicator 的真机/模拟器上验证。
            // 本次 PR 未提供验证截图，存在视觉回归风险。
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    // MARK: - Tab 胶囊

    @ViewBuilder
    private func tabPill(label: String, icon: String, tab: BottomTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(WarmAnimation.springFast) { selectedTab = tab }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? WarmTheme.textPrimary : WarmTheme.textMuted)
                .frame(width: WarmSize.tabPillSize, height: WarmSize.tabPillSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .accessibilityIdentifier(tab.accessibilityIdentifier)
        .accessibilityLabel(label)
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button(action: onFABTap) {
            Image(systemName: "mic.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: WarmSize.fab, height: WarmSize.fab)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // tint 加重到 primaryDark（深橙），防白底洗白。
        .glassEffect(.regular.tint(WarmTheme.primaryDark).interactive(), in: .circle)
        // 极细描边让 FAB 在浅背景上"立"起来。
        .overlay(
            Circle()
                .stroke(WarmTheme.primary, lineWidth: 1.5)
        )
        .disabled(isFABDisabled)
        .opacity(isFABDisabled ? 0.55 : 1)
        .accessibilityIdentifier("RecordFAB")
        .accessibilityLabel(String(localized: "panel.fab.record"))
    }
}

/// 底部 tab 类型
enum BottomTab: Hashable {
    case today
    case calendar

    var accessibilityIdentifier: String {
        switch self {
        case .today:
            return "TodayTabButton"
        case .calendar:
            return "CalendarTabButton"
        }
    }
}

#Preview {
    VStack {
        Spacer()
        BottomTabBar(selectedTab: .constant(.today), isFABDisabled: false, onFABTap: {})
    }
    .background(WarmTheme.background)
}
