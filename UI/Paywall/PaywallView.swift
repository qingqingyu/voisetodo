import SwiftUI
import StoreKit

/// 订阅页（Paywall）。入口：① AppCoordinator.showPaywall（配额耗尽）；② 设置页手动入口。
/// Pro 仅提高每日额度，不改核心工作流。恢复购买为 App Store 审核必需入口。
struct PaywallView: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: WarmSpacing.lg) {
                    header
                    quotaSummary
                    productList
                    if let error = entitlement.lastError {
                        Text(error)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundColor(WarmTheme.urgent)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, WarmSpacing.lg)
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
                    Button(String(localized: "paywall.close")) { dismiss() }
                        .foregroundColor(WarmTheme.textSecondary)
                }
            }
        }
        .task { await entitlement.refresh() }
        .onChange(of: entitlement.isPro) { _, becamePro in
            if becamePro { dismiss() }
        }
    }

    // MARK: - Sections

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
                .padding(.horizontal, WarmSpacing.lg)
        }
        .padding(.top, WarmSpacing.sm)
    }

    private var quotaSummary: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: quotaSummaryIcon)
                .foregroundColor(WarmTheme.primary)
            if quotaUsage.loadState == .loading {
                ProgressView()
                    .tint(WarmTheme.primary)
            } else {
                Text(quotaSummaryText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(WarmTheme.textPrimary)
            }
            if !quotaUsage.isAuthoritative {
                Text(String(localized: "quota.non_authoritative"))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textMuted)
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.chip))
    }

    private var quotaSummaryIcon: String {
        switch quotaUsage.loadState {
        case .loading:
            return "hourglass"
        case .error:
            return "exclamationmark.triangle"
        case .empty:
            return "bolt.circle"
        case .success:
            return quotaUsage.showsUnlimited ? "infinity" : "bolt.circle"
        }
    }

    private var quotaSummaryText: String {
        switch quotaUsage.loadState {
        case .loading:
            return String(localized: "quota.loading")
        case .empty:
            return String(localized: "quota.empty")
        case .error:
            return String(localized: "quota.error")
        case .success:
            break
        }
        if quotaUsage.showsUnlimited {
            return "\(String(localized: "quota.unlimited")) · \(String(format: String(localized: "quota.used_only"), quotaUsage.used))"
        }
        return String(format: String(localized: "quota.today_used"), quotaUsage.used, quotaUsage.limit)
    }

    private var productList: some View {
        VStack(spacing: WarmSpacing.sm) {
            switch entitlement.productLoadState {
            case .loading:
                loadingPlaceholder
            case .empty:
                stateMessage(icon: "tray", text: String(localized: "paywall.products_empty"))
            case .error:
                stateMessage(icon: "exclamationmark.triangle", text: entitlement.lastError ?? ErrorMessages.paywallPurchaseFailed)
            case .success:
                ForEach(entitlement.products, id: \.id) { product in
                    ProductCard(
                        product: product,
                        isYearly: product.id == EntitlementManager.yearlyProductID,
                        isPurchasing: entitlement.isPurchasing,
                        action: { Task { await entitlement.purchase(product) } }
                    )
                }
            }
            Text(String(localized: "paywall.trial_hint"))
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textMuted)
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    private func stateMessage(icon: String, text: String) -> some View {
        VStack(spacing: WarmSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(WarmTheme.textMuted)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding(.horizontal, WarmSpacing.md)
        .background(WarmTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: WarmRadius.card)
            .fill(WarmTheme.cardBackground)
            .frame(height: 88)
            .overlay(
                ProgressView()
                    .tint(WarmTheme.primary)
            )
    }

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

    var body: some View {
        Button(action: action) {
            HStack(spacing: WarmSpacing.md) {
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(product.displayName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundColor(WarmTheme.textPrimary)
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
                }
                Spacer()
                HStack(spacing: 2) {
                    if isPurchasing {
                        ProgressView().tint(WarmTheme.primary)
                    } else {
                        Text(product.displayPrice)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(WarmTheme.primary)
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
