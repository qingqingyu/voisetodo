import SwiftUI

/// 「转写文本发送第三方 AI 处理」披露卡(App Store 审核指南 5.1.1:数据离开设备
/// 前须明确告知并取得同意)。同一组件两个场景复用,披露口径单一事实源:
/// - Onboarding 权限步(未同意时替代权限卡展示,同意后进入系统权限申请);
/// - 运行时 gate sheet(AppCoordinator.ensureAIConsent,覆盖跳过 onboarding 的路径)。
///
/// 存储写入(AppGroupConfig.setAIConsentGranted)由调用方在 onAgree 里完成,
/// 组件本身不碰 UserDefaults——便于单测与 onboarding 内嵌/sheet 两态复用。
struct AIConsentDisclosureCard: View {
    /// 「同意并继续」回调:调用方负责写同意标志并推进各自流程。
    let onAgree: () -> Void
    /// 「仍不同意」回调:onboarding 场景留在权限步重新考虑;sheet 场景以 false 收起。
    let onDecline: () -> Void

    @State private var showsDeclineDialog = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)

            Text(String(localized: "aiconsent.title"))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            Text(String(localized: "aiconsent.body"))
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .minimumScaleFactor(0.8)

            Link(
                String(localized: "paywall.legal.privacy_link"),
                destination: PaywallLegal.privacyPolicyURL
            )
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Button(action: onAgree) {
                Text(String(localized: "aiconsent.agree"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(WarmTheme.primary)
                            .shadow(color: WarmTheme.primary.opacity(0.3), radius: 8, y: 4)
                    )
            }
            .accessibilityIdentifier("AIConsentAgreeButton")

            Button {
                showsDeclineDialog = true
            } label: {
                Text(String(localized: "aiconsent.decline"))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityIdentifier("AIConsentDeclineButton")
            .confirmationDialog(
                Text(String(localized: "aiconsent.decline_title")),
                isPresented: $showsDeclineDialog,
                titleVisibility: .visible
            ) {
                // 隐私政策出口直接放进 dialog:用户不必先「我再想想」绕回卡片才能看
                // 政策——知情才有有效同意(dialog 盖住了卡上的 Link)。
                Button(String(localized: "aiconsent.view_policy")) {
                    openURL(PaywallLegal.privacyPolicyURL)
                }
                Button(String(localized: "aiconsent.still_decline"), role: .destructive, action: onDecline)
                Button(String(localized: "aiconsent.reconsider"), role: .cancel) {}
            } message: {
                Text(String(localized: "aiconsent.decline_body"))
            }
        }
        .padding(WarmSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 6, y: 2)
        )
        .padding(.horizontal, WarmSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AIConsentCard")
    }
}
