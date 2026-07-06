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
        ZStack {
            // 长条 capsule 容器 + 凸出 FAB：模仿 iOS 26 dock notch 风格。
            // 有意不用 GlassEffectContainer——capsule 与 FAB 的玻璃边缘独立渲染，
            // FAB 跨越 capsule 顶边形成"凸出"视觉，而非多元素融合。
            HStack(spacing: 0) {
                tabIcon(label: String(localized: "tab.today"), icon: "checklist", tab: .today)
                // 为 FAB 留洞：直径 fab + 两侧 lg 余量，避免 FAB 与 tab icon 撞车
                Spacer(minLength: WarmSize.fab + WarmSpacing.lg)
                tabIcon(label: String(localized: "tab.calendar"), icon: "calendar", tab: .calendar)
            }
            .padding(.horizontal, WarmSpacing.sm)
            .frame(height: WarmSize.tabPillHeight)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .center) {
                fabButton
                    .offset(y: -WarmSize.fabLift)
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
    private func tabIcon(label: String, icon: String, tab: BottomTab) -> some View {
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
        .accessibilityLabel(label)
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
