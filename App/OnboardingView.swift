import SwiftUI

/// 首次启动引导视图 [v2 新增]
/// 分步引导用户完成权限配置和 Action Button 设置
struct OnboardingView: View {
    @StateObject private var permissionManager = PermissionManager()
    @Binding var hasCompletedOnboarding: Bool

    @State private var currentStep = 0
    @State private var isRequestingPermission = false

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // 进度指示器
            progressBar

            // 内容区
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // 底部按钮
            bottomButtons
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        ProgressView(value: Double(currentStep + 1), total: Double(totalSteps))
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // App 图标
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            // 标题
            Text("欢迎使用 VoiceTodo")
                .font(.system(size: 32, weight: .bold))

            // 副标题
            Text("语音录入，智能提取，随时可见")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 功能特点
            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "waveform", title: "语音录入", description: "按下 Action Button 即可开始")
                featureRow(icon: "brain", title: "智能提取", description: "AI 自动识别待办事项")
                featureRow(icon: "rectangle.topright.inset.filled", title: "随时可见", description: "锁屏和桌面 Widget 展示")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Step 2: Microphone Permission

    private var microphonePermissionStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(permissionManager.micGranted ? .green : .accentColor)

            // 标题
            Text("麦克风权限")
                .font(.system(size: 28, weight: .bold))

            // 说明
            Text("VoiceTodo 需要麦克风来识别你的语音")
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // 权限状态
            if permissionManager.micGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.green)
            } else if permissionManager.isMicPermanentlyDenied {
                VStack(spacing: 12) {
                    Text(ErrorMessages.micDenied)
                        .font(.system(size: 15))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("前往设置") {
                        permissionManager.openAppSettings()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(action: requestMicPermission) {
                    if isRequestingPermission {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("授权麦克风")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequestingPermission)
            }

            Spacer()
        }
    }

    // MARK: - Step 3: Speech Recognition Permission

    private var speechPermissionStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 60))
                .foregroundColor(permissionManager.speechGranted ? .green : .accentColor)

            // 标题
            Text("语音识别权限")
                .font(.system(size: 28, weight: .bold))

            // 说明
            Text("VoiceTodo 需要语音识别来将语音转为文字\n（语音数据仅在本地处理，不会上传服务器）")
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // 权限状态
            if permissionManager.speechGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.green)
            } else if permissionManager.isSpeechPermanentlyDenied {
                VStack(spacing: 12) {
                    Text(ErrorMessages.speechDenied)
                        .font(.system(size: 15))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("前往设置") {
                        permissionManager.openAppSettings()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(action: requestSpeechPermission) {
                    if isRequestingPermission {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("授权语音识别")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequestingPermission)
            }

            Spacer()
        }
    }

    // MARK: - Step 4: Action Button Guide

    private var actionButtonGuideStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(systemName: "button.programmable")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // 标题
            Text("配置 Action Button")
                .font(.system(size: 28, weight: .bold))

            // 说明
            Text("将 VoiceTodo 设置为 Action Button 的快捷操作\n即可一键唤起语音录入")
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // 配置步骤
            VStack(alignment: .leading, spacing: 16) {
                instructionRow(number: 1, text: "打开「设置」")
                instructionRow(number: 2, text: "找到「Action Button」")
                instructionRow(number: 3, text: "选择「快捷方式」")
                instructionRow(number: 4, text: "选择「VoiceTodo」")
            }
            .padding(.horizontal, 32)

            // 跳转设置按钮
            Button("前往系统设置") {
                permissionManager.openAppSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()
        }
    }

    // MARK: - Step 5: Completion

    private var completionStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // 成功图标
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            // 标题
            Text("准备就绪！")
                .font(.system(size: 32, weight: .bold))

            // 说明
            Text("现在你可以按下 Action Button\n开始语音录入待办事项了")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // 提示
            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "lightbulb", text: "你也可以在 App 内点击录音按钮")
                tipRow(icon: "hand.tap", text: "点击待办可查看详情或编辑")
                tipRow(icon: "rectangle.topright.inset.filled", text: "待办会自动显示在 Widget 上")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 16) {
            // 后退按钮
            if currentStep > 0 {
                Button("后退") {
                    withAnimation {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()

            // 前进/完成按钮
            Button(action: nextStep) {
                Text(buttonTitle)
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canProceed)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Helper Views

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(spacing: 16) {
            Text("\(number)")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.system(size: 17))
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Computed Properties

    private var buttonTitle: String {
        if currentStep == totalSteps - 1 {
            return "开始使用"
        } else if currentStep == 1 && !permissionManager.micGranted {
            return "下一步"
        } else if currentStep == 2 && !permissionManager.speechGranted {
            return "下一步"
        } else {
            return "下一步"
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case 1:
            return permissionManager.micGranted
        case 2:
            return permissionManager.speechGranted
        default:
            return true
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
            // 完成引导
            hasCompletedOnboarding = true
        } else {
            // 前进到下一步
            withAnimation {
                currentStep += 1
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var completed = false

        var body: some View {
            OnboardingView(hasCompletedOnboarding: $completed)
        }
    }

    return PreviewWrapper()
}
