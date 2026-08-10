import SwiftUI

// MARK: - 手绘风格 Onboarding
// 设计理念：温暖手写笔记本风格，仿佛翻开一本精心制作的手账

/// Onboarding 步骤。`visibleSteps` 会根据设备能力(Action Button)
/// 和订阅状态(Pro)动态过滤,旧机型或已付费用户会跳过对应步骤。
private enum OnboardingStep: CaseIterable {
    case welcome
    case voicePermissions
    case actionButton
    case proPaywall
    case completion
}

/// 标记当前正在请求哪一类权限,只让对应卡片的按钮显示 spinner。
private enum PermissionRequestType {
    case mic
    case speech
}

/// 首次启动引导视图 - 温暖手写风格
/// 分步引导用户完成权限配置(可选 Action Button 设置)
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    @Binding var hasCompletedOnboarding: Bool
    /// Onboarding 开始时的订阅状态快照。用户在 proPaywall 页订阅成功会翻转 entitlement.isPro,
    /// 若 visibleSteps 跟着实时变化会导致步骤索引错位,故整个 onboarding 期间固定这份快照。
    /// isPro=true 的老用户重装不应再被卖 → showsProStep=false → 跳过 proPaywall 步骤。
    private let showsProStep: Bool

    // 无障碍：尊重「减弱动态效果」设置
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// EntitlementManager 通过 environmentObject 注入(VoiceTodoApp 的 sheet 显式传入)。
    /// 监听 isPro 翻转,在 proPaywall 步骤订阅成功后自动前进到 completionStep。
    @EnvironmentObject private var entitlement: EntitlementManager

    @State private var currentStepIndex = 0
    // 用 Set 而非单个值:两张权限卡可独立授权,各自 spinner 互不覆盖。
    @State private var requestingPermissionTypes: Set<PermissionRequestType> = []

    // 动画状态
    @State private var contentOffset: CGFloat = 30
    @State private var contentOpacity: Double = 0
    @State private var illustrationScale: CGFloat = 0.8
    @State private var illustrationRotation: Double = -5

    init(
        permissionManager: PermissionManager,
        hasCompletedOnboarding: Binding<Bool>,
        entitlement: EntitlementManager
    ) {
        self.permissionManager = permissionManager
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self.showsProStep = !entitlement.isPro
    }

    // 使用 WarmTheme 统一配色
    private var inkColor: Color { WarmTheme.ink }
    private var paperColor: Color { WarmTheme.paperBackground }
    private var highlightColor: Color { WarmTheme.primary }
    private var sketchColor: Color { WarmTheme.sketch }

    /// 当前设备实际要走的步骤序列。Action Button 步骤只在支持的机型上出现;
    /// Pro 付费墙步骤只对未付费用户出现(用 init 时的 isPro 快照,不实时跟随)。
    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .actionButton:
                return ActionButtonCapability.isSupported
            case .proPaywall:
                return showsProStep
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
                    .padding(.top, 20)

                // 内容区
                ScrollView {
                    VStack(spacing: 0) {
                        Group {
                            switch currentStep {
                            case .welcome:
                                welcomeStep
                            case .voicePermissions:
                                voicePermissionsStep
                            case .actionButton:
                                actionButtonGuideStep
                            case .proPaywall:
                                proPaywallStep
                            case .completion:
                                completionStep
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
                .frame(maxHeight: .infinity)

                // 底部按钮:
                // - 权限合并页:用 Continue 替代 Next(授权后才亮)
                // - Pro 付费墙:自带 CTA(PaywallContent 内) + 外层「以后再说」,不显示底部栏
                if !shouldHideBottomBar {
                    bottomButtons
                }
            }
        }
        .onAppear {
            // 每次页面显示时重新检查权限状态（用户可能从系统设置返回）
            permissionManager.checkCurrentStatus()
            animateContentIn()
        }
        .onChange(of: currentStepIndex) {
            animateContentIn()
        }
        // 订阅成功(isPro 翻转)后自动前进到 completionStep。
        // 用 currentStep == .proPaywall 守卫,避免 isPro 在其他步骤变化时误触。
        .onChange(of: entitlement.isPro) { _, becamePro in
            guard becamePro, currentStep == .proPaywall else { return }
            nextStep()
        }
        .accessibilityIdentifier("OnboardingView")
    }

    /// Pro 付费墙自带 CTA(PaywallContent 内)+ 外层「以后再说」,不渲染底部栏。
    private var shouldHideBottomBar: Bool {
        currentStep == .proPaywall
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
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 20)

            // 手绘麦克风插图
            handDrawnMicIllustration
                .scaleEffect(illustrationScale)
                .rotationEffect(.degrees(illustrationRotation))
                .animation(motionAnim(.spring(response: 0.6, dampingFraction: 0.7)), value: illustrationScale)
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                // 手写风格标题
                Text(String(localized: "onboarding.welcome"))
                    .font(WarmFont.body(18))
                    .foregroundColor(sketchColor)

                Text("VoiceTodo")
                    .font(WarmFont.title(36))
                    .foregroundColor(inkColor)

                // 手绘下划线
                underlineDoodle
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 功能卡片 - 手写便签风格(复用 ValuePropCard,与 Paywall 等入口共享设计语言)
            VStack(spacing: WarmSpacing.md) {
                ValuePropCard(
                    emoji: "🎙️",
                    title: String(localized: "onboarding.feature1.title"),
                    description: String(localized: "onboarding.feature1.desc")
                )

                ValuePropCard(
                    emoji: "✨",
                    title: String(localized: "onboarding.feature2.title"),
                    description: String(localized: "onboarding.feature2.desc")
                )

                ValuePropCard(
                    emoji: "📱",
                    title: String(localized: "onboarding.feature3.title"),
                    description: String(localized: "onboarding.feature3.desc")
                )
            }
            .padding(.top, 24)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            Spacer()
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
    /// 两张独立卡片各自带授权按钮,用户可按任意顺序授权;Skip 作为文字链接放在卡片下方,
    /// 右下角 Continue 在两项都授权后才亮起。
    private var voicePermissionsStep: some View {
        VStack(spacing: 22) {
            Spacer()
                .frame(height: 30)

            // 麦克风 + 波形 双图标(纯 SF Symbol,不再混用 emoji)
            voicePermissionsIllustration

            VStack(spacing: 10) {
                Text(String(localized: "onboarding.voice.title"))
                    .font(WarmFont.title(28))
                    .foregroundColor(inkColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(String(localized: "onboarding.voice.desc"))
                    .font(WarmFont.body(17))
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
                .padding(.top, 4)
                .offset(y: contentOffset)
                .opacity(contentOpacity)

            VStack(spacing: 14) {
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
            .padding(.top, 14)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // Skip 文字链接 —— 灰色小号居中,不抢导航位
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

            Spacer()
        }
    }

    private var voicePermissionsIllustration: some View {
        ZStack {
            Circle()
                .fill(highlightColor.opacity(0.1))
                .frame(width: 120, height: 120)

            // 麦克风 + 波形 并列,纯 SF Symbol,统一矢量风格
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(inkColor)

                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .medium))
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
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : systemName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(isGranted ? WarmTheme.success : inkColor)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(WarmFont.headline(17))
                        .foregroundColor(inkColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)

                    Text(desc)
                        .font(WarmFont.caption(14))
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
        .padding(20)
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
                .padding(.vertical, 14)
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
                .font(.system(size: 14))
                .foregroundColor(sketchColor.opacity(0.6))

            Text(text)
                .font(WarmFont.caption(13))
                .foregroundColor(sketchColor.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(sketchColor.opacity(0.06))
        )
    }

    // MARK: - Step 4: Action Button Guide

    private var actionButtonGuideStep: some View {
        VStack(spacing: 28) {
            Spacer()
                .frame(height: 30)

            // Action Button 插图
            actionButtonIllustration

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.action_button.title"))
                    .font(WarmFont.title(28))
                    .foregroundColor(inkColor)

                Text(String(localized: "onboarding.action_button.desc"))
                    .font(WarmFont.body(17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
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
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 12, y: 6)
            )
            .padding(.top, 16)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            Text(String(localized: "onboarding.action_button.hint"))
                .font(WarmFont.caption(14))
                .foregroundColor(sketchColor.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            Spacer()
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
                    .frame(width: 32, height: 32)

                Text(verbatim: "\(number)")
                    .font(WarmFont.title(16))
                    .foregroundColor(highlightColor)
            }

            Text(text)
                .font(WarmFont.body(16))
                .foregroundColor(inkColor)

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(sketchColor.opacity(0.5))
        }
    }

    // MARK: - Step 5: Pro Paywall

    /// Pro 付费墙:onboarding 内嵌的真实订阅页。
    /// 与 sheet 版 PaywallView 共用 PaywallContent —— 价格、试用资格判断、购买调用完全同源。
    /// 「以后再说」始终可见,商品加载失败也一样:onboarding 绝不能被网络或 StoreKit 问题卡死。
    ///
    /// 视觉层级(B 点,详见 docs/onboarding-paywall-merge.md 3.3):
    /// 商品卡 → CTA(PaywallContent 内) → legal → restore → 「以后再说」(本视图外层)。
    /// 「以后再说」是小号灰色文字按钮,位置在最末,不抢 CTA 视觉位。
    private var proPaywallStep: some View {
        VStack(spacing: 16) {
            PaywallContent(context: .onboarding)

            Button {
                nextStep()
            } label: {
                Text(String(localized: "onboarding.pro.cta.later"))
                    .font(WarmFont.body(15))
                    .foregroundColor(sketchColor)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("ProIntroLaterButton")
        }
    }

    // MARK: - Step 6: Completion

    private var completionStep: some View {
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 30)

            // 成功庆祝插图
            celebrationIllustration

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.done.title"))
                    .font(WarmFont.title(32))
                    .foregroundColor(inkColor)

                Text(String(localized: "onboarding.done.desc"))
                    .font(WarmFont.body(18))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                // 已订阅用户额外显示感谢文案;未订阅则维持现状。
                // 注意读实时 isPro 而非 showsProStep —— 后者是 init 快照,
                // 用户在 proPaywall 步骤刚订阅成功时 isPro 已翻转但 showsProStep 仍为 true。
                if entitlement.isPro {
                    Text(String(localized: "onboarding.done.pro_thanks"))
                        .font(WarmFont.body(15))
                        .foregroundColor(highlightColor)
                        .padding(.top, 4)
                }
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 使用提示卡片
            VStack(spacing: 16) {
                tipRow(icon: "🎤", text: String(localized: "onboarding.tip1"))
                tipRow(icon: "✏️", text: String(localized: "onboarding.tip2"))
                tipRow(icon: "📋", text: String(localized: "onboarding.tip3"))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: sketchColor.opacity(0.08), radius: 12, y: 6)
            )
            .padding(.top, 20)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            Spacer()
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
        .frame(height: 140)
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

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Text(icon)
                .font(.system(size: 22))

            Text(text)
                .font(WarmFont.body(16))
                .foregroundColor(inkColor)

            Spacer()
        }
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

            // 前进/完成按钮
            // - 权限合并页:文案「Continue」,两项都授权后才亮(未授权时显示但禁用)
            // - 其他页:文案「Next」/「Got it」/「Get Started」,始终可用
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
                .opacity(primaryButtonOpacity)
            }
            .disabled(isPrimaryButtonDisabled)
            .accessibilityIdentifier("NextButton")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: - Computed Properties

    private var buttonTitle: String {
        switch currentStep {
        case .completion:
            return String(localized: "onboarding.button.start")
        case .actionButton:
            return String(localized: "onboarding.button.got_it")
        case .voicePermissions:
            // 合并页右下角的 Continue —— 授权完成后才可点
            return String(localized: "onboarding.button.continue")
        default:
            return String(localized: "onboarding.button.next")
        }
    }

    /// 权限合并页在两项权限都拿到前禁用 Continue(但保持可见,让用户知道下一步在哪)。
    /// 其他步骤的主按钮永远可用。
    private var isPrimaryButtonDisabled: Bool {
        switch currentStep {
        case .voicePermissions:
            return !permissionManager.allPermissionsGranted
        default:
            return false
        }
    }

    private var primaryButtonOpacity: Double {
        isPrimaryButtonDisabled ? 0.4 : 1.0
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
        if currentStepIndex == totalSteps - 1 {
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
                hasCompletedOnboarding: $completed,
                entitlement: entitlement
            )
            .environmentObject(entitlement)
            .environmentObject(QuotaUsage())
        }
    }

    return PreviewWrapper()
}
