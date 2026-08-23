import SwiftUI

// MARK: - 手绘风格 Onboarding
// 设计理念：温暖手写笔记本风格，仿佛翻开一本精心制作的手账

/// Onboarding 步骤。`visibleSteps` 会根据设备能力(Action Button)动态过滤,
/// 旧机型会跳过对应步骤。Pro 付费墙已移出 onboarding——改为首次 wow 之后弹
/// app 级 sheet(docs/onboarding-first-voice-trial.md §3.5)。
/// 日历同步页已删(2026-08-23):改为首次确认带日期待办后由主页弹一次性询问
/// (CalendarSyncAskSheet)——在用户刚看到日期被识别出来的那一刻请求价值。
private enum OnboardingStep: CaseIterable {
    case welcome
    case demo
    case voicePermissions
    case speechLanguage
    case actionButton
    case completion
}

/// 标记当前正在请求哪一类权限,只让对应卡片的按钮显示 spinner。
private enum PermissionRequestType {
    case mic
    case speech
}

/// Onboarding 小屏适配常量(项目约定:常量用 enum namespace 收敛)。
private enum OnboardingLayout {
    /// 视口高度低于此值启用紧凑规格:所有 iPhone 视口都 < 800,
    /// iPad(≥ 1000)保留宽松排版。
    static let compactViewportThreshold: CGFloat = 800
}

/// 首次启动引导视图 - 温暖手写风格
/// 分步引导用户完成权限配置(可选 Action Button 设置)
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    @Binding var hasCompletedOnboarding: Bool
    /// 首次语音试用引导状态:completion 页按钮点下时 arm(权限齐 → pending)。
    /// 台词/时机见 docs/onboarding-first-voice-trial.md §3.2c。
    @AppStorage(FirstVoiceTrial.storageKey)
    private var firstVoiceTrialRaw = FirstVoiceTrial.notArmed.rawValue

    // 无障碍：尊重「减弱动态效果」设置
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 从系统设置切回 App 时刷新权限态(mic/speech/calendar 共用)。
    // .onAppear 管 sheet 首次出现,.onChange(of: scenePhase) 管后续回前台。
    @Environment(\.scenePhase) private var scenePhase

    // 语音识别语言:与 HomeSettingsSheet 共享同一个 UserDefaults key,设置页无需改动。
    @AppStorage(SpeechRecognitionLanguage.storageKey)
    private var speechLanguageRaw = SpeechRecognitionLanguage.auto.rawValue

    // (日历写入模式已不在 onboarding 配置——日历页删除后,一次性询问
    // 由主页 CalendarSyncAskSheet 负责,读写都走 HomeView 的共享 key。)

    /// EntitlementManager 通过 environmentObject 注入(VoiceTodoApp 的 sheet 显式传入)。
    /// completion 页用 isPro 显示已订阅用户的感谢文案(实时读,非快照)。
    @EnvironmentObject private var entitlement: EntitlementManager

    @State private var currentStepIndex = 0
    // 用 Set 而非单个值:两张权限卡可独立授权,各自 spinner 互不覆盖。
    @State private var requestingPermissionTypes: Set<PermissionRequestType> = []

    // 小屏适配:ScrollView 视口高度。初值 .infinity 表示「尚未测得」——
    // 拿到真值前不施加 minHeight(否则首帧 frame(minHeight: .infinity) 会把
    // ScrollView 内容撑成无限高),也不参与 isCompact / contentFits 判定。
    @State private var viewportHeight: CGFloat = .infinity
    // 当前步骤内容的自然高度(在 frame(minHeight:) 撑开之前测量),
    // 与视口比较即得「内容是否一屏装下」。
    @State private var contentHeight: CGFloat = 0

    /// 紧凑布局判定:视口 < 800pt 启用。原「宽松」规格(欢迎页自然高 ~880pt)在
    /// 任何 iPhone 上都装不下 —— SE 视口 ~521,iPhone 17 Pro Max 也只有 ~780,
    /// 全部需要滚动(正是本次要修的问题)。因此所有手机走紧凑规格,iPad
    /// (视口 ≥ 1000)保留宽松排版。测得真值前视为非紧凑。
    private var isCompact: Bool {
        viewportHeight.isFinite && viewportHeight < OnboardingLayout.compactViewportThreshold
    }

    /// 内容区 minHeight:每一步都撑到视口高度,内容装得下时垂直居中;
    /// 视口未测得时返回 nil(首帧不干预布局)。
    private var minContentHeight: CGFloat? {
        guard viewportHeight.isFinite else { return nil }
        return viewportHeight
    }

    /// 当前步骤内容是否一屏装下(不滚动)。DEBUG 下经隐藏元素暴露给 UI 测试断言,
    /// 视口未测得时报告 "pending",测试等待其收敛到 "0"/"1"。
    /// DEBUG 构建 +1:流内 a11y 钩子占 1pt,也算滚动内容,不计入会出现
    /// 「fits 报 1 但实际多 1pt 可滚」的假阳性。
    private var contentFits: Bool {
        guard viewportHeight.isFinite else { return false }
        #if DEBUG
        return contentHeight + 1 <= viewportHeight + 0.5
        #else
        return contentHeight <= viewportHeight + 0.5
        #endif
    }
    private var contentFitsRawValue: String {
        guard viewportHeight.isFinite else { return "pending" }
        let prefix = contentFits ? "1" : "0"
        // 附上实测数值,溢出时 UI 测试失败信息直接显示差多少,免得反复加日志排查
        return "\(prefix)|content=\(Int(contentHeight))|viewport=\(Int(viewportHeight))|compact=\(isCompact ? 1 : 0)"
    }

    // 动画状态
    @State private var contentOffset: CGFloat = 30
    @State private var contentOpacity: Double = 0
    @State private var illustrationScale: CGFloat = 0.8
    @State private var illustrationRotation: Double = -5

    init(
        permissionManager: PermissionManager,
        hasCompletedOnboarding: Binding<Bool>
    ) {
        self.permissionManager = permissionManager
        self._hasCompletedOnboarding = hasCompletedOnboarding
    }

    // 使用 WarmTheme 统一配色
    private var inkColor: Color { WarmTheme.ink }
    private var paperColor: Color { WarmTheme.paperBackground }
    private var highlightColor: Color { WarmTheme.primary }
    private var sketchColor: Color { WarmTheme.sketch }

    /// 当前设备实际要走的步骤序列。Action Button 步骤只在支持的机型上出现。
    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .actionButton:
                return ActionButtonCapability.isSupported
            default:
                return true
            }
        }
    }

    private var totalSteps: Int { visibleSteps.count }

    private var currentStep: OnboardingStep {
        guard visibleSteps.indices.contains(currentStepIndex) else {
            return .welcome
        }
        return visibleSteps[currentStepIndex]
    }

    /// 「减弱动态效果」开启时返回 nil，从而禁用对应动画。
    private func motionAnim(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    var body: some View {
        ZStack {
            // 纸张纹理背景
            paperBackground

            VStack(spacing: 0) {
                // 顶部装饰
                topDecoration

                // 页面指示器 - 手绘圆点风格
                handDrawnPageIndicator
                    .padding(.top, isCompact ? 8 : 20)

                // 内容区。保留 ScrollView:内容一屏装下时 frame(minHeight:) 让它垂直居中;
                // 内容超高(AX 大字号)时正常从顶部滚动 —— ScrollView 是无障碍回退,不删。
                ScrollView {
                    VStack(spacing: 0) {
                        Group {
                            switch currentStep {
                            case .welcome:
                                welcomeStep
                            case .demo:
                                demoStep
                            case .voicePermissions:
                                voicePermissionsStep
                            case .speechLanguage:
                                speechLanguageStep
                            case .actionButton:
                                actionButtonGuideStep
                            case .completion:
                                completionStep
                            }
                        }
                        .padding(.horizontal, 28)
                        // 测量自然内容高:必须挂在 frame(minHeight:) 之前,否则量到的是
                        // 撑开后的高度(恒等于视口,断言失效)。
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { _, newHeight in
                            contentHeight = newHeight
                        }
                        // 每步内容撑到视口高度,装得下时垂直居中
                        // (比顶对齐更稳,避免底部大片空白);超高(AX 大字号)时正常滚动。
                        .frame(minHeight: minContentHeight)

                        #if DEBUG
                        // UI 测试钩子:暴露「当前步骤内容是否一屏装下」,截图只能人看,
                        // 这个值让 test_S17 能做确定性断言。试过挂 overlay 零占位,
                        // 但 overlay 里的元素进不了 XCUI 可见的 a11y 树,只能放回流内;
                        // 它的 1pt 已计入 contentFits 判定(见上方属性区的 DEBUG +1)。
                        // (0×0 元素会被 SwiftUI 从 a11y 树剪掉,必须给一点尺寸。)
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("OnboardingContentFits")
                            .accessibilityValue(contentFitsRawValue)
                        #endif
                    }
                }
                .frame(maxHeight: .infinity)
                // 挂在 ScrollView 自身测视口:高度由外层 maxHeight 决定,与内容无关,
                // 不会与内容侧的 frame(minHeight:) 形成布局反馈环。
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, newHeight in
                    viewportHeight = newHeight
                }

                // 底部按钮:所有步骤统一「下一步」,始终可用
                // (权限被拒不卡流程,设置页可随时补授权)
                bottomButtons
            }
        }
        .onAppear {
            // sheet 首次出现时检查权限状态(整个 onboarding 期间 sheet 只 appear 一次)。
            permissionManager.checkCurrentStatus()
            animateContentIn()
        }
        .onChange(of: scenePhase) { _, phase in
            // 后续回前台:用户跳到系统设置授权日历/麦克风后切回 App,sheet 不会重新 appear,
            // 必须靠 scenePhase 刷新。与 .onAppear 互补,不重复(appear 只触发一次)。
            guard phase == .active else { return }
            permissionManager.checkCurrentStatus()
        }
        .onChange(of: currentStepIndex) {
            animateContentIn()
        }
        .accessibilityIdentifier("OnboardingView")
    }

    // MARK: - Paper Background

    private var paperBackground: some View {
        PaperTextureBackground(
            baseColor: paperColor,
            showCornerDoodles: true
        )
    }

    // MARK: - Top Decoration

    private var topDecoration: some View {
        // 顶部手绘波浪线装饰
        Path { path in
            path.move(to: CGPoint(x: 0, y: 8))
            for i in 0..<20 {
                let x = CGFloat(i) * 20
                path.addCurve(
                    to: CGPoint(x: x + 20, y: 8),
                    control1: CGPoint(x: x + 5, y: 0),
                    control2: CGPoint(x: x + 15, y: 16)
                )
            }
        }
        .stroke(highlightColor.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(height: 16)
        .padding(.top, 8)
    }

    // MARK: - Hand-drawn Page Indicator

    private var handDrawnPageIndicator: some View {
        HStack(spacing: 12) {
            ForEach(visibleSteps.indices, id: \.self) { index in
                if index == currentStepIndex {
                    // 当前页面 - 手绘圆圈
                    Circle()
                        .stroke(highlightColor, style: StrokeStyle(lineWidth: 2.5))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .fill(highlightColor)
                                .frame(width: 6, height: 6)
                        )
                        .scaleEffect(index == currentStepIndex ? 1.1 : 1.0)
                        .animation(motionAnim(.spring(response: 0.3)), value: currentStepIndex)
                } else if index < currentStepIndex {
                    // 已完成 - 打勾
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(WarmTheme.success)
                        .frame(width: 12, height: 12)
                } else {
                    // 未完成 - 小圆点
                    Circle()
                        .fill(sketchColor.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "a11y.onboarding.progress"))
        .accessibilityValue("\(currentStepIndex + 1) / \(totalSteps)")
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: isCompact ? 20 : 32) {

            // 手绘麦克风插图。紧凑屏用 scaleEffect 缩小后再用 frame 锁布局盒:
            // scaleEffect 本身不改布局尺寸,不补 frame 的话占位仍是 140pt。
            handDrawnMicIllustration
                .scaleEffect(isCompact ? 0.63 : 1)
                .frame(
                    width: isCompact ? 88 : nil,
                    height: isCompact ? 88 : nil
                )
                .scaleEffect(illustrationScale)
                .rotationEffect(.degrees(illustrationRotation))
                .animation(motionAnim(.spring(response: 0.6, dampingFraction: 0.7)), value: illustrationScale)
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                // 手写风格标题
                Text(String(localized: "onboarding.welcome"))
                    .font(WarmFont.body(isCompact ? 15 : 18))
                    .foregroundColor(sketchColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("VoiceTodo")
                    .font(WarmFont.title(isCompact ? 28 : 36))
                    .foregroundColor(inkColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // 手绘下划线
                underlineDoodle
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 功能卡片 - 手写便签风格(复用 ValuePropCard,与 Paywall 等入口共享设计语言)
            VStack(spacing: isCompact ? WarmSpacing.sm : WarmSpacing.md) {
                ValuePropCard(
                    emoji: "🎙️",
                    title: String(localized: "onboarding.feature1.title"),
                    description: String(localized: "onboarding.feature1.desc"),
                    compact: isCompact
                )

                ValuePropCard(
                    emoji: "✨",
                    title: String(localized: "onboarding.feature2.title"),
                    description: String(localized: "onboarding.feature2.desc"),
                    compact: isCompact
                )

                ValuePropCard(
                    emoji: "📱",
                    title: String(localized: "onboarding.feature3.title"),
                    description: String(localized: "onboarding.feature3.desc"),
                    compact: isCompact
                )
            }
            .padding(.top, isCompact ? 0 : 24)
            .offset(y: contentOffset)
            .opacity(contentOpacity)
        }
    }

    private var handDrawnMicIllustration: some View {
        ZStack {
            // 背景装饰圆
            Circle()
                .fill(highlightColor.opacity(0.1))
                .frame(width: 140, height: 140)

            // 手绘麦克风
            VStack(spacing: 0) {
                // 麦克风头部
                RoundedRectangle(cornerRadius: 20)
                    .stroke(inkColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 64)
                    .overlay(
                        VStack(spacing: 6) {
                            ForEach(0..<4, id: \.self) { _ in
                                Capsule()
                                    .fill(inkColor.opacity(0.3))
                                    .frame(width: 28, height: 3)
                            }
                        }
                    )

                // 麦克风支架
                Rectangle()
                    .fill(inkColor)
                    .frame(width: 3, height: 16)

                // 底座
                Capsule()
                    .fill(inkColor)
                    .frame(width: 32, height: 8)
            }

            // 手绘装饰元素
            handDrawnSparkles
        }
    }

    private var handDrawnSparkles: some View {
        ZStack {
            // 左上闪光
            starShape
                .frame(width: 16, height: 16)
                .offset(x: -60, y: -50)
                .foregroundColor(highlightColor)

            // 右上闪光
            starShape
                .frame(width: 12, height: 12)
                .offset(x: 55, y: -40)
                .foregroundColor(WarmTheme.warning)

            // 右下闪光
            Circle()
                .fill(highlightColor.opacity(0.6))
                .frame(width: 8, height: 8)
                .offset(x: 50, y: 45)

            // 装饰曲线
            Path { path in
                path.move(to: CGPoint(x: -50, y: 40))
                path.addCurve(
                    to: CGPoint(x: -30, y: 55),
                    control1: CGPoint(x: -45, y: 50),
                    control2: CGPoint(x: -35, y: 55)
                )
            }
            .stroke(sketchColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.5))
            .offset(x: 50, y: -10)
        }
    }

    private var starShape: some Shape {
        Path { path in
            let points: [CGPoint] = [
                CGPoint(x: 8, y: 0),
                CGPoint(x: 10, y: 6),
                CGPoint(x: 16, y: 8),
                CGPoint(x: 10, y: 10),
                CGPoint(x: 8, y: 16),
                CGPoint(x: 6, y: 10),
                CGPoint(x: 0, y: 8),
                CGPoint(x: 6, y: 6)
            ]
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .offsetBy(dx: -8, dy: -8)
    }

    private var underlineDoodle: some View {
        // 手绘波浪下划线
        Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addCurve(to: CGPoint(x: 30, y: 4), control1: CGPoint(x: 10, y: 0), control2: CGPoint(x: 20, y: 8))
            path.addCurve(to: CGPoint(x: 60, y: 4), control1: CGPoint(x: 40, y: 0), control2: CGPoint(x: 50, y: 8))
            path.addCurve(to: CGPoint(x: 90, y: 4), control1: CGPoint(x: 70, y: 0), control2: CGPoint(x: 80, y: 8))
            path.addCurve(to: CGPoint(x: 120, y: 4), control1: CGPoint(x: 100, y: 0), control2: CGPoint(x: 110, y: 8))
        }
        .stroke(highlightColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(height: 8)
    }

    // MARK: - Step: Voice Permissions (microphone + speech merged)

    /// 麦克风和语音识别合并为一页。用户心智里这是同一件事 ——「让 App 听我说话」。
    /// 两张独立卡片各自带授权按钮,用户可按任意顺序授权;即便一项都不授权,右下角「下一步」
    /// 也可点(被拒权限之后能在「设置 - 语音权限」里跳系统设置重新开启)。Skip 作为更轻量
    /// 的文字链接,只在权限未全开时显示 —— 不授权就标记为主动跳过,首次录音前会给引导。
    private var voicePermissionsStep: some View {
        VStack(spacing: isCompact ? 12 : 22) {

            // 麦克风 + 波形 双图标(纯 SF Symbol,不再混用 emoji)
            voicePermissionsIllustration

            VStack(spacing: 10) {
                Text(String(localized: "onboarding.voice.title"))
                    .font(WarmFont.title(isCompact ? 24 : 28))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.voice.desc"))
                    .font(WarmFont.body(isCompact ? 15 : 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 隐私说明 —— 放在卡片上方,用户点授权按钮之前就读得到
            privacyNote(String(localized: "onboarding.voice.privacy"))
                .padding(.top, isCompact ? 0 : 4)
                .offset(y: contentOffset)
                .opacity(contentOpacity)

            VStack(spacing: isCompact ? 12 : 14) {
                permissionCard(
                    systemName: "mic.fill",
                    title: String(localized: "onboarding.mic.card_title"),
                    desc: String(localized: "onboarding.mic.card_desc"),
                    isGranted: permissionManager.micGranted,
                    isDenied: permissionManager.isMicPermanentlyDenied,
                    isRequesting: requestingPermissionTypes.contains(.mic),
                    grantAction: requestMicPermission,
                    buttonTitle: String(localized: "onboarding.button.allow_mic"),
                    grantedText: String(localized: "onboarding.mic.granted"),
                    deniedMessage: ErrorMessages.micDenied,
                    accessId: "AuthorizeMicButton"
                )

                permissionCard(
                    systemName: "waveform",
                    title: String(localized: "onboarding.speech.card_title"),
                    desc: String(localized: "onboarding.speech.card_desc"),
                    isGranted: permissionManager.speechGranted,
                    isDenied: permissionManager.isSpeechPermanentlyDenied,
                    isRequesting: requestingPermissionTypes.contains(.speech),
                    grantAction: requestSpeechPermission,
                    buttonTitle: String(localized: "onboarding.button.allow_speech"),
                    grantedText: String(localized: "onboarding.speech.granted"),
                    deniedMessage: ErrorMessages.speechDenied,
                    accessId: "AuthorizeSpeechButton"
                )
            }
            .padding(.top, isCompact ? 0 : 14)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // Skip 文字链接 —— 灰色小号居中,不抢导航位。
            // 两项权限都已开启时隐藏:此时「跳过」语义为空,留着只会误导
            // (点了还会误标 markSkippedInOnboarding,触发后续不必要的重问)。
            if !permissionManager.allPermissionsGranted {
                Button {
                    permissionManager.markSkippedInOnboarding()
                    nextStep()
                } label: {
                    Text(String(localized: "onboarding.button.skip"))
                        .font(WarmFont.body(14))
                        .foregroundColor(sketchColor.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 6)
                }
                .accessibilityIdentifier("SkipVoicePermissionsButton")
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Step 2.5: Speech Language

    /// 语音识别语言选择。与 HomeSettingsSheet 共享 storageKey,设置页无需任何改动。
    /// `.auto` 默认选中并展开成「跟随系统 · 中文」(systemResolved),让用户第一眼就知道
    /// auto 意味着什么。任何状态下「下一步」都可点 —— 这是个性化设置,不是 gate。
    private var speechLanguageStep: some View {
        VStack(spacing: isCompact ? 14 : 22) {

            ZStack {
                Circle()
                    .fill(highlightColor.opacity(0.1))
                    .frame(width: isCompact ? 80 : 120, height: isCompact ? 80 : 120)
                HStack(spacing: 14) {
                    Image(systemName: "globe.asia.australia")
                        .font(.system(size: isCompact ? 26 : 34, weight: .medium))
                        .foregroundColor(inkColor)
                    Image(systemName: "waveform")
                        .font(.system(size: isCompact ? 26 : 34, weight: .medium))
                        .foregroundColor(highlightColor)
                }
            }
            .scaleEffect(illustrationScale)
            .animation(motionAnim(.spring(response: 0.5)), value: illustrationScale)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(String(localized: "onboarding.speech_language.title"))
                    .font(WarmFont.title(isCompact ? 24 : 28))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.speech_language.desc"))
                    .font(WarmFont.body(isCompact ? 15 : 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            VStack(spacing: isCompact ? 12 : 14) {
                ForEach(SpeechRecognitionLanguage.allCases) { lang in
                    languageOptionRow(lang, isSelected: speechLanguageRaw == lang.rawValue)
                }
            }
            .padding(.top, isCompact ? 0 : 14)
            .offset(y: contentOffset)
            .opacity(contentOpacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "a11y.onboarding.speech_language"))
        .accessibilityIdentifier("OnboardingSpeechLanguageStep")
    }

    /// 语言选项卡:chrome 复用 permissionCard(RoundedRectangle + cardBackground + shadow + 描边)。
    /// 选中态:描边换 highlightColor + 右侧 checkmark.circle.fill —— 与 PaywallView.ProductCard 一致。
    @ViewBuilder
    private func languageOptionRow(_ lang: SpeechRecognitionLanguage, isSelected: Bool) -> some View {
        Button {
            speechLanguageRaw = lang.rawValue
        } label: {
            HStack(spacing: isCompact ? 10 : 14) {
                Image(systemName: "globe")
                    .font(.system(size: isCompact ? 20 : 24, weight: .medium))
                    .foregroundColor(inkColor)
                    .frame(width: isCompact ? 36 : 44, height: isCompact ? 36 : 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.displayName)
                        .font(WarmFont.headline(isCompact ? 15 : 17))
                        .foregroundColor(inkColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)

                    if lang == .auto {
                        // 把「跟随系统」展开成「跟随系统 · 中文」,
                        // systemResolved 让 auto 不再是黑箱。
                        Text(String(localized: "onboarding.speech_language.auto_resolved \(SpeechRecognitionLanguage.systemResolved.displayName)"))
                            .font(WarmFont.caption(isCompact ? 13 : 14))
                            .foregroundColor(sketchColor)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: isCompact ? 20 : 22))
                    .foregroundColor(isSelected ? highlightColor : .clear)
                    .accessibilityHidden(true)
            }
            .padding(isCompact ? 14 : 20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? highlightColor : sketchColor.opacity(0.15),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SpeechLanguageOption_\(lang.rawValue)")
    }

    // MARK: - Step: Demo(一句话 → 两条待办)

    /// 静态 before/after 演示:一句口语 → 两条整理好的待办。
    /// 设计动机(2026-08-23 拍板):三张 feature 卡是「声明」,用户不买账;
    /// 产品的说服力在「乱糟糟的口语变成整齐待办」这个瞬间,把它前置到
    /// onboarding 里演示一遍。示例台词与 completion 页/主页 hint 的
    /// `home.first_trial.example` 刻意不同——那是用户接下来要照着说的句子,
    /// 这里是演示用的另一句,避免同一句话出现三遍。
    private var demoStep: some View {
        VStack(spacing: isCompact ? 16 : 24) {
            VStack(spacing: 10) {
                Text(String(localized: "onboarding.demo.title"))
                    .font(WarmFont.title(isCompact ? 24 : 28))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.demo.desc"))
                    .font(WarmFont.body(isCompact ? 15 : 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // Before:口语原文,手写便签风格
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .medium))
                    .foregroundColor(highlightColor)
                    .frame(width: isCompact ? 32 : 40)
                    .accessibilityHidden(true)

                Text(String(localized: "onboarding.demo.speech"))
                    .font(WarmFont.body(isCompact ? 15 : 17))
                    .foregroundColor(inkColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isCompact ? 14 : 18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(sketchColor.opacity(0.15), lineWidth: 1)
            )
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 转化箭头(方向敏感,RTL 翻转不适用——垂直方向)
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(highlightColor)
                .accessibilityHidden(true)
                .offset(y: contentOffset)
                .opacity(contentOpacity)

            // After:两条整理好的待办
            VStack(spacing: isCompact ? 10 : 12) {
                demoTodoRow(
                    title: String(localized: "onboarding.demo.todo1"),
                    timeChip: String(localized: "onboarding.demo.todo1.time")
                )
                demoTodoRow(
                    title: String(localized: "onboarding.demo.todo2"),
                    timeChip: nil
                )
            }
            .padding(isCompact ? 14 : 18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(highlightColor.opacity(0.35), lineWidth: 1)
            )
            .offset(y: contentOffset)
            .opacity(contentOpacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "onboarding.demo.title"))
        .accessibilityIdentifier("OnboardingDemoStep")
    }

    /// 演示页的单条待办行:空选框 + 标题 + 时间胶囊。纯视觉,不可交互。
    private func demoTodoRow(title: String, timeChip: String?) -> some View {
        HStack(spacing: 12) {
            Circle()
                .stroke(sketchColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(WarmFont.headline(isCompact ? 15 : 17))
                .foregroundColor(inkColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if let timeChip {
                Text(timeChip)
                    .font(WarmFont.caption(isCompact ? 12 : 13))
                    .foregroundColor(highlightColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(highlightColor.opacity(0.1))
                    )
            }
        }
    }

    private var voicePermissionsIllustration: some View {
        ZStack {
            Circle()
                .fill(highlightColor.opacity(0.1))
                .frame(width: isCompact ? 64 : 120, height: isCompact ? 64 : 120)

            // 麦克风 + 波形 并列,纯 SF Symbol,统一矢量风格
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: isCompact ? 22 : 34, weight: .medium))
                    .foregroundColor(inkColor)

                Image(systemName: "waveform")
                    .font(.system(size: isCompact ? 22 : 34, weight: .medium))
                    .foregroundColor(highlightColor)
            }
        }
        .scaleEffect(illustrationScale)
        .animation(motionAnim(.spring(response: 0.5)), value: illustrationScale)
        .accessibilityHidden(true)
    }

    // MARK: - Permission Card

    /// 单张权限卡:图标 + 标题 + 描述 + 行动区(按钮 / 已授权 / 被拒绝三态)。
    /// Onboarding 权限合并页有两张这样的卡(麦克风、语音识别)。
    private func permissionCard(
        systemName: String,
        title: String,
        desc: String,
        isGranted: Bool,
        isDenied: Bool,
        isRequesting: Bool,
        grantAction: @escaping () -> Void,
        buttonTitle: String,
        grantedText: String,
        deniedMessage: String,
        accessId: String
    ) -> some View {
        VStack(spacing: isCompact ? 10 : 14) {
            HStack(spacing: isCompact ? 10 : 14) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : systemName)
                    .font(.system(size: isCompact ? 22 : 28, weight: .medium))
                    .foregroundColor(isGranted ? WarmTheme.success : inkColor)
                    .frame(width: isCompact ? 36 : 44, height: isCompact ? 36 : 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(WarmFont.headline(isCompact ? 15 : 17))
                        .foregroundColor(inkColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)

                    Text(desc)
                        .font(WarmFont.caption(isCompact ? 13 : 14))
                        .foregroundColor(sketchColor)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }

                Spacer(minLength: 0)
            }

            permissionActionArea(
                isGranted: isGranted,
                isDenied: isDenied,
                isRequesting: isRequesting,
                grantAction: grantAction,
                buttonTitle: buttonTitle,
                grantedText: grantedText,
                deniedMessage: deniedMessage,
                accessId: accessId
            )
        }
        .padding(isCompact ? 14 : 20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(WarmTheme.cardBackground)
                .shadow(color: sketchColor.opacity(0.08), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(sketchColor.opacity(0.15), lineWidth: 1)
        )
    }

    /// 紧凑屏被拒附注:消息 + 右侧小胶囊「打开设置」按钮内联单行,权限页与日历页共用,
    /// 仅 accessId 不同(独立 id 避免两页前后出现时 UI 测试跨页歧义匹配)。
    /// 常规的上下排 VStack 在两卡全被拒时比授权态高 ~38pt,会撑破 SE 预算;
    /// 内联后高度反而低于授权按钮态。
    private func compactDeniedNote(message: String, accessId: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(WarmFont.caption(12))
                .foregroundColor(sketchColor)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)

            Button(action: { permissionManager.openAppSettings() }) {
                Label {
                    Text(String(localized: "onboarding.open_settings"))
                        .font(WarmFont.caption(12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } icon: {
                    Image(systemName: "gear")
                        .font(.system(size: 10))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(inkColor))
            }
            .accessibilityIdentifier(accessId)
            .accessibilityHint(String(localized: "a11y.onboarding.open_settings_hint"))
        }
    }

    @ViewBuilder
    private func permissionActionArea(
        isGranted: Bool,
        isDenied: Bool,
        isRequesting: Bool,
        grantAction: @escaping () -> Void,
        buttonTitle: String,
        grantedText: String,
        deniedMessage: String,
        accessId: String
    ) -> some View {
        if isGranted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16))
                Text(grantedText)
                    .font(WarmFont.body(15))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            .foregroundColor(WarmTheme.success)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isDenied {
            if isCompact {
                compactDeniedNote(message: deniedMessage, accessId: "OpenSettingsButton")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(deniedMessage)
                        .font(WarmFont.caption(13))
                        .foregroundColor(sketchColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Button(action: { permissionManager.openAppSettings() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                                .font(.system(size: 12))
                            Text(String(localized: "onboarding.open_settings"))
                                .font(WarmFont.body(14))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(inkColor))
                    }
                    .accessibilityIdentifier("OpenSettingsButton")
                    .accessibilityHint(String(localized: "a11y.onboarding.open_settings_hint"))
                }
            }
        } else {
            Button(action: grantAction) {
                HStack(spacing: 8) {
                    if isRequesting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text(buttonTitle)
                            .font(WarmFont.headline(15))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                // 紧凑屏 vertical 12:12×2 + 文本 ~20 ≈ 44pt,守住 HIG 最小命中区
                .padding(.vertical, isCompact ? 12 : 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(highlightColor)
                        .shadow(color: highlightColor.opacity(0.25), radius: 6, y: 3)
                )
            }
            .disabled(isRequesting)
            .accessibilityIdentifier(accessId)
            .accessibilityHint(String(localized: "a11y.onboarding.authorize_hint"))
        }
    }

    // MARK: - Privacy Note

    private func privacyNote(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: isCompact ? 12 : 14))
                .foregroundColor(sketchColor.opacity(0.6))

            Text(text)
                .font(WarmFont.caption(13))
                .foregroundColor(sketchColor.opacity(0.8))
                // 紧凑屏锁 2 行:en 长文案(语音隐私说明 ~100 字符)3 行会撑破 SE 预算,
                // 用最小缩放换行数,符合项目「lineLimit + minimumScaleFactor ≥0.7」规则。
                .lineLimit(isCompact ? 2 : nil)
                .minimumScaleFactor(isCompact ? 0.7 : 1)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isCompact ? 7 : 10)
        .background(
            Capsule()
                .fill(sketchColor.opacity(0.06))
        )
    }

    // MARK: - Step 4: Action Button Guide

    private var actionButtonGuideStep: some View {
        VStack(spacing: isCompact ? 16 : 28) {

            // Action Button 插图。紧凑屏 scaleEffect + frame 锁布局盒(同欢迎页麦克风插图)。
            actionButtonIllustration
                .scaleEffect(isCompact ? 0.75 : 1)
                .frame(height: isCompact ? 120 : nil)

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.action_button.title"))
                    .font(WarmFont.title(isCompact ? 24 : 28))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.action_button.desc"))
                    .font(WarmFont.body(isCompact ? 15 : 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 设置步骤卡片
            VStack(spacing: 12) {
                instructionStep(number: 1, text: String(localized: "onboarding.action_button.step1"), icon: "gear")
                instructionStep(number: 2, text: String(localized: "onboarding.action_button.step2"), icon: "button.programmable")
                instructionStep(number: 3, text: String(localized: "onboarding.action_button.step3"), icon: "bolt")
                instructionStep(number: 4, text: String(localized: "onboarding.action_button.step4"), icon: "checkmark")
            }
            .padding(isCompact ? 14 : 20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 12, y: 6)
            )
            .padding(.top, isCompact ? 8 : 16)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            Text(String(localized: "onboarding.action_button.hint"))
                .font(WarmFont.caption(14))
                .foregroundColor(sketchColor.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private var actionButtonIllustration: some View {
        ZStack {
            // 手机轮廓
            RoundedRectangle(cornerRadius: 28)
                .stroke(inkColor, style: StrokeStyle(lineWidth: 2.5))
                .frame(width: 80, height: 160)

            // Action Button 区域
            Circle()
                .fill(highlightColor)
                .frame(width: 20, height: 20)
                .offset(x: 30, y: -60)

            // 手指按压指示
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 15, y: 15))
            }
            .stroke(highlightColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .offset(x: 55, y: -85)

            Text(String(localized: "onboarding.action_button.press_here"))
                .font(WarmFont.body(12))
                .foregroundColor(highlightColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .offset(x: 65, y: -95)

            // 屏幕内容
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(sketchColor.opacity(0.1))
                    .frame(width: 50, height: 8)

                RoundedRectangle(cornerRadius: 4)
                    .fill(sketchColor.opacity(0.1))
                    .frame(width: 40, height: 8)

                Spacer()

                // 麦克风图标
                Circle()
                    .fill(highlightColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16))
                            .foregroundColor(highlightColor)
                    )

                Spacer()
            }
            .padding(.vertical, 20)
            .frame(width: 70, height: 140)
        }
        .scaleEffect(illustrationScale)
        .animation(motionAnim(.spring(response: 0.5)), value: illustrationScale)
    }

    private func instructionStep(number: Int, text: String, icon: String) -> some View {
        HStack(spacing: 16) {
            // 步骤数字圆圈
            ZStack {
                Circle()
                    .stroke(highlightColor, lineWidth: 2)
                    .frame(width: isCompact ? 26 : 32, height: isCompact ? 26 : 32)

                Text(verbatim: "\(number)")
                    .font(WarmFont.title(isCompact ? 14 : 16))
                    .foregroundColor(highlightColor)
            }

            Text(text)
                .font(WarmFont.body(isCompact ? 15 : 16))
                .foregroundColor(inkColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(sketchColor.opacity(0.5))
        }
    }

    // MARK: - Step 5: Completion

    /// Completion 页 = 首次语音试用的交棒点:不再放静态 tip,
    /// 而是给一句可直接照着说的示例台词,把用户推向主页的第一次录音。
    /// 台词与主页 FirstVoiceTrialHintView 的 `home.first_trial.example` 同源——
    /// 用户在这里看到的句子,关掉 sheet 后 hint 里还是这一句,认知连续。
    private var completionStep: some View {
        VStack(spacing: isCompact ? 24 : 32) {

            // 成功庆祝插图
            celebrationIllustration

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.done.trial_title"))
                    .font(WarmFont.title(isCompact ? 28 : 32))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.done.trial_desc"))
                    .font(WarmFont.body(isCompact ? 15 : 18))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)

                // 已订阅用户额外显示感谢文案(实时读 isPro)。
                if entitlement.isPro {
                    Text(String(localized: "onboarding.done.pro_thanks"))
                        .font(WarmFont.body(15))
                        .foregroundColor(highlightColor)
                        .padding(.top, 4)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 示例台词卡片:原三条 tipRow 收敛而来,只留一个动作指引。
            VStack(spacing: isCompact ? 8 : 12) {
                Label {
                    Text(String(localized: "home.first_trial.hint"))
                        .font(WarmFont.body(isCompact ? 13 : 15))
                        .foregroundColor(sketchColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                } icon: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15))
                        .foregroundColor(highlightColor)
                }

                Text("「\(String(localized: "home.first_trial.example"))」")
                    .font(WarmFont.body(isCompact ? 17 : 20).weight(.medium))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(isCompact ? 14 : 20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 12, y: 6)
            )
            .padding(.top, isCompact ? 12 : 20)
            .offset(y: contentOffset)
            .opacity(contentOpacity)
        }
    }

    private var celebrationIllustration: some View {
        ZStack {
            // 彩带效果
            ForEach(0..<8, id: \.self) { i in
                confettiPiece(rotation: Double(i) * 45)
            }

            // 主图标
            ZStack {
                Circle()
                    .fill(WarmTheme.success.opacity(0.15))
                    .frame(width: 100, height: 100)

                Circle()
                    .fill(WarmTheme.success)
                    .frame(width: 70, height: 70)

                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }
            .scaleEffect(illustrationScale)
            .animation(motionAnim(.spring(response: 0.5, dampingFraction: 0.6)), value: illustrationScale)
        }
        // 紧凑屏整体缩小庆祝插图(scaleEffect + frame 锁布局盒)
        .scaleEffect(isCompact ? 0.78 : 1)
        .frame(height: isCompact ? 110 : 140)
    }

    private func confettiPiece(rotation: Double) -> some View {
        let colors: [Color] = [WarmTheme.primary, WarmTheme.warning, WarmTheme.success, highlightColor]
        let color = colors[Int(rotation / 90) % colors.count]

        return Rectangle()
            .fill(color)
            .frame(width: 8, height: 20)
            .cornerRadius(4)
            .offset(x: 50, y: 0)
            .rotationEffect(.degrees(rotation))
            .opacity(0.7)
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 16) {
            // 后退按钮(首步隐藏)
            if currentStepIndex > 0 {
                Button(action: {
                    withAnimation(motionAnim(.spring(response: 0.4))) {
                        currentStepIndex = max(currentStepIndex - 1, 0)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .flipsForRightToLeftLayoutDirection(true)
                        Text(String(localized: "onboarding.back"))
                            .font(WarmFont.body(16))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(sketchColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .stroke(sketchColor.opacity(0.3), lineWidth: 1.5)
                    )
                }
                .accessibilityIdentifier("BackButton")
            }

            Spacer()

            // 前进/完成按钮。所有步骤(包括权限页)始终可用 —— 权限被拒不该卡住 onboarding,
            // 用户随时能在「设置 - 语音权限」里重新开启(跳转系统设置)。
            Button(action: nextStep) {
                HStack(spacing: 8) {
                    Text(buttonTitle)
                        .font(WarmFont.headline(17))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if currentStepIndex < totalSteps - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(highlightColor)
                        .shadow(
                            color: highlightColor.opacity(0.3),
                            radius: 8,
                            y: 4
                        )
                )
            }
            .accessibilityIdentifier("NextButton")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, isCompact ? 16 : 24)
    }

    // MARK: - Computed Properties

    private var buttonTitle: String {
        switch currentStep {
        case .completion:
            // completion 页按钮即交棒动作:关 sheet → 主页 arm 首次语音试用 hint
            return String(localized: "onboarding.button.try_voice")
        case .actionButton:
            return String(localized: "onboarding.button.got_it")
        default:
            // 中间各步(含权限页)统一「下一步」——按钮文案不一致会让人
            // 怀疑每一步的语义不同,实际都是同一导航动作。
            return String(localized: "onboarding.button.next")
        }
    }

    // MARK: - Actions

    private func requestMicPermission() {
        requestingPermissionTypes.insert(.mic)

        Task {
            _ = await permissionManager.requestMicPermission()
            requestingPermissionTypes.remove(.mic)
        }
    }

    private func requestSpeechPermission() {
        requestingPermissionTypes.insert(.speech)

        Task {
            _ = await permissionManager.requestSpeechPermission()
            requestingPermissionTypes.remove(.speech)
        }
    }

    private func nextStep() {
        // 离开权限页时若用户没把两项权限都拿到,视同主动跳过 —— 标志位会被首次录音前的
        // 引导 sheet 读到,给出更详细的开启说明。Skip 按钮已经独立调过 markSkippedInOnboarding,
        // 这里再调一次是幂等的(PermissionManager 内部 guard 了重复写)。
        if currentStep == .voicePermissions && !permissionManager.allPermissionsGranted {
            permissionManager.markSkippedInOnboarding()
        }
        if currentStepIndex == totalSteps - 1 {
            // 首次语音试用 arm:权限齐 → .pending(主页显示 hint 等首次录音);
            // 不齐 → .dismissed(由 VoicePermissionRepromptSheet 接管,不叠加两层引导)。
            // 口径见 docs/onboarding-first-voice-trial.md §3.2c。
            firstVoiceTrialRaw = FirstVoiceTrial
                .armedState(allPermissionsGranted: permissionManager.allPermissionsGranted)
                .rawValue
            // 权限未齐直接 dismissed 的路径也记 armed:漏斗分母包含全部完成 onboarding 的用户。
            Telemetry.record(.firstVoiceTrial(stage: FirstVoiceTrialStage.armed))
            hasCompletedOnboarding = true
        } else {
            withAnimation(motionAnim(.spring(response: 0.4))) {
                // clamp 防御:visibleSteps 在 onboarding 期间收缩(理论上 isPro 变化)
                // 会导致 currentStepIndex 越界。这里显式 clamp 而非静默 fallback。
                currentStepIndex = min(currentStepIndex + 1, visibleSteps.count - 1)
            }
        }
    }

    private func animateContentIn() {
        // 「减弱动态效果」开启时跳过入场动画，直接显示终态
        guard !reduceMotion else {
            contentOffset = 0
            contentOpacity = 1
            illustrationScale = 1.0
            illustrationRotation = 0
            return
        }

        contentOffset = 30
        contentOpacity = 0
        illustrationScale = 0.8
        illustrationRotation = -5

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                illustrationScale = 1.0
                illustrationRotation = 0
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(WarmAnimation.springEntrance) {
                contentOffset = 0
                contentOpacity = 1
            }
        }
    }
}

// MARK: - Preview

#Preview("Onboarding - Step 1") {
    struct PreviewWrapper: View {
        @State var completed = false
        @StateObject var permissionManager = PermissionManager()
        @StateObject var entitlement = EntitlementManager()

        var body: some View {
            OnboardingView(
                permissionManager: permissionManager,
                hasCompletedOnboarding: $completed
            )
            .environmentObject(entitlement)
            .environmentObject(QuotaUsage())
        }
    }

    return PreviewWrapper()
}
