import SwiftUI

// MARK: - 手绘风格 Onboarding
// 设计理念：温暖手写笔记本风格，仿佛翻开一本精心制作的手账

/// 首次启动引导视图 - 温暖手写风格
/// 分步引导用户完成权限配置和 Action Button 设置
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    @Binding var hasCompletedOnboarding: Bool

    @State private var currentStep = 0
    @State private var isRequestingPermission = false

    // 动画状态
    @State private var contentOffset: CGFloat = 30
    @State private var contentOpacity: Double = 0
    @State private var illustrationScale: CGFloat = 0.8
    @State private var illustrationRotation: Double = -5

    private let totalSteps = 5

    // 使用 WarmTheme 统一配色
    private var inkColor: Color { WarmTheme.ink }
    private var paperColor: Color { WarmTheme.paperBackground }
    private var highlightColor: Color { WarmTheme.primary }
    private var sketchColor: Color { WarmTheme.sketch }

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
                            case 0:
                                welcomeStep
                            case 1:
                                microphonePermissionStep
                            case 2:
                                speechPermissionStep
                            case 3:
                                actionButtonGuideStep
                            case 4:
                                completionStep
                            default:
                                EmptyView()
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
                .frame(maxHeight: .infinity)

                // 底部按钮
                bottomButtons
            }
        }
        .onAppear {
            // 每次页面显示时重新检查权限状态（用户可能从系统设置返回）
            permissionManager.checkCurrentStatus()
            animateContentIn()
        }
        .onChange(of: currentStep) {
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
            ForEach(0..<totalSteps, id: \.self) { index in
                if index == currentStep {
                    // 当前页面 - 手绘圆圈
                    Circle()
                        .stroke(highlightColor, style: StrokeStyle(lineWidth: 2.5))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .fill(highlightColor)
                                .frame(width: 6, height: 6)
                        )
                        .scaleEffect(index == currentStep ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3), value: currentStep)
                } else if index < currentStep {
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
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: illustrationScale)
                .accessibilityLabel("麦克风插画")
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                // 手写风格标题
                Text("嗨，欢迎来到")
                    .font(.custom("Avenir Next", size: 18))
                    .foregroundColor(sketchColor)

                Text("VoiceTodo")
                    .font(.custom("Avenir Next", size: 36, relativeTo: .largeTitle))
                    .fontWeight(.bold)
                    .foregroundColor(inkColor)

                // 手绘下划线
                underlineDoodle
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 功能卡片 - 手写便签风格
            VStack(spacing: 16) {
                featureStickyNote(
                    emoji: "🎙️",
                    title: "说出来",
                    description: "按下按钮，说出你的待办"
                )

                featureStickyNote(
                    emoji: "✨",
                    title: "变整齐",
                    description: "AI 帮你整理成清晰的列表"
                )

                featureStickyNote(
                    emoji: "📱",
                    title: "看得见",
                    description: "锁屏桌面上随时提醒你"
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

    // MARK: - Feature Sticky Note

    private func featureStickyNote(emoji: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            // Emoji 圆圈
            Text(emoji)
                .font(.system(size: 28))
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(Color.white)
                        .shadow(color: sketchColor.opacity(0.1), radius: 4, y: 2)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("Avenir Next", size: 18)).fontWeight(.semibold)
                    .foregroundColor(inkColor)

                Text(description)
                    .font(.custom("Avenir Next", size: 15))
                    .foregroundColor(sketchColor)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .shadow(color: sketchColor.opacity(0.08), radius: 8, y: 4)
        )
        .overlay(
            // 手绘边框效果
            RoundedRectangle(cornerRadius: 16)
                .stroke(sketchColor.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Step 2: Microphone Permission

    private var microphonePermissionStep: some View {
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 40)

            // 手绘麦克风插图
            permissionIllustration(
                systemName: "mic.fill",
                isGranted: permissionManager.micGranted,
                decoration: "🎤"
            )

            VStack(spacing: 12) {
                Text("需要你的麦克风")
                    .font(.custom("Avenir Next", size: 28)).fontWeight(.bold)
                    .foregroundColor(inkColor)

                Text("这样才能「听」到你说的话呀")
                    .font(.custom("Avenir Next", size: 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 权限状态卡片
            permissionStatusCard(
                isGranted: permissionManager.micGranted,
                isDenied: permissionManager.isMicPermanentlyDenied,
                grantAction: requestMicPermission,
                deniedMessage: ErrorMessages.micDenied
            )
            .padding(.top, 24)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 隐私提示
            privacyNote("录音只用于识别你的语音，不会保存或上传")
                .padding(.top, 16)

            Spacer()
        }
    }

    // MARK: - Step 3: Speech Recognition Permission

    private var speechPermissionStep: some View {
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 40)

            // 手绘语音识别插图
            permissionIllustration(
                systemName: "waveform",
                isGranted: permissionManager.speechGranted,
                decoration: "💬"
            )

            VStack(spacing: 12) {
                Text("还需要语音识别")
                    .font(.custom("Avenir Next", size: 28)).fontWeight(.bold)
                    .foregroundColor(inkColor)

                Text("这样才能把你的话变成文字")
                    .font(.custom("Avenir Next", size: 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 权限状态卡片
            permissionStatusCard(
                isGranted: permissionManager.speechGranted,
                isDenied: permissionManager.isSpeechPermanentlyDenied,
                grantAction: requestSpeechPermission,
                deniedMessage: ErrorMessages.speechDenied
            )
            .padding(.top, 24)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 隐私提示
            privacyNote("语音识别在设备本地进行，数据不会离开你的手机")
                .padding(.top, 16)

            Spacer()
        }
    }

    // MARK: - Permission Illustration

    private func permissionIllustration(systemName: String, isGranted: Bool, decoration: String) -> some View {
        ZStack {
            // 背景圆
            Circle()
                .fill(isGranted ? WarmTheme.success.opacity(0.15) : highlightColor.opacity(0.1))
                .frame(width: 120, height: 120)

            // 图标
            Image(systemName: isGranted ? "checkmark.circle.fill" : systemName)
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(isGranted ? WarmTheme.success : inkColor)

            // 装饰 emoji
            Text(decoration)
                .font(.system(size: 24))
                .offset(x: 45, y: -45)
        }
        .scaleEffect(illustrationScale)
        .animation(.spring(response: 0.5), value: illustrationScale)
    }

    // MARK: - Permission Status Card

    private func permissionStatusCard(
        isGranted: Bool,
        isDenied: Bool,
        grantAction: @escaping () -> Void,
        deniedMessage: String
    ) -> some View {
        VStack(spacing: 16) {
            if isGranted {
                // 已授权状态
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24))
                        .foregroundColor(WarmTheme.success)

                    Text("太好了，已经授权了！")
                        .font(.custom("Avenir Next", size: 17)).fontWeight(.medium)
                        .foregroundColor(WarmTheme.success)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(WarmTheme.success.opacity(0.1))
                )

            } else if isDenied {
                // 被拒绝状态
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(WarmTheme.warning)

                    Text(deniedMessage)
                        .font(.custom("Avenir Next", size: 15))
                        .foregroundColor(sketchColor)
                        .multilineTextAlignment(.center)

                    Button(action: { permissionManager.openAppSettings() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                            Text("去设置里开启")
                        }
                        .font(.custom("Avenir Next", size: 16)).fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(inkColor)
                        )
                    }
                    .accessibilityIdentifier("OpenSettingsButton")
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white)
                        .shadow(color: sketchColor.opacity(0.1), radius: 8, y: 4)
                )

            } else {
                // 待授权状态
                Button(action: grantAction) {
                    HStack(spacing: 12) {
                        if isRequestingPermission {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 20))
                            Text("好的，授权给 VoiceTodo")
                                .font(.custom("Avenir Next", size: 17)).fontWeight(.semibold)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(highlightColor)
                            .shadow(color: highlightColor.opacity(0.3), radius: 8, y: 4)
                    )
                }
                .disabled(isRequestingPermission)
                .accessibilityIdentifier(currentStep == 1 ? "AuthorizeMicButton" : "AuthorizeSpeechButton")
            }
        }
    }

    // MARK: - Privacy Note

    private func privacyNote(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14))
                .foregroundColor(sketchColor.opacity(0.6))

            Text(text)
                .font(.custom("Avenir Next", size: 13))
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
                Text("设置一键录音")
                    .font(.custom("Avenir Next", size: 28)).fontWeight(.bold)
                    .foregroundColor(inkColor)

                Text("把 VoiceTodo 设为 Action Button 的动作\n按一下就能开始录音")
                    .font(.custom("Avenir Next", size: 17))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 设置步骤卡片
            VStack(spacing: 12) {
                instructionStep(number: 1, text: "打开「设置」", icon: "gear")
                instructionStep(number: 2, text: "找到「Action Button」", icon: "button.programmable")
                instructionStep(number: 3, text: "选择「快捷方式」", icon: "bolt")
                instructionStep(number: 4, text: "选「VoiceTodo」", icon: "checkmark")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white)
                    .shadow(color: sketchColor.opacity(0.08), radius: 12, y: 6)
            )
            .padding(.top, 16)
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            Text("设置完成后回到这里点「知道了」即可")
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

            Text("按这里")
                .font(.custom("Avenir Next", size: 12)).fontWeight(.medium)
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
        .animation(.spring(response: 0.5), value: illustrationScale)
    }

    private func instructionStep(number: Int, text: String, icon: String) -> some View {
        HStack(spacing: 16) {
            // 步骤数字圆圈
            ZStack {
                Circle()
                    .stroke(highlightColor, lineWidth: 2)
                    .frame(width: 32, height: 32)

                Text("\(number)")
                    .font(.custom("Avenir Next", size: 16)).fontWeight(.bold)
                    .foregroundColor(highlightColor)
            }

            Text(text)
                .font(.custom("Avenir Next", size: 16))
                .foregroundColor(inkColor)

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(sketchColor.opacity(0.5))
        }
    }

    // MARK: - Step 5: Completion

    private var completionStep: some View {
        VStack(spacing: 32) {
            Spacer()
                .frame(height: 30)

            // 成功庆祝插图
            celebrationIllustration

            VStack(spacing: 12) {
                Text("搞定啦！")
                    .font(.custom("Avenir Next", size: 32)).fontWeight(.bold)
                    .foregroundColor(inkColor)

                Text("现在你可以按下 Action Button\n开始用语音记录待办了")
                    .font(.custom("Avenir Next", size: 18))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .offset(y: contentOffset)
            .opacity(contentOpacity)

            // 使用提示卡片
            VStack(spacing: 16) {
                tipRow(icon: "🎤", text: "也可以在 App 里点录音按钮")
                tipRow(icon: "✏️", text: "点待办可以编辑或删除")
                tipRow(icon: "📋", text: "待办会自动显示在 Widget")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white)
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
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: illustrationScale)
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
                .font(.custom("Avenir Next", size: 16))
                .foregroundColor(inkColor)

            Spacer()
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 16) {
            // 后退按钮
            if currentStep > 0 {
                Button(action: {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep -= 1
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("返回")
                            .font(.custom("Avenir Next", size: 16))
                    }
                    .foregroundColor(sketchColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .stroke(sketchColor.opacity(0.3), lineWidth: 1.5)
                    )
                }
            }

            Spacer()

            // 前进/完成按钮
            Button(action: nextStep) {
                HStack(spacing: 8) {
                    Text(buttonTitle)
                        .font(.custom("Avenir Next", size: 17)).fontWeight(.semibold)

                    if currentStep < totalSteps - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
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
        .padding(.bottom, 24)
    }

    // MARK: - Computed Properties

    private var buttonTitle: String {
        if currentStep == totalSteps - 1 {
            return "开始使用"
        } else if currentStep == 1 && !permissionManager.micGranted && !permissionManager.isMicPermanentlyDenied {
            return "先跳过"
        } else if currentStep == 2 && !permissionManager.speechGranted && !permissionManager.isSpeechPermanentlyDenied {
            return "先跳过"
        } else if currentStep == 3 {
            return "知道了"
        } else {
            return "下一步"
        }
    }

    // MARK: - Actions

    private func requestMicPermission() {
        isRequestingPermission = true

        Task {
            _ = await permissionManager.requestMicPermission()
            isRequestingPermission = false
        }
    }

    private func requestSpeechPermission() {
        isRequestingPermission = true

        Task {
            _ = await permissionManager.requestSpeechPermission()
            isRequestingPermission = false
        }
    }

    private func nextStep() {
        if currentStep == totalSteps - 1 {
            hasCompletedOnboarding = true
        } else {
            withAnimation(.spring(response: 0.4)) {
                currentStep += 1
            }
        }
    }

    private func animateContentIn() {
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
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
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

        var body: some View {
            OnboardingView(permissionManager: permissionManager, hasCompletedOnboarding: $completed)
        }
    }

    return PreviewWrapper()
}
