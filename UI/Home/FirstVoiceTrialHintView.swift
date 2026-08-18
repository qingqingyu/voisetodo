import SwiftUI

/// 首次语音试用引导:悬浮在 FAB 上方的教练提示,引导用户点麦克风录第一句。
///
/// 纯视觉组件,不管理触发条件或持久化——由调用方(`HomeView`)决定何时显示,
/// 状态机(`FirstVoiceTrial`)的推进与落盘也全在调用方。
///
/// 本视图只负责:
/// 1. 渲染引导语 + 示例台词 + 「知道了」按钮,麦克风图标做朝下指向 FAB 的循环动画
/// 2. 提供唯一消失路径:用户点「知道了」(**没有自动超时**——与 ExpandMonthHintView
///    的 4.5s 落盘不同,本 hint 的生命周期完全由 eligible 条件控制,见方案 §3.3 差异 1)
///
/// **a11y**: 与 ExpandMonthHintView 的 `accessibilityHidden(true)` 不同——本 hint
/// 承载真实信息且没有替代路径,必须可达:容器 `children: .contain` + label,
/// 「知道了」按钮独立可点(方案 §3.3 差异 2)。
struct FirstVoiceTrialHintView: View {
    /// 「知道了」:写 `.dismissed` 终态并收起 hint。
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.animation) { timeline in
            // phase ∈ [0, 1):truncatingRemainder 让循环无缝衔接(同 ExpandMonthHintView)。
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: FirstVoiceTrialHintMetrics.loopDuration) / FirstVoiceTrialHintMetrics.loopDuration
            // smoothstep: ease-in-out,开始慢、中间快、结束慢。
            let eased = phase * phase * (3 - 2 * phase)
            // 朝下指向:麦克风从上往下压向 chevron,示意「按下面这个按钮」。
            let offset = FirstVoiceTrialHintMetrics.bounceStartOffset + CGFloat(eased) * FirstVoiceTrialHintMetrics.bounceDistance
            // 早进晚出:前 85% 满显,后 15% 淡出,衔接下一轮。
            let opacity = phase < FirstVoiceTrialHintMetrics.fadeOutStartPhase
                ? 1.0
                : 1.0 - (phase - FirstVoiceTrialHintMetrics.fadeOutStartPhase) / (1 - FirstVoiceTrialHintMetrics.fadeOutStartPhase)

            VStack(spacing: FirstVoiceTrialHintMetrics.sectionSpacing) {
                // 指向动画(纯装饰,VoiceOver 跳过)
                VStack(spacing: FirstVoiceTrialHintMetrics.iconStackSpacing) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: FirstVoiceTrialHintMetrics.micIconSize, weight: .semibold))
                        .foregroundColor(WarmTheme.primary)
                        .offset(y: offset)
                    Image(systemName: "chevron.down")
                        .font(.system(size: FirstVoiceTrialHintMetrics.chevronIconSize, weight: .bold))
                        .foregroundColor(WarmTheme.primary.opacity(0.6))
                }
                .opacity(opacity)
                .accessibilityHidden(true)

                VStack(spacing: FirstVoiceTrialHintMetrics.textSpacing) {
                    Text(String(localized: "home.first_trial.hint"))
                        .font(WarmFont.body(FirstVoiceTrialHintMetrics.hintFontSize))
                        .foregroundColor(WarmTheme.sketch)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text("「\(String(localized: "home.first_trial.example"))」")
                        .font(WarmFont.body(FirstVoiceTrialHintMetrics.exampleFontSize).weight(.medium))
                        .foregroundColor(WarmTheme.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }

                Button {
                    onDismiss()
                } label: {
                    Text(String(localized: "home.first_trial.got_it"))
                        .font(WarmFont.body(FirstVoiceTrialHintMetrics.gotItFontSize))
                        .foregroundColor(WarmTheme.sketch)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, FirstVoiceTrialHintMetrics.gotItHorizontalPadding)
                        .padding(.vertical, FirstVoiceTrialHintMetrics.gotItVerticalPadding)
                        .background(
                            Capsule()
                                .fill(WarmTheme.sketch.opacity(FirstVoiceTrialHintMetrics.gotItBgOpacity))
                        )
                }
                .accessibilityIdentifier("FirstVoiceTrialGotItButton")
            }
            .padding(FirstVoiceTrialHintMetrics.cardPadding)
            .frame(maxWidth: FirstVoiceTrialHintMetrics.cardMaxWidth)
            .background(
                RoundedRectangle(cornerRadius: FirstVoiceTrialHintMetrics.cardCornerRadius)
                    .fill(WarmTheme.cardBackground.opacity(FirstVoiceTrialHintMetrics.cardBgOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FirstVoiceTrialHintMetrics.cardCornerRadius)
                    .stroke(WarmTheme.primary.opacity(FirstVoiceTrialHintMetrics.cardStrokeOpacity), lineWidth: 1)
            )
            .shadow(color: WarmTheme.primary.opacity(FirstVoiceTrialHintMetrics.shadowOpacity), radius: 4, y: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "a11y.first_trial.hint"))
        .accessibilityIdentifier("FirstVoiceTrialHint")
    }
}

/// 首次语音试用引导常量(触发延迟 + 动画曲线 + 布局),集中管理避免散落硬编码。
/// `HomeView`(触发调度 + overlay offset)与本视图(动画曲线)共享同一组配置。
enum FirstVoiceTrialHintMetrics {
    // MARK: 触发(HomeView 用)
    /// 触发延迟(秒):HomeView 挂载后等 0.4s 再显示,让主页先完成首帧渲染。
    static let triggerDelaySeconds: Double = 0.4
    /// 触发延迟(nanoseconds 形式,供 `Task.sleep`)。
    static var triggerDelayNano: UInt64 { UInt64(triggerDelaySeconds * 1_000_000_000) }

    // MARK: 视觉定位(HomeView 用)
    /// bottom overlay 内的 Y 偏移:hint 底边抬到 FAB 顶上方留一条呼吸缝。
    /// FAB 上沿 = WarmSpacing.md(16) + WarmSize.fab(72) = 88;再留 WarmSpacing.sm(12) 的缝。
    static let overlayOffsetY: CGFloat = -(WarmSpacing.md + WarmSize.fab + WarmSpacing.sm)

    // MARK: 动画曲线(FirstVoiceTrialHintView 用)
    /// 单轮动画时长(秒)。麦克风下压一圈 1.6s。
    static let loopDuration: Double = 1.6
    /// 麦克风起点偏移(pt)。负值上抬,形成"先弹起"暗示。
    static let bounceStartOffset: CGFloat = -8
    /// 麦克风行程(pt)。起点 -8 → 终点 10,朝下压向 chevron(指向 FAB)。
    static let bounceDistance: CGFloat = 18
    /// 单轮内淡出起始 phase(0~1)。前 85% 满显,后 15% 淡出。
    static let fadeOutStartPhase: Double = 0.85

    // MARK: 布局(FirstVoiceTrialHintView 用)
    /// 动画区 / 文本区 / 按钮三段的垂直 spacing。
    static let sectionSpacing: CGFloat = 10
    /// 麦克风 + chevron 的垂直 spacing。
    static let iconStackSpacing: CGFloat = 4
    /// 引导语与示例台词的垂直 spacing。
    static let textSpacing: CGFloat = 6
    /// 麦克风图标字号。
    static let micIconSize: CGFloat = 28
    /// chevron 字号。
    static let chevronIconSize: CGFloat = 10
    /// 引导语字号。
    static let hintFontSize: CGFloat = 14
    /// 示例台词字号。
    static let exampleFontSize: CGFloat = 17
    /// 「知道了」字号。
    static let gotItFontSize: CGFloat = 13
    /// 「知道了」胶囊 padding。
    static let gotItHorizontalPadding: CGFloat = 14
    static let gotItVerticalPadding: CGFloat = 6
    static let gotItBgOpacity: Double = 0.1
    /// 卡片 padding / 圆角 / 最大宽度(窄屏不至于横贯全屏,宽屏不至于飘忽)。
    static let cardPadding: CGFloat = 14
    static let cardCornerRadius: CGFloat = 16
    static let cardMaxWidth: CGFloat = 300
    static let cardBgOpacity: Double = 0.96
    static let cardStrokeOpacity: Double = 0.3
    static let shadowOpacity: Double = 0.15
}
