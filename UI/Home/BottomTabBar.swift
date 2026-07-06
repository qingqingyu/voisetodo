import SwiftUI

/// 底部 Tab Bar：左侧"今日"、右侧"日历"、中间留洞给悬浮 FAB。
/// FAB 是橙色麦克风录音钮，点击弹出底部输入面板。
///
/// iOS 26 改造（Liquid Glass）：
/// - 整个 BottomTabBar 包在 GlassEffectContainer 里，让 FAB + tab 按钮共享折射上下文
/// - FAB 用 .buttonStyle(.glass) + .glassEffect(.regular.tint(primary).interactive())
/// - tab 按钮选中态用 .glassEffect(.regular)（不选中不加，避免视觉噪点）
/// - 底部背景从 .regularMaterial 改 .ultraThinMaterial，让 FAB 折射感更强
///
/// 布局参考 HTML 规格 voicetodo-input-panel.html：
/// tab bar 高度 72pt，中间 spacer 给 FAB 留空间（FAB 悬浮在上方）。
struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab
    let isFABDisabled: Bool
    let onFABTap: () -> Void

    var body: some View {
        // GlassEffectContainer：iOS 26 推荐做法，让多个 glass 元素共享折射上下文，
        // FAB 滚到 tab 按钮上方时玻璃边缘会连贯（不会出现两个独立玻璃拼出的接缝）。
        GlassEffectContainer {
            HStack(spacing: 0) {
                // 左：今日
                tabButton(
                    title: String(localized: "tab.today"),
                    icon: "checklist",
                    tab: .today
                )

                // 中：留洞给 FAB（直径 64 + 折射余量）
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
                Color.clear
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .bottom)
            )
            .overlay(alignment: .center) {
                // FAB：悬浮在 tab bar 中央上方。
                // contentShape 限定命中区域为圆形，防止阴影扩展到两侧 tab 按钮的 frame 后产生命中歧义。
                // iOS 26：.buttonStyle(.glass) 提供玻璃容器，.glassEffect 加 tint 和 interactive 提供橙色染色 + 悬停反馈。
                Button(action: onFABTap) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: WarmSize.fab, height: WarmSize.fab)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .glassEffect(.regular.tint(WarmTheme.primary).interactive())
                .disabled(isFABDisabled)
                .opacity(isFABDisabled ? 0.55 : 1)
                .offset(y: -16)
                .accessibilityIdentifier("RecordFAB")
                .accessibilityLabel(String(localized: "panel.fab.record"))
            }
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
            .foregroundStyle(selectedTab == tab ? WarmTheme.textPrimary : WarmTheme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: WarmSize.touch)
            .padding(.bottom, WarmSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        // 选中态加 glass 染色（淡橙 tint 提示当前 tab）；未选中保持透明让背景穿透。
        .glassEffect(selectedTab == tab ? .regular.tint(WarmTheme.primary.opacity(0.2)) : .clear)
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
