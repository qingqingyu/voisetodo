import SwiftUI

/// 首次使用引导:手指下拉动画,提示可下拉展开整月。
///
/// 纯视觉引导组件,不管理触发条件或持久化——由调用方(`HomeView`)决定何时显示,
/// 并负责把"已展示过"标记写入 `@AppStorage("hasShownExpandMonthHint")`。
///
/// 本视图只负责:
/// 1. 渲染手指 + chevron 图标,做无缝循环下拉动画
/// 2. 提供两条消失路径:用户点击 / 自动超时(4.5s 约 3 轮)
///
/// **a11y**: 纯视觉,VoiceOver 通过 `WeekStripCard.accessibilityAction(named: "a11y.action.expand_month")`
/// 触发展开。本视图 `accessibilityHidden(true)`,避免 VoiceOver 用户读到无意义的图标描述。
struct ExpandMonthHintView: View {
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.animation) { timeline in
            // phase ∈ [0, 1):truncatingRemainder 让循环无缝衔接,无可见跳变。
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: ExpandHintMetrics.loopDuration) / ExpandHintMetrics.loopDuration
            // smoothstep: ease-in-out 曲线,比线性更自然——开始慢、中间快、结束慢。
            let eased = phase * phase * (3 - 2 * phase)
            let offset = ExpandHintMetrics.dragStartOffset + CGFloat(eased) * ExpandHintMetrics.dragDistance
            // 早进晚出:前 85% 时间满显,后 15% 淡出——形成"动画结束"暗示,衔接下一轮淡入。
            let opacity = phase < ExpandHintMetrics.fadeOutStartPhase
                ? 1.0
                : 1.0 - (phase - ExpandHintMetrics.fadeOutStartPhase) / (1 - ExpandHintMetrics.fadeOutStartPhase)

            VStack(spacing: ExpandHintMetrics.iconStackSpacing) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: ExpandHintMetrics.handIconSize, weight: .semibold))
                    .foregroundColor(WarmTheme.primary)
                    .offset(y: offset)
                Image(systemName: "chevron.down")
                    .font(.system(size: ExpandHintMetrics.chevronIconSize, weight: .bold))
                    .foregroundColor(WarmTheme.primary.opacity(0.6))
            }
            .opacity(opacity)
        }
        .padding(ExpandHintMetrics.capsulePadding)
        .background(Capsule().fill(WarmTheme.cardBackground.opacity(ExpandHintMetrics.capsuleBgOpacity)))
        .overlay(Capsule().stroke(WarmTheme.primary.opacity(ExpandHintMetrics.capsuleStrokeOpacity), lineWidth: 1))
        .shadow(color: WarmTheme.primary.opacity(ExpandHintMetrics.shadowOpacity), radius: 4, y: 2)
        .onTapGesture { onDismiss() }
        .accessibilityHidden(true)
        // 自动超时:进入即计时,maxDisplayDuration 后强制 dismiss。
        // .task 在视图 disappear 时自动取消 Task——避免退后台/切 tab 后还在等 sleep。
        .task {
            try? await Task.sleep(nanoseconds: ExpandHintMetrics.autoDismissDelayNano)
            onDismiss()
        }
    }
}

/// 下拉引导动画相关常量。
///
/// 集中管理避免散落硬编码;`HomeView`(触发延迟 + ZStack overlay offset)与本视图(动画曲线)
/// 共享同一组配置,便于统一调参。
enum ExpandHintMetrics {
    // MARK: 触发(HomeView 用)
    /// 触发延迟(秒):进入折叠态后等 0.5s 再显示,让用户先感知"我在折叠态"。
    static let triggerDelaySeconds: Double = 0.5
    /// 触发延迟(nanoseconds 形式,供 `Task.sleep`)。
    static var triggerDelayNano: UInt64 { UInt64(triggerDelaySeconds * 1_000_000_000) }

    // MARK: Hint 视觉定位(HomeView 用)
    /// ZStack 内 hint 的 Y 偏移:让胶囊底边贴 WeekStripCard 顶边,手指指向卡片"按下"。
    /// = -(胶囊高度):图标 32 + chevron 10 + 上下 padding 8×2 = 58;按视觉微调为 -52。
    static let overlayOffsetY: CGFloat = -52

    // MARK: 动画曲线(ExpandMonthHintView 用)
    /// 单轮动画时长(秒)。1.4s 兼顾"看清手势方向"和"不磨叽"。
    static let loopDuration: Double = 1.4
    /// 自动超时(秒)。约 3 轮动画后用户若没反应就不再打扰。
    static let maxDisplayDuration: Double = 4.5
    /// 自动超时(nanoseconds 形式,供 `Task.sleep`)。
    static var autoDismissDelayNano: UInt64 { UInt64(maxDisplayDuration * 1_000_000_000) }
    /// 手指动画起点偏移(pt)。负值上抬,形成"先弹起"暗示。
    static let dragStartOffset: CGFloat = -8
    /// 手指动画行程(pt)。起点 -8 → 终点 18,形成"按下又弹起"的视觉。
    static let dragDistance: CGFloat = 26
    /// 单轮内淡出起始 phase(0~1)。前 85% 满显,后 15% 淡出。
    static let fadeOutStartPhase: Double = 0.85

    // MARK: Hint 内部布局(ExpandMonthHintView 用)
    /// 手指图标 + chevron 的垂直 spacing。
    static let iconStackSpacing: CGFloat = 4
    /// 手指图标字号。
    static let handIconSize: CGFloat = 32
    /// chevron 图标字号。
    static let chevronIconSize: CGFloat = 10
    /// 胶囊内 padding。
    static let capsulePadding: CGFloat = 8
    /// 胶囊背景透明度。
    static let capsuleBgOpacity: Double = 0.92
    /// 胶囊描边透明度。
    static let capsuleStrokeOpacity: Double = 0.3
    /// 阴影透明度。
    static let shadowOpacity: Double = 0.15
}
