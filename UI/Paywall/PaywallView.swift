import SwiftUI
import StoreKit

/// 订阅页(Paywall)。
///
/// 入口:
/// ① Onboarding 末屏点「开始 3 天免费试用」后弹出
/// ② `AppCoordinator.showPaywall`(配额耗尽时)
/// ③ 设置页手动入口
///
/// Pro 仅提高每日额度,不改核心工作流。恢复购买为 App Store 审核必需入口。
struct PaywallView: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: WarmSpacing.lg) {
                    header
                    comparisonCard
                    valuePropsList
                    productList
                    if entitlement.productLoadState == .success {
                        legalText
                    }
                    restoreButton
                    Spacer(minLength: WarmSpacing.xs)
                }
                .padding(.vertical, WarmSpacing.lg)
            }
            .background(WarmTheme.background.ignoresSafeArea())
            .navigationTitle(Text(String(localized: "paywall.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WarmTheme.textSecondary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .center)
                    }
                    .accessibilityLabel(String(localized: "paywall.close"))
                }
            }
        }
        .task { await entitlement.refresh() }
        .onChange(of: entitlement.isPro) { _, becamePro in
            if becamePro { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: WarmSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.subtitle"))
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, WarmSpacing.lg)
        }
        .padding(.top, WarmSpacing.sm)
    }

    // MARK: - Comparison Card

    /// 用量展示卡:用户当天用量为 0 时显示「免费 limit/天 vs Pro 无限」两列对比卡,
    /// 强化付费动机;已用时切回实时计数,提醒配额耗尽进度。
    ///
    /// 分流顺序:error → 错误胶囊;Pro 用户 → 实时用量卡(对比卡对已订阅者无意义);
    /// Free 且 used == 0 → 对比卡;Free 已用 → 实时用量卡。
    @ViewBuilder
    private var comparisonCard: some View {
        if quotaUsage.loadState == .error {
            quotaErrorPill
        } else if quotaUsage.showsUnlimited {
            liveUsageCard
        } else if quotaUsage.used == 0 {
            freeVsProComparison
        } else {
            liveUsageCard
        }
    }

    /// 两列对比卡:Free (limit/day) vs Pro (Unlimited)。
    private var freeVsProComparison: some View {
        HStack(spacing: 0) {
            freeColumn
            chevronDivider
            proColumn
        }
        .padding(WarmSpacing.md)
        .background(WarmTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
        .shadow(color: WarmTheme.shadowLight, radius: 6, y: 2)
        .padding(.horizontal, WarmSpacing.lg)
    }

    private var freeColumn: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(WarmTheme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.comparison.free"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(quotaUsage.limit) / \(String(localized: "paywall.comparison.per_day"))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var proColumn: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "infinity")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.comparison.pro"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(WarmTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(String(localized: "quota.unlimited"))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(WarmTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 中间的 chevron 分隔(RTL 安全:图标会自动翻转)。
    private var chevronDivider: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(WarmTheme.textMuted)
            .flipsForRightToLeftLayoutDirection(true)
            .accessibilityHidden(true)
            .padding(.horizontal, WarmSpacing.xs)
    }

    /// 实时用量卡(用户已开始消耗额度时显示)。
    private var liveUsageCard: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: quotaUsage.showsUnlimited ? "infinity" : "bolt.circle")
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)
            Text(liveUsageText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            if !quotaUsage.isAuthoritative {
                Text(String(localized: "quota.non_authoritative"))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.chip))
        .padding(.horizontal, WarmSpacing.lg)
    }

    private var liveUsageText: String {
        if quotaUsage.showsUnlimited {
            return "\(String(localized: "quota.unlimited")) · \(String(format: String(localized: "quota.used_only"), quotaUsage.used))"
        }
        return String(format: String(localized: "quota.today_used"), quotaUsage.used, quotaUsage.limit)
    }

    private var quotaErrorPill: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(WarmTheme.warning)
                .accessibilityHidden(true)
            Text(String(localized: "quota.error"))
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(Capsule())
        .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - Value Props

    /// 价值主张:3 张卡片(更高额度 / 3 天试用 / 支持独立开发)。
    /// 复用 OnboardingView 同源 `onboarding.pro.bullet.*` 文案,保证设计语言一致。
    private var valuePropsList: some View {
        VStack(spacing: WarmSpacing.md) {
            ValuePropCard(
                emoji: "🎯",
                title: String(localized: "onboarding.pro.bullet.quota.title"),
                description: String(localized: "onboarding.pro.bullet.quota.desc")
            )
            ValuePropCard(
                emoji: "🎁",
                title: String(localized: "onboarding.pro.bullet.trial.title"),
                description: String(localized: "onboarding.pro.bullet.trial.desc")
            )
            ValuePropCard(
                emoji: "🌱",
                title: String(localized: "onboarding.pro.bullet.support.title"),
                description: String(localized: "onboarding.pro.bullet.support.desc")
            )
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - Product List

    @ViewBuilder
    private var productList: some View {
        switch entitlement.productLoadState {
        case .loading:
            loadingPlaceholder
        case .empty:
            stateMessage(
                icon: "wifi.exclamationmark",
                title: String(localized: "paywall.products_empty.title"),
                subtitle: String(localized: "paywall.products_empty.subtitle"),
                retryAction: { Task { await entitlement.refresh() } }
            )
        case .error:
            stateMessage(
                icon: "exclamationmark.triangle",
                title: String(localized: "paywall.products_empty.title"),
                subtitle: entitlement.lastError ?? ErrorMessages.paywallPurchaseFailed,
                retryAction: { Task { await entitlement.refresh() } }
            )
        case .success:
            VStack(spacing: WarmSpacing.sm) {
                ForEach(entitlement.products, id: \.id) { product in
                    ProductCard(
                        product: product,
                        isYearly: product.id == EntitlementManager.yearlyProductID,
                        isPurchasing: entitlement.isPurchasing,
                        action: { Task { await entitlement.purchase(product) } }
                    )
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
        }
    }

    private func stateMessage(
        icon: String,
        title: String,
        subtitle: String,
        retryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: WarmSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(WarmTheme.textMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            Button(action: retryAction) {
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "paywall.products_empty.retry"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(WarmTheme.primary)
                .padding(.horizontal, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    Capsule()
                        .stroke(WarmTheme.primary, lineWidth: 1.5)
                )
            }
            .disabled(entitlement.productLoadState == .loading)
            .accessibilityIdentifier("PaywallRetryButton")
        }
        .frame(maxWidth: .infinity)
        .padding(WarmSpacing.lg)
        .background(WarmTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
        .padding(.horizontal, WarmSpacing.lg)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: WarmRadius.card)
            .fill(WarmTheme.cardBackground)
            .frame(height: 100)
            .overlay(ProgressView().tint(WarmTheme.primary))
            .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - Legal Text

    /// App Store 审核要求的自动续费合规说明。
    private var legalText: some View {
        Text(String(localized: "paywall.legal.autorenew"))
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundColor(WarmTheme.textMuted)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - Restore

    private var restoreButton: some View {
        Button {
            Task { await entitlement.restorePurchases() }
        } label: {
            Group {
                if entitlement.isRestoring {
                    HStack(spacing: WarmSpacing.xs) {
                        ProgressView().tint(WarmTheme.textSecondary)
                        Text(ErrorMessages.paywallRestoring)
                    }
                } else {
                    Text(String(localized: "paywall.restore"))
                }
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(WarmTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .disabled(entitlement.isRestoring || entitlement.isPurchasing)
        .padding(.top, WarmSpacing.sm)
    }
}

// MARK: - Product Card

private struct ProductCard: View {
    let product: Product
    let isYearly: Bool
    let isPurchasing: Bool
    let action: () -> Void

    private var periodUnit: String {
        isYearly
            ? String(localized: "paywall.period.year")
            : String(localized: "paywall.period.month")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WarmSpacing.md) {
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(product.displayName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if isYearly {
                            Text(String(localized: "paywall.yearly_save"))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, WarmSpacing.xs)
                                .padding(.vertical, 2)
                                .background(WarmTheme.primary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(product.description)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(String(localized: "paywall.card.trial_included"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(WarmTheme.success)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if isPurchasing {
                        ProgressView().tint(WarmTheme.primary)
                    } else {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(product.displayPrice)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(WarmTheme.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("/ \(periodUnit)")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundColor(WarmTheme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            }
            .padding(WarmSpacing.md)
            .background(WarmTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
            .shadow(color: WarmTheme.shadowLight, radius: 6, y: 2)
        }
        .disabled(isPurchasing)
    }
}
