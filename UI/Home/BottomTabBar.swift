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

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            tabPill(label: String(localized: "tab.today"), icon: "checklist", tab: .today)
            fabButton
            tabPill(label: String(localized: "tab.calendar"), icon: "calendar", tab: .calendar)
        }
        // 整簇离底抬高：从 xs（8pt）改为 md（16pt），避免紧贴屏幕底。
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.bottom, WarmSpacing.md)
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
