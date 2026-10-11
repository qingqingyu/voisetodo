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

/// 披露卡的 sheet 形态(构造单一来源,两处挂载共用):
/// - 根挂载(`VoiceTodoApp`,cover/sheet 之外的六路径);
/// - 复盘内的**镜像挂载**(`ReviewFlowView` 与拆小 sheet)。镜像的原因:
///   根级 sheet 在 fullScreenCover 常驻期间无法呈现(UKit「一个 presenter
///   同时只呈现一个模态」,复盘 cover 由根呈现——已实验证实),不镜像的
///   gate 在复盘内是死路:点按无反应,且 `ensureAIConsent` 的 continuation
///   永不 resume,后续所有 gate 调用被重入护栏判 false 直到重启。
///   同一 binding 多层镜像时,只有最深一层未占用的 presenting 上下文会
///   实际呈现,不会双弹。决议仍收口在 `handleAIConsentDismissed`
///   (同意写存储 + resume 挂起方,幂等)。
struct AIConsentSheet: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        AIConsentDisclosureCard(
            onAgree: { coordinator.handleAIConsentDismissed(granted: true) },
            onDecline: { coordinator.handleAIConsentDismissed(granted: false) }
        )
        .padding(.vertical, WarmSpacing.lg)
        // 两档可拖:常规字号 430 一屏;AX 大字号(ja/en 长文案)放不下时
        // 用户可上拖到 large——固定单档会在动态字体下裁掉同意按钮。
        .presentationDetents([.height(430), .large])
    }
}
