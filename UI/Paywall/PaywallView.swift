import SwiftUI
import StoreKit

// MARK: - Presentation Context

/// 付费墙呈现形态。历史上有 sheet / onboarding 内嵌两种;onboarding 步骤已被移除
/// (paywall 改为首次 wow 后弹 sheet,见 docs/onboarding-first-voice-trial.md §3.5),
/// 仅剩 sheet 形态。保留 enum 以免连带改 `PaywallContent` 的调用签名。
enum PaywallPresentationContext {
    case sheet       // AppCoordinator.presentPaywall(四来源) / 设置页入口
}

/// 付费墙法务链接常量。3.1.2 要求隐私政策 + 使用条款均可点。
/// 使用条款用 Apple 标准最终用户许可协议(未自定义时默认适用于本 app);
/// 隐私政策为 GitHub Pages 公开页,与 App Store Connect 提审表单填的是同一地址。
enum PaywallLegal {
    /// 隐私政策公开页。内容变更直接改 qingqingyu/voicetodo-privacy 仓库并更新页内日期。
    static let privacyPolicyURL = URL(string: "https://qingqingyu.github.io/voicetodo-privacy/")!

    /// Apple 标准最终用户许可协议 (EULA)。
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

// MARK: - PaywallView (sheet 入口)

/// 订阅页 Paywall (sheet 形态)。
///
/// 入口(全部经 `AppCoordinator.presentPaywall(source:)` 收口):
/// ① 首次 wow 之后(自动)
/// ② 累计 5 次录音成功阈值(自动)
/// ③ 配额耗尽(自动)
/// ④ 设置页手动入口
///
/// Pro 仅提高每日额度,不改核心工作流。恢复购买为 App Store 审核必需入口。
struct PaywallView: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PaywallContent(context: .sheet)
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
        .onChange(of: entitlement.isPro) { _, becamePro in
            if becamePro { dismiss() }
        }
    }
}

// MARK: - PaywallContent

/// 付费墙主体内容(现仅 sheet 形态使用;历史上有 onboarding 内嵌,已删)。
///
/// 渲染顺序(自上而下):`header → comparisonCard → valuePropsList → productList → [purchaseCTA + legalText] → legalLinks → restoreButton`
struct PaywallContent: View {
    let context: PaywallPresentationContext

    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage

    /// 当前选中的商品 ID。productList 加载后默认选年付;找不到则取排序后的第一个。
    /// 购买期间用户仍可点其它卡片切换 —— A 点已要求此时所有卡 disabled,实际不会改值。
    @State private var selectedProductID: String?

    var body: some View {
        VStack(spacing: WarmSpacing.lg) {
            header
            comparisonCard
            valuePropsList
            productList
            if entitlement.productLoadState == .success {
                purchaseCTA
                // legalText 依赖 isEligibleForIntroOffer 分流,查询期间不渲染避免抖动 (C 点)。
                if !entitlement.isCheckingIntroOffer {
                    legalText
                }
            }
            // 3.1.2 要求两链接不依赖商品加载结果 —— 商品加载失败时付费墙仍可见,链接也必须可点。
            legalLinks
            restoreButton
            Spacer(minLength: WarmSpacing.xs)
        }
        .task { await entitlement.refresh() }
        .onChange(of: entitlement.products) { _, newProducts in
            // 购买飞行中不重置选中 —— refresh 可能由 transaction listener 触发,
            // 此时改 selectedProductID 会让用户感知到选中漂移。
            guard !entitlement.isPurchasing else { return }
            // 当前选中无效(首次加载/重试后商品变化/选中商品已不存在)时重置:
            // 默认年付,找不到则取排序后第一个。products 已按价格升序排好。
            if selectedProductID == nil || !newProducts.contains(where: { $0.id == selectedProductID }) {
                selectedProductID = newProducts.first(where: { $0.id == EntitlementManager.yearlyProductID })?.id
                    ?? newProducts.first?.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: WarmSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)
            // intro offer 资格查询期间不渲染 subtitle —— 避免查完前后「无试用 ↔ 有试用」抖动 (C 点)。
            // CTA 在此期间显 spinner;subtitle 从无到有不算「先承诺再变脸」。
            if !entitlement.isCheckingIntroOffer {
                Text(String(localized: subtitleKey))
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, WarmSpacing.lg)
            }
        }
        .padding(.top, headerTopPadding)
    }

    /// sheet 有 NavigationStack + toolbar 占位,header 上方需要相应留白。
    /// (原 onboarding 内嵌分支用更紧的 xs,该形态已删除。)
    private var headerTopPadding: CGFloat {
        WarmSpacing.sm
    }

    /// 无试用资格时改用只讲额度的 subtitle,避免对老用户撒谎。
    private var subtitleKey: String.LocalizationValue {
        entitlement.isEligibleForIntroOffer ? "paywall.subtitle" : "paywall.subtitle_no_trial"
    }

    // MARK: - Comparison Card

    /// 用量展示卡:用户当天用量为 0 时显示「免费 N/天 vs Pro M/天」两列对比卡,
    /// 强化付费动机;已用时切回实时计数,提醒配额耗尽进度。
    ///
    /// Pro 档是更高的有限额度、不是无限,两列都展示具体条数。
    ///
    /// 分流顺序:error → 错误胶囊;Pro 用户 → 实时用量卡(对比卡对已订阅者无意义);
    /// Free 且 used == 0 → 对比卡;Free 已用 → 实时用量卡。
    @ViewBuilder
    private var comparisonCard: some View {
        if quotaUsage.loadState == .error {
            quotaErrorPill
        } else if quotaUsage.isPro {
            liveUsageCard
        } else if quotaUsage.used == 0 {
            freeVsProComparison
        } else {
            liveUsageCard
        }
    }

    /// 两列对比卡:Free (freeLimit/day) vs Pro (proDailyLimit/day)。
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
            Text(String(localized: "paywall.comparison.limit_per_day \(quotaUsage.limit)"))
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
            Image(systemName: "bolt.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(WarmTheme.primary)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.comparison.pro"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(WarmTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(String(localized: "paywall.comparison.limit_per_day \(NetworkConfig.proDailyLimit)"))
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
            Image(systemName: "bolt.circle")
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

    /// Pro 档也是有限额度，与免费档同样显示「已用 used/limit」。
    /// `limit` 由代理 `X-Quota-Limit` 提供（Pro 时为 `PAID_DAILY_LIMIT`）。
    private var liveUsageText: String {
        String(format: String(localized: "quota.today_used"), quotaUsage.used, quotaUsage.limit)
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
                .layoutPriority(1)
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(Capsule())
        .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - Value Props

    /// 价值主张:quota 和 support 两张卡总是显示;
    /// trial 卡在 intro offer 资格查询完成且 isEligibleForIntroOffer 为 true 时才渲染 (C 点防抖)。
    /// 复用 OnboardingView 同源 `onboarding.pro.bullet.*` 文案,保证设计语言一致。
    private var valuePropsList: some View {
        VStack(spacing: WarmSpacing.md) {
            ValuePropCard(
                emoji: "🎯",
                title: String(localized: "onboarding.pro.bullet.quota.title"),
                description: String(localized: "onboarding.pro.bullet.quota.desc \(NetworkConfig.proDailyLimit)")
            )
            // 查询期间不渲染试用卡,避免查完前后「无试用 ↔ 有试用」抖动 (C 点)。
            if !entitlement.isCheckingIntroOffer && entitlement.isEligibleForIntroOffer {
                ValuePropCard(
                    emoji: "🎁",
                    title: String(localized: "onboarding.pro.bullet.trial.title"),
                    description: String(localized: "onboarding.pro.bullet.trial.desc")
                )
            }
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
            // StoreKit 返回空数组时静默无原因(模拟器 storekitd 抽风 / 商品未上架 / 真断网 都走这里)。
            // 用当前网络状态间接归因:无网 → 提示网络(归因正确);
            // 有网但空 → 中性"无法连接 App Store",不误导用户去查一个没坏的网络。
            // 归因在渲染时点读取,网络后续变化不主动刷新 —— Retry 会驱动状态变化并重新归因。
            stateMessage(
                icon: NetworkMonitor.shared.isConnected
                    ? "cart.badge.exclamationmark" : "wifi.exclamationmark",
                title: String(localized: "paywall.products_empty.title"),
                subtitle: String(localized: productsEmptySubtitleKey),
                retryAction: { Task { await entitlement.refresh() } }
            )
        case .error:
            stateMessage(
                icon: "exclamationmark.triangle",
                title: String(localized: "paywall.products_empty.title"),
                subtitle: entitlement.lastError ?? ErrorMessages.paywallProductsLoadFailed,
                retryAction: { Task { await entitlement.refresh() } }
            )
        case .success:
            VStack(spacing: WarmSpacing.sm) {
                ForEach(entitlement.products, id: \.id) { product in
                    ProductCard(
                        product: product,
                        isSelected: product.id == selectedProductID,
                        isPurchasing: entitlement.isPurchasing,
                        showsTrialIncluded: entitlement.isEligibleForIntroOffer,
                        action: { selectedProductID = product.id }
                    )
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
        }
    }

    /// `.empty` 态副文案:有网但商品空 → 中性"无法连接 App Store";无网 → 提示检查网络。
    /// StoreKit 空数组不携带失败原因,只能用当前网络状态间接归因(见 productList `.empty` 注释)。
    private var productsEmptySubtitleKey: String.LocalizationValue {
        NetworkMonitor.shared.isConnected
            ? "paywall.products_empty.store_unavailable" : "paywall.products_empty.offline"
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

    // MARK: - Purchase CTA

    /// 主 CTA:点下去直接调 `entitlement.purchase(product)` —— Apple 系统购买弹窗随后弹出。
    /// 行为(详见 docs/onboarding-paywall-merge.md 3.2):
    /// - `isCheckingIntroOffer == true` → spinner 不显文案,避免资格查询前后文案抖动 (C 点)
    /// - `isPurchasing == true` → spinner + disabled,ProductCard 同步弱化 (A 点)
    /// - 商品加载失败 (`.empty`/`.error`) → 不渲染(由 productList 的 stateMessage 接管)
    @ViewBuilder
    private var purchaseCTA: some View {
        Button {
            guard let product = currentSelectedProduct else { return }
            Task { await entitlement.purchase(product) }
        } label: {
            HStack(spacing: WarmSpacing.xs) {
                if showsCTASpinner {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(ctaTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(WarmTheme.primary)
                    .shadow(color: WarmTheme.primary.opacity(0.3), radius: 8, y: 4)
            )
        }
        .disabled(ctaDisabled)
        .accessibilityIdentifier("PaywallPurchaseButton")
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// CTA 是否显示 spinner:资格查询中 或 购买中。
    private var showsCTASpinner: Bool {
        entitlement.isCheckingIntroOffer || entitlement.isPurchasing
    }

    private var ctaDisabled: Bool {
        showsCTASpinner || currentSelectedProduct == nil
    }

    private var currentSelectedProduct: Product? {
        if let id = selectedProductID,
           let product = entitlement.products.first(where: { $0.id == id }) {
            return product
        }
        // fallback: 默认年付,找不到则取排序后第一个
        return entitlement.products.first(where: { $0.id == EntitlementManager.yearlyProductID })
            ?? entitlement.products.first
    }

    /// CTA 文案:有试用资格时用「开始 N 天免费试用」(N 来自 StoreKit 的 SubscriptionPeriod
    /// 转成本地化时长字符串),无资格时用「订阅 Pro」。N 永远从 StoreKit 取,不手写「7 天」。
    private var ctaTitle: String {
        if entitlement.isEligibleForIntroOffer, let period = entitlement.introOfferPeriod {
            let periodStr = period.formattedLocalizedPeriod()
            return String(localized: "paywall.cta.start_trial \(periodStr)")
        }
        return String(localized: "paywall.cta.subscribe")
    }

    // MARK: - Legal Text

    /// App Store 审核要求的自动续费合规说明。
    /// 有试用资格 → paywall.legal.autorenew (含试用期结束后...)
    /// 无试用资格 → paywall.legal.autorenew_no_trial (只讲自动续费)
    private var legalText: some View {
        Text(String(localized: legalKey))
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundColor(WarmTheme.textMuted)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, WarmSpacing.lg)
    }

    private var legalKey: String.LocalizationValue {
        entitlement.isEligibleForIntroOffer ? "paywall.legal.autorenew" : "paywall.legal.autorenew_no_trial"
    }

    /// App Store 审核指南 3.1.2:自动续订订阅的付费墙必须提供隐私政策与使用条款的可点链接。
    /// 两链接在 restoreButton 之上、与 legalText 同级展示,不依赖商品加载结果。
    private var legalLinks: some View {
        HStack(spacing: WarmSpacing.sm) {
            Link(String(localized: "paywall.legal.privacy_link"), destination: PaywallLegal.privacyPolicyURL)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            Text("·")
                .foregroundColor(WarmTheme.textMuted)
                .accessibilityHidden(true)
            Link(String(localized: "paywall.legal.terms_link"), destination: PaywallLegal.termsOfUseURL)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .tint(WarmTheme.textSecondary)
        .padding(.top, WarmSpacing.xxs)
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

/// 商品卡:点击切换 selectedProductID(选择语义,不再触发购买)。
/// 选中态加 primary 描边;购买中所有卡 disabled + opacity(0.5),避免 selectedProductID 在飞行中漂移 (A 点)。
private struct ProductCard: View {
    let product: Product
    let isSelected: Bool
    let isPurchasing: Bool
    let showsTrialIncluded: Bool
    let action: () -> Void

    private var isYearly: Bool {
        product.id == EntitlementManager.yearlyProductID
    }

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
                            .layoutPriority(1)
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
                        .layoutPriority(1)
                    if showsTrialIncluded {
                        Text(String(localized: "paywall.card.trial_included"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(WarmTheme.success)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                // 价格保持显示(弱化后),让用户在购买中仍知道在买什么。
                // A 点:购买期间所有卡 disabled + 弱化,不再在此处显内嵌 spinner ——
                // spinner 只在主 CTA 上,避免双 spinner 视觉噪音。
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product.displayPrice)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(WarmTheme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(verbatim: "/ \(periodUnit)")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(WarmTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(WarmSpacing.md)
            .background(WarmTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .stroke(WarmTheme.primary, lineWidth: isSelected ? 2 : 0)
            )
            .shadow(color: WarmTheme.shadowLight, radius: 6, y: 2)
            .opacity(isPurchasing ? 0.5 : 1.0)
        }
        .disabled(isPurchasing)
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - SubscriptionPeriod 本地化

private extension Product.SubscriptionPeriod {
    /// 把 SubscriptionPeriod 转成本地化的时长字符串(如 "7 days" / "7 天")。
    /// StoreKit 没有现成的 FormatStyle,借用 Foundation 的 DateComponentsFormatter
    /// 处理 day/week/month/year 四种单位 —— 跟随系统语言自动本地化。
    func formattedLocalizedPeriod() -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1

        let components: DateComponents
        switch unit {
        case .day: components = DateComponents(day: value)
        case .week: components = DateComponents(weekOfMonth: value)
        case .month: components = DateComponents(month: value)
        case .year: components = DateComponents(year: value)
        @unknown default: components = DateComponents(day: value)
        }
        // formatter.string(from:) 失败时返回 nil,fallback 到「N + 裸单位英文」——
        // 不静默吞,留可识别的退化值(至少不产生「开始 7 免费试用」这种缺单位的语病)。
        guard let str = formatter.string(from: components) else {
            let unitName: String
            switch unit {
            case .day: unitName = value == 1 ? "day" : "days"
            case .week: unitName = value == 1 ? "week" : "weeks"
            case .month: unitName = value == 1 ? "month" : "months"
            case .year: unitName = value == 1 ? "year" : "years"
            @unknown default: unitName = "days"
            }
            return "\(value) \(unitName)"
        }
        return str
    }
}
