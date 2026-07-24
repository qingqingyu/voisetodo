import SwiftUI

/// 底部语音 FAB——app 的签名按钮，独占底部中央。
///
/// 设计变更（2026-07-12）：
/// 之前是"三个玻璃件并排（Today tab + FAB + Calendar tab）"——导航和动作平级排放，
/// 心智上别扭（列表/日历是"导航"，麦克风是"动作"，不该并列）。
///
/// 现在导航移到头部（下划线切换器），底部只留一个大麦克风：
/// - 72pt 直径（2026-07 从 68 调到 72，配合外发光圈提升显眼度），是画面的焦点
/// - 轻微呼吸动画（scale 0.97↔1.03，3s 周期）让按钮"活着"
/// - tint 加重到 primaryDark + primary 描边，防浅背景洗白
/// - 柔和外发光圈（比按钮大 28pt 的模糊 primary 圆），营造「主操作锚点」感
///
/// "动作只有一个，就让它孤独而显眼。"——方案一的核心原则。
struct VoiceFAB: View {
    let isDisabled: Bool
    let onTap: () -> Void

    @State private var breathing = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "mic.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: WarmSize.fab, height: WarmSize.fab)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(WarmTheme.primaryDark).interactive(), in: .circle)
        .overlay(
            Circle()
                .stroke(WarmTheme.primary, lineWidth: 1.5)
        )
        .opacity(isDisabled ? 0.55 : 1)
        .scaleEffect(breathing ? 1.03 : 0.97)
        .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .disabled(isDisabled)
        // 柔和外发光圈:比按钮大 28pt 的模糊 primary 圆,营造「主操作锚点」感。
        // 挂在 scaleEffect 之外 → 呼吸动画时光晕稳定不跟着缩放(避免忽大忽小分散注意力)。
        // allowsHitTesting(false) 防止发光圈拦截按钮外的 tap。
        // disabled 时光晕 opacity 从 0.22 → 0.1,与按钮本体的 0.55 opacity 协调(明显变暗但不消失)。
        .background {
            Circle()
                .fill(WarmTheme.primary.opacity(isDisabled ? 0.1 : 0.22))
                .frame(width: WarmSize.fab + 28, height: WarmSize.fab + 28)
                .blur(radius: 16)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("RecordFAB")
        .accessibilityLabel(String(localized: "panel.fab.record"))
        .frame(maxWidth: .infinity)
        .padding(.bottom, WarmSpacing.md)
    }
}

/// 视图切换类型（保留枚举——selectedBottomTab 仍用它控制头部 + 内容区）
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
        VoiceFAB(isDisabled: false, onTap: {})
    }
    .background(WarmTheme.background)
}
