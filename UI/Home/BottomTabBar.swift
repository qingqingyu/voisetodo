import SwiftUI

/// 底部导航：今日胶囊 / 麦克风 FAB 圆 / 日历胶囊，三件同排、居中悬浮成一个玻璃簇。
/// FAB 点击弹出底部输入面板。
///
/// iOS 26 Liquid Glass 统一：
/// - 三个元素放进**同一个** GlassEffectContainer，用同一 gap 间距一致、玻璃边缘连贯融合。
/// - FAB 只用 `.glassEffect(.regular.tint(.orange).interactive(), in: .circle)`（单层玻璃，
///   不再叠 `.buttonStyle(.glass)`，去掉双层发光边缘），直径 60、内联不浮起、不遮挡列表。
/// - 两侧 tab 恒为玻璃胶囊，选中态用橙色 tint + 前景色区分。
/// - 全程原生 glassEffect，**不使用** ultraThinMaterial / 自定义半透明背景模拟玻璃。
struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab
    let isFABDisabled: Bool
    let onFABTap: () -> Void

    /// 三元素间距 = GlassEffectContainer 融合间距，保持一致。
    private let gap = WarmSpacing.xs

    var body: some View {
        GlassEffectContainer(spacing: gap) {
            HStack(spacing: gap) {
                tabButton(title: String(localized: "tab.today"), icon: "checklist", tab: .today)
                fabButton
                tabButton(title: String(localized: "tab.calendar"), icon: "calendar", tab: .calendar)
            }
        }
        // 内容自然宽度的簇居中悬浮（不再全宽贴边），底部留一点悬浮间隙。
        .frame(maxWidth: .infinity)
        .padding(.bottom, WarmSpacing.xs)
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
        .glassEffect(.regular.tint(.orange).interactive(), in: .circle)
        .disabled(isFABDisabled)
        .opacity(isFABDisabled ? 0.55 : 1)
        .accessibilityIdentifier("RecordFAB")
        .accessibilityLabel(String(localized: "panel.fab.record"))
    }

    // MARK: - Tab 胶囊

    @ViewBuilder
    private func tabButton(title: String, icon: String, tab: BottomTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(WarmAnimation.springFast) { selectedTab = tab }
        } label: {
            VStack(spacing: WarmSpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(isSelected ? WarmTheme.textPrimary : WarmTheme.textMuted)
            .frame(height: WarmSize.tabPillHeight)
            .padding(.horizontal, WarmSpacing.lg)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffectTinted(isSelected: isSelected, tint: WarmTheme.primary.opacity(0.18))
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }
}

/// 两侧胶囊恒为玻璃：选中加橙色 tint，未选中素玻璃。用 ViewBuilder 分支承载
/// glassEffect 的字面量入参（其类型未公开命名，需分支各自写字面量）。
private extension View {
    @ViewBuilder
    func glassEffectTinted(isSelected: Bool, tint: Color) -> some View {
        if isSelected {
            self.glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            self.glassEffect(.regular, in: .capsule)
        }
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
}
