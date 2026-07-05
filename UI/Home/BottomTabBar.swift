import SwiftUI

/// 底部 Tab Bar：左侧"今日"、右侧"日历"、中间留洞给悬浮 FAB。
/// FAB 是红色圆形录音钮，点击弹出底部输入面板。
///
/// 布局参考 HTML 规格 voicetodo-input-panel.html：
/// tab bar 高度 72pt，中间 spacer 给 FAB 留空间（FAB 悬浮在上方）。
struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab
    let isFABDisabled: Bool
    let onFABTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 左：今日
            tabButton(
                title: String(localized: "tab.today"),
                icon: "checklist",
                tab: .today
            )

            // 中：留洞给 FAB（直径 64 + 阴影/描边余量）
            Spacer()
                .frame(width: 96)

            // 右：日历
            tabButton(
                title: String(localized: "tab.calendar"),
                icon: "calendar",
                tab: .calendar
            )
        }
        .frame(height: 72)
        .background(
            WarmTheme.background.opacity(0.94)
                .background(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .center) {
            // FAB：悬浮在 tab bar 中央上方。contentShape 限定命中区域为圆形，
            // 防止阴影扩展到两侧 tab 按钮的 frame 后产生命中歧义。
            Button(action: onFABTap) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: WarmSize.fab, height: WarmSize.fab)
                    .background(
                        Circle()
                            .fill(WarmTheme.primary)
                            .overlay(
                                Circle()
                                    .stroke(WarmTheme.background, lineWidth: WarmSpacing.xxs)
                            )
                            .shadow(color: WarmTheme.primary.opacity(0.42), radius: 22, x: 0, y: WarmSpacing.xs)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isFABDisabled)
            .opacity(isFABDisabled ? 0.55 : 1)
            .offset(y: -16)
            .accessibilityIdentifier("RecordFAB")
            .accessibilityLabel(String(localized: "panel.fab.record"))
        }
    }

    private func tabButton(title: String, icon: String, tab: BottomTab) -> some View {
        Button {
            withAnimation(WarmAnimation.springFast) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: WarmSpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 23))
                Text(title)
                    .font(.system(size: 10.5))
            }
            .foregroundColor(selectedTab == tab ? WarmTheme.textPrimary : WarmTheme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: WarmSize.touch)
            .padding(.bottom, WarmSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tab.accessibilityIdentifier)
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
