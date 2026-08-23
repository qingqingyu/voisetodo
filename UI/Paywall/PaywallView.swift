import SwiftUI
import StoreKit

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
    /// 购买成功后发全局 toast 用(收起时 sheet 已消失,toast 挂在主视图上)。
    /// 由 VoiceTodoApp 的 sheet 内容显式注入,与 entitlement/quotaUsage 同惯例。
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    /// 一屏化:ScrollView 视口高度。初值 .infinity 表示「尚未测得」,
    /// 拿到真值前不参与 contentFits 判定。挂在 ScrollView 自身测,
    /// 高度由容器决定、与内容无关,不会形成布局反馈环。
    @State private var viewportHeight: CGFloat = .infinity
    /// 全部可滚动内容的自然高(PaywallContent + 上下外边距)。
    @State private var contentHeight: CGFloat = 0

    /// 内容是否一屏装下(不滚动)。DEBUG 下经隐藏元素暴露给 UI 测试断言(S18)。
    /// DEBUG 构建 +1:流内 a11y 钩子占 1pt,也算滚动内容,不计入会出现
    /// 「fits 报 1 但实际多 1pt 可滚」的假阳性(与 OnboardingView.contentFits 同款)。
    private var contentFits: Bool {
        guard viewportHeight.isFinite else { return false }
        #if DEBUG
        return contentHeight + 1 <= viewportHeight + 0.5
        #else
        return contentHeight <= viewportHeight + 0.5
        #endif
    }

    /// 值形如 "1|content=560|viewport=740|state=success";
    /// state 附带商品加载态,断言失败时可判断卡在哪个分支。
    private var contentFitsRawValue: String {
        guard viewportHeight.isFinite else { return "pending" }
        let prefix = contentFits ? "1" : "0"
        return "\(prefix)|content=\(Int(contentHeight))|viewport=\(Int(viewportHeight))|state=\(productStateLabel)"
    }

    private var productStateLabel: String {
        switch entitlement.productLoadState {
        case .loading: return "loading"
        case .empty: return "empty"
        case .error: return "error"
        case .success: return "success"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    PaywallContent()
                        .padding(.vertical, WarmSpacing.xs)
                        // 测自然内容高(含上下外边距,在钩子之前):一屏化改造的回归哨兵,
                        // 超预算时 S18 读 PaywallContentFits 断言失败并显示差值。
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { _, newHeight in
                            contentHeight = newHeight
                        }

                    #if DEBUG
                    // UI 测试钩子(照 OnboardingView 的 OnboardingContentFits 范式):
                    // overlay 里的元素进不了 XCUI a11y 树,只能放回流内;
                    // 0×0 会被剪掉,给 1×1 占位,其高度已计入 contentFits 的 DEBUG +1。
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("PaywallContentFits")
                        .accessibilityValue(contentFitsRawValue)
                    #endif
                }
            }
            .background(WarmTheme.background.ignoresSafeArea())
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, newHeight in
                viewportHeight = newHeight
            }
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
            // 兜底路径:restore 等不含购买的场景,靠 isPro 翻正收起。
            if becamePro { dismiss() }
        }
        .onChange(of: entitlement.purchaseSuccessCount) { _, _ in
            // 主路径:购买成功事件驱动收起(与 isPro 状态解耦)。isPro 在订阅过期后可能
            // 停留在 stale-true,二次购买成功时无跳变,只靠上面的 onChange 会漏收起。
            // 先 dismiss 再 toast:toast 挂在主视图,sheet 收起动画期间即升起。
            dismiss()
            coordinator.showToast(message: ErrorMessages.paywallPurchaseSucceeded, style: .success)
        }
    }
}

// MARK: - PaywallContent

/// 付费墙主体内容(仅 sheet 形态:AppCoordinator.presentPaywall 四来源 + 设置页入口;
/// 历史上有 onboarding 内嵌与其形态 enum,已删)。
///
/// 渲染顺序(自上而下):`comparisonCard → valuePropsList → productList → [purchaseCTA] → legalBlock`
///
/// 一屏化(2026-08):删掉 header(副标题与导航标题/CTA 信息重复)与 quota 价值卡
/// (额度信息由对比胶囊表达),区块间距 lg→sm,保证 SE 级视口下 CTA 无需滚动即可见。
struct PaywallContent: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage

    /// 当前选中的商品 ID。productList 加载后默认选年付;找不到则取排序后的第一个。
    /// 购买期间用户仍可点其它卡片切换 —— A 点已要求此时所有卡 disabled,实际不会改值。
    @State private var selectedProductID: String?

    var body: some View {
        VStack(spacing: WarmSpacing.sm) {
            comparisonCard
            valuePropsList
            productList
            if entitlement.productLoadState == .success {
                purchaseCTA
                inlineErrorText
            }
            legalBlock
            Spacer(minLength: WarmSpacing.xxs)
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

    // MARK: - Comparison Card

    /// 用量展示卡:用户当天用量为 0 时显示「免费 N/天 vs Pro M/天」对比胶囊,
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
            freeVsProComparisonPill
        } else {
            liveUsageCard
        }
    }

    /// 单行对比胶囊:「免费版 N 次/天 › Pro 版 M 次/天」。
    /// 原两列对比卡实高 ~96pt 撑破 SE 一屏预算,压成 ~44pt 单行,信息不变;
    /// 文案与图标沿用原两列卡(label + limit_per_day + chevron 分隔)。
    private var freeVsProComparisonPill: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WarmTheme.textSecondary)
                .accessibilityHidden(true)
            comparisonText(
                labelKey: "paywall.comparison.free",
                limit: quotaUsage.limit,
                color: WarmTheme.textPrimary
            )
            chevronDivider
            comparisonText(
                labelKey: "paywall.comparison.pro",
                limit: NetworkConfig.proDailyLimit,
                color: WarmTheme.primary
            )
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.chip))
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 胶囊内一列文本:「<档位名> <N 次/每天>」单行,超宽整体缩放不截断。
    private func comparisonText(
        labelKey: String.LocalizationValue,
        limit: Int,
        color: Color
    ) -> some View {
        Text("\(String(localized: labelKey)) \(String(localized: "paywall.comparison.limit_per_day \(limit)"))")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
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

    /// 价值主张:quota 卡已删(一屏化去重 —— 额度信息由对比胶囊表达);
    /// trial 卡在 intro offer 资格查询完成且 isEligibleForIntroOffer 为 true 时才渲染 (C 点防抖);
    /// support 卡总是显示。全部走 ValuePropCard compact 规格换高度。
    /// 复用 OnboardingView 同源 `onboarding.pro.bullet.*` 文案,保证设计语言一致。
    private var valuePropsList: some View {
        VStack(spacing: WarmSpacing.sm) {
            // 查询期间不渲染试用卡,避免查完前后「无试用 ↔ 有试用」抖动 (C 点)。
            if !entitlement.isCheckingIntroOffer && entitlement.isEligibleForIntroOffer {
                ValuePropCard(
                    emoji: "🎁",
                    title: String(localized: "onboarding.pro.bullet.trial.title"),
                    description: String(localized: "onboarding.pro.bullet.trial.desc"),
                    compact: true
                )
            }
            ValuePropCard(
                emoji: "🌱",
                title: String(localized: "onboarding.pro.bullet.support.title"),
                description: String(localized: "onboarding.pro.bullet.support.desc"),
                compact: true
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
                    ? "storefront" : "wifi.exclamationmark",
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
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
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

    /// 购买/恢复失败的显式反馈(错误显式传播):`.success` 态下 `lastError` 此前无处渲染,
    /// 购买失败、验签失败(unverified)、恢复无可恢复项都会静默无反馈。
    /// `paywall.pending` 也共用此行(中性提示文案)。purchase/restore 开始时会清 lastError,
    /// 双 isPurchasing/isRestoring 守卫只是兜底防飞行中显示陈旧错误。
    @ViewBuilder
    private var inlineErrorText: some View {
        if !entitlement.isPurchasing, !entitlement.isRestoring, let error = entitlement.lastError {
            Text(error)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.warning)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, WarmSpacing.lg)
                .accessibilityIdentifier("PaywallInlineError")
        }
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

    // MARK: - Legal Block

    /// 法务三件套合并的底部块(自动续费说明 + 隐私·条款链接 + 恢复购买),间距压到
    /// xxs 换取一屏预算。legalText 仍只在商品加载成功且 intro 资格查询落定后渲染
    /// (C 点防抖,依赖 isEligibleForIntroOffer 分流);链接与恢复不依赖商品加载结果
    /// (3.1.2:商品加载失败时付费墙仍可见,链接也必须可点)。
    private var legalBlock: some View {
        VStack(spacing: WarmSpacing.xxs) {
            if entitlement.productLoadState == .success && !entitlement.isCheckingIntroOffer {
                legalText
            }
            legalLinks
            restoreButton
        }
    }

    /// App Store 审核要求的自动续费合规说明。
    /// 有试用资格 → paywall.legal.autorenew (含试用期结束后...)
    /// 无试用资格 → paywall.legal.autorenew_no_trial (只讲自动续费)
    private var legalText: some View {
        Text(String(localized: legalKey))
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundColor(WarmTheme.textMuted)
            .multilineTextAlignment(.center)
            // 合规文案不可截断:en autorenew 84 字符,AX 大字号下需 3 行,
            // lineLimit(2)+0.85 缩放兜不住会出 "..."(审核风险),保持 3 行预算。
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, WarmSpacing.lg)
    }

    private var legalKey: String.LocalizationValue {
        entitlement.isEligibleForIntroOffer ? "paywall.legal.autorenew" : "paywall.legal.autorenew_no_trial"
    }

    /// App Store 审核指南 3.1.2:自动续订订阅的付费墙必须提供隐私政策与使用条款的可点链接。
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
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
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
                        .font(.system(size: 16, weight: .bold, design: .rounded))
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
            .padding(WarmSpacing.sm)
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
