import SwiftUI

/// 用户在 Onboarding 权限页跳过后,首次按下录音按钮时弹出的二次引导 sheet。
///
/// 设计目的:Onboarding 里的「Skip for now」是低门槛出口,但跳过之后用户进主界面
/// 点录音会直接被卡住。这一屏在系统权限弹窗前再插一次说明 —— 告诉用户为什么需要
/// 这两项权限,以及跳过的代价(没法用语音建待办)。比直接抛 toast 更容易挽回。
struct VoicePermissionRepromptSheet: View {
    /// 点「Allow Access」时调用 —— 调用方负责关 sheet 并触发
    /// `permissionManager.ensureVoicePermissionsBeforeRecording()`。
    var onAllow: () -> Void

    /// 点「Not now」时调用 —— 调用方负责关 sheet,不进入录音流程。
    var onDismiss: () -> Void

    // 使用 WarmTheme 统一配色(与 OnboardingView 保持一致)
    private var inkColor: Color { WarmTheme.ink }
    private var highlightColor: Color { WarmTheme.primary }
    private var sketchColor: Color { WarmTheme.sketch }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 8)

            illustration

            VStack(spacing: 12) {
                Text(String(localized: "reprompt.title"))
                    .font(WarmFont.title(24))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(String(localized: "reprompt.desc"))
                    .font(WarmFont.body(15))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                benefitRow(
                    icon: "mic.fill",
                    text: String(localized: "reprompt.mic_benefit")
                )
                benefitRow(
                    icon: "waveform",
                    text: String(localized: "reprompt.speech_benefit")
                )
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 4)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text(String(localized: "reprompt.cta"))
                        .font(WarmFont.headline(17))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(highlightColor)
                                .shadow(color: highlightColor.opacity(0.3), radius: 8, y: 4)
                        )
                }
                .accessibilityIdentifier("RepromptAllowButton")

                Button(action: onDismiss) {
                    Text(String(localized: "reprompt.skip"))
                        .font(WarmFont.body(14))
                        .foregroundColor(sketchColor.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 6)
                }
                .accessibilityIdentifier("RepromptDismissButton")
            }
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .padding(.top, 20)
        .frame(maxWidth: 460)
        .background(WarmTheme.paperBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "reprompt.title"))
    }

    // MARK: - Subviews

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(highlightColor.opacity(0.1))
                .frame(width: 100, height: 100)

            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(inkColor)

                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(highlightColor)
            }
        }
        .accessibilityHidden(true)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(highlightColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(text)
                .font(WarmFont.body(15))
                .foregroundColor(inkColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Preview

#Preview("VoicePermissionRepromptSheet") {
    VoicePermissionRepromptSheet(
        onAllow: { print("allow") },
        onDismiss: { print("dismiss") }
    )
    .background(WarmTheme.background)
}
