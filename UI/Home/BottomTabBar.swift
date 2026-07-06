import SwiftUI

/// 底部导航：长条玻璃 capsule 容器 + 中央凸出的麦克风 FAB。
///
/// 设计参考：iOS 26 dock / notch tab bar 风格——
/// - 整体一个长条 capsule 玻璃容器（不再 3 个独立 capsule 融合）
/// - 两侧 tab 仅图标（无文字），左右对称坐在 capsule 内
/// - 中央 FAB 是凸出的圆形玻璃，直径比 capsule 高度大、向上突破容器顶边
///
/// 用户反馈（2026-07-06）：
/// 1. 不要显示汉字，只要图标
/// 2. 底部采用长条形设计
/// 3. 中间的录音按钮要做成一个稍微大一点、凸出来的圆
struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab
    let isFABDisabled: Bool
    let onFABTap: () -> Void

    var body: some View {
        // FAB 凸出量：让 FAB 顶部超出 capsule 顶部 ~1/3，下方坐进 capsule 内。
        // (fab - tabPillHeight) / 2 = (70 - 52) / 2 = 9，再加 4 让上方更凸。
        let fabLift: CGFloat = 13

        ZStack {
            // 长条 capsule 容器：单一玻璃，两端排 tab icon，中间留洞给 FAB
            HStack(spacing: 0) {
                tabIcon(title: String(localized: "tab.today"), icon: "checklist", tab: .today)
                Spacer(minLength: WarmSize.fab + WarmSpacing.lg)
                tabIcon(title: String(localized: "tab.calendar"), icon: "calendar", tab: .calendar)
            }
            .padding(.horizontal, WarmSpacing.sm)
            .frame(height: WarmSize.tabPillHeight)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .center) {
                fabButton
                    .offset(y: -fabLift)
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.bottom, WarmSpacing.xs)
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button(action: onFABTap) {
            Image(systemName: "mic.fill")
                .font(.system(size: 26))
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

    // MARK: - Tab 图标

    @ViewBuilder
    private func tabIcon(title: String, icon: String, tab: BottomTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(WarmAnimation.springFast) { selectedTab = tab }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? WarmTheme.textPrimary : WarmTheme.textMuted)
                .frame(width: WarmSize.touch, height: WarmSize.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 不再给单个 tab 加 .glassEffect——它们坐在长条 capsule 内，
        // 长条 capsule 已经是玻璃。选中态用前景色 + 字重区分。
        .accessibilityIdentifier(tab.accessibilityIdentifier)
        .accessibilityLabel(title)
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
    .background(Color.gray.opacity(0.3))
}
