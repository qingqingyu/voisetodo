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
    @Environment(\.dismiss) private var dismiss

    /// 购买/恢复成功的反馈事件。非 nil 时 CTA 原地变绿、触发成功触感,约 1.0 秒后自动收起;
    /// 收起后由 `AppCoordinator.handlePaywallDismissed` 在主界面补成功 toast。
    @State private var successEvent: SuccessEvent?

    enum SuccessEvent: Equatable {
        case purchased
        case restored

        var message: String {
            switch self {
            case .purchased: return ErrorMessages.paywallPurchaseSucceeded
            case .restored: return ErrorMessages.paywallRestoreSucceeded
            }
        }
    }

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
                    PaywallContent(successEvent: successEvent)
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
            .navigationTitle(Text(String(localized: navigationTitleKey)))
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
        // 成功反馈画在 CTA 本身上(原地变绿):用户视线不用挪,顶部额度胶囊同时升到
        // Pro 档,「买到了什么」一眼可见。整页遮罩会打断操作且盖住额度变化,已弃用
        // (v2 任务书条目 1)。约 1 秒后收起;toast 由 AppCoordinator 在 sheet
        // onDismiss 后弹——挂在主视图上,不会被本 sheet 盖住。
        .sensoryFeedback(.success, trigger: successEvent) { _, new in new != nil }
        .onChange(of: entitlement.purchaseSuccessCount) { _, _ in
            showSuccess(.purchased)
        }
        .onChange(of: entitlement.restoreSuccessCount) { _, _ in
            showSuccess(.restored)
        }
        .task(id: successEvent) {
            guard successEvent != nil else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// 导航标题文案:已订阅(且非成功窗口)用「VoiceTodo Pro」,否则沿用「升级」。
    /// 条件必须与 `PaywallContent` 的已订阅分支一致——成功窗口内页面仍停在购买 UI,
    /// 标题也要留在「升级」,不得闪成已订阅页。
    private var navigationTitleKey: String.LocalizationValue {
        entitlement.isPro && successEvent == nil
            ? "paywall.title.subscribed"
            : "paywall.title"
    }

    private func showSuccess(_ event: SuccessEvent) {
        successEvent = event
        AccessibilityNotification.Announcement(event.message).post()
    }
}

// MARK: - PaywallContent

/// 付费墙主体内容(仅 sheet 形态:AppCoordinator.presentPaywall 四来源 + 设置页入口;
/// 历史上有 onboarding 内嵌与其形态 enum,已删)。
///
/// 渲染顺序(自上而下):
/// - 已订阅(`entitlement.isPro`):`comparisonCard(实时用量) → subscribedStatusCard → legalBlock(无价格披露)`
/// - 未订阅:`comparisonCard → valuePropsList → productList → [purchaseCTA] → legalBlock(含价格披露)`
///
/// 一屏化(2026-08):删掉 header(副标题与导航标题/CTA 信息重复)与 quota 价值卡
/// (额度信息由对比胶囊表达),区块间距 lg→sm,保证 SE 级视口下 CTA 无需滚动即可见。
struct PaywallContent: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage

    /// 购买/恢复成功事件(来自 PaywallView)。非 nil 时:
    /// - 未订阅分支保持渲染(CTA 原地变绿而不是整页切走,反馈出现在用户刚点的按钮上);
    /// - 顶部额度胶囊升到 Pro 档上限(NetworkConfig.proDailyLimit);
    /// - 商品卡弱化禁用,防止成功窗口内再选方案。
    let successEvent: PaywallView.SuccessEvent?

    /// 默认选中的商品 ID(产品建议推年付,不是硬要求——以后想改推月付改这一行即可)。
    /// 只在「当前没有有效选中」时生效;用户手动选过的方案不会被覆盖。
    static let defaultProductID = EntitlementManager.yearlyProductID

    /// 当前选中的商品 ID。productList 加载后默认选年付;找不到则取排序后的第一个。
    /// 购买期间用户仍可点其它卡片切换 —— A 点已要求此时所有卡 disabled,实际不会改值。
    @State private var selectedProductID: String?
    /// 系统订阅管理页(.manageSubscriptionsSheet)是否展示。关闭后重读权益。
    @State private var showManageSubscriptions = false

    var body: some View {
        VStack(spacing: WarmSpacing.sm) {
            // 成功窗口内不切已订阅分支:反馈要落在用户刚点的那颗 CTA 上(变绿),
            // 整页切换会把按钮、商品列表一并抽走,「页面突然变了」反而像出错。
            // 约 1 秒后 sheet 收起,下次再进付费墙自然走已订阅状态卡。
            if entitlement.isPro && successEvent == nil {
                // 已订阅:不再出现购买选项 —— 展示订阅状态卡(方案/价格/续费状态)+ 管理订阅。
                // 价值主张/商品列表/购买 CTA 都只服务「未订阅 → 转化」,对已订阅者是噪音。
                // refresh() 仍无条件跑:isPro 若是 stale-true(订阅实际已过期),
                // refreshEntitlements 会翻回 false,本分支自动退回完整购买 UI。
                comparisonCard
                subscribedStatusCard
                if quotaUsage.proxyRejectedSubscription {
                    subscriptionRejectedHint
                }
                manageSubscriptionButton
                if entitlement.lastError != ErrorMessages.paywallProductsLoadFailed {
                    // 错误显式传播:恢复购买失败(离线时 AppStore.sync 抛错)必须可见。
                    // 只排除商品加载错误 —— 本分支不渲染商品,加载失败对已订阅者是噪音;
                    // loadProducts 失败时只赋 paywallProductsLoadFailed 这一个常量,
                    // 按值比较即按错误来源过滤(lastError 均来自 ErrorMessages 常量赋值)。
                    inlineErrorText
                }
                // 已订阅分支不渲染价格披露(legalText):那段是购买前的自动续费披露,
                // 价格取「当前选中方案」(默认年付),不是用户实际订阅的商品——月付用户
                // 会看到年付价格、已关续费的用户会看到 "auto-renews",都与状态卡矛盾
                // (外部 review 第 1 条)。隐私/条款链接与恢复购买保留。
                legalBlock(showsPriceDisclosure: false)
            } else {
                comparisonCard
                valuePropsList
                productList
                if entitlement.productLoadState == .success {
                    purchaseCTA
                    inlineErrorText
                }
                legalBlock(showsPriceDisclosure: true)
            }
            Spacer(minLength: WarmSpacing.xxs)
        }
        .task { await entitlement.refresh() }
        // initial: true —— 二次打开付费墙时商品早已加载、数组没变,普通 onChange 不触发,
        // 之前会导致没有任何卡片高亮(用户截图里的选中态 bug)。让首次出现也走默认选中逻辑。
        .onChange(of: entitlement.products, initial: true) { _, newProducts in
            // 购买飞行中不重置选中 —— refresh 可能由 transaction listener 触发,
            // 此时改 selectedProductID 会让用户感知到选中漂移。
            guard !entitlement.isPurchasing else { return }
            // 当前选中无效(首次加载/重试后商品变化/选中商品已不存在)时重置:
            // 默认年付,找不到则取第一个。products 已按价格升序排好。
            if selectedProductID == nil || !newProducts.contains(where: { $0.id == selectedProductID }) {
                selectedProductID = newProducts.first(where: { $0.id == Self.defaultProductID })?.id
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
    /// 「Pro 用户」同时看 entitlement 与 quotaUsage 两处:quotaUsage.isPro 是代理
    /// 验签后的 plan,可能滞后于 StoreKit 的 entitlement.isPro(刚订阅、代理响应未到);
    /// 只看前者时已订阅+当日零用量的用户会看到「免费 vs Pro」转化胶囊,
    /// 与已订阅状态卡自相矛盾 —— 任一处为 Pro 即走实时用量卡。
    @ViewBuilder
    private var comparisonCard: some View {
        if quotaUsage.loadState == .error {
            quotaErrorPill
        } else if successEvent != nil || quotaUsage.isPro || entitlement.isPro {
            // 成功窗口内一律走实时用量卡:刚买到手就让「已用 x/3 → x/100」的跳变
            // 立即可见(任务书条目 1.3)。这是本次会话的展示覆盖,不改 QuotaUsage——
            // 代理权威头到来后由 displayedLimit 正常接管。
            liveUsageCard
        } else if quotaUsage.used == 0 {
            freeVsProComparisonPill
        } else {
            liveUsageCard
        }
    }

    /// 单行对比胶囊:「🎙 语音录入:免费版 N 次/天 › Pro 版 M 次/天」。
    /// 原两列对比卡实高 ~96pt 撑破 SE 一屏预算,压成 ~44pt 单行,信息不变;
    /// 文案与图标沿用原两列卡(label + limit_per_day + chevron 分隔)。
    /// 2026-10-26(paywall-copy-v2):图标 ⚡→🎙,免费列前加「语音录入:」标签
    /// (voice_prefix 包住整列,标点随语言走,代码里不拼标点);一行 + 0.7 缩放
    /// 是硬约束,SE 三语实测若截断/难读按任务书 §2 降级为只留图标。
    private var freeVsProComparisonPill: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "mic.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WarmTheme.textSecondary)
                .accessibilityHidden(true)
            comparisonText(
                String(
                    format: String(localized: "paywall.comparison.voice_prefix %@"),
                    "\(String(localized: "paywall.comparison.free")) \(String(localized: "paywall.comparison.limit_per_day \(quotaUsage.limit)"))"
                ),
                color: WarmTheme.textPrimary
            )
            chevronDivider
            comparisonText(
                "\(String(localized: "paywall.comparison.pro")) \(String(localized: "paywall.comparison.limit_per_day \(NetworkConfig.proDailyLimit)"))",
                color: WarmTheme.primary
            )
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(WarmTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.chip))
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 胶囊内一列文本:单行,超宽整体缩放不截断。
    /// 调用方负责拼好整列文案(档位名 + 次/每天;免费列另含 voice_prefix 标签)。
    private func comparisonText(
        _ text: String,
        color: Color
    ) -> some View {
        Text(text)
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
                // 购买成功 x/3 → x/100 的跳变用数字滚动呈现(任务书条目 1.3)。
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: liveUsageText)
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
    /// 矛盾窗口期（刚订阅、代理响应未到）经 `displayedLimit` 过渡到 Pro 常量，
    /// 数字与「已订阅」状态卡不再自相矛盾 —— 上方 `comparisonCard` 分流容错
    /// （任一处为 Pro 即走实时用量卡）的另一半修复：只修「走哪张卡」不够，
    /// 卡里的数字也要跟着档位走。
    private var liveUsageText: String {
        let limit = successEvent != nil
            // 成功窗口内的展示覆盖:一律按 Pro 上限显示,让「买到了什么」立即可见
            // (任务书条目 1.3)。代理权威头到来后由 displayedLimit 正常接管。
            ? NetworkConfig.proDailyLimit
            : quotaUsage.displayedLimit(storeKitIsPro: entitlement.isPro)
        return String(
            format: String(localized: "quota.today_used"),
            quotaUsage.used,
            limit
        )
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

    // MARK: - Subscribed Status Card

    /// 已订阅状态卡:`isPro == true` 时替代价值主张 + 商品列表 + 购买 CTA。
    /// 已订阅用户进付费墙不该再看到购买选项(点了也只能从 StoreKit 系统弹窗得知
    /// 订阅已生效到几号),直接告知订阅状态:方案与价格、按续费状态区分的日期行。
    /// 到期时间来自 `Transaction.currentEntitlements` 的 `expirationDate`
    /// (自动续期开启时即下次续期日);理论上有订阅必有值,nil 时只降级不显示日期行。
    private var subscribedStatusCard: some View {
        VStack(spacing: WarmSpacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(WarmTheme.success)
                .accessibilityHidden(true)
            Text(subscribedTitleText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let plan = subscribedPlanText {
                // 方案行:「Pro 年付 · ¥39.99/年」。displayName/displayPrice 全取 StoreKit,
                // 商品未加载(activeProductID 对不上 products)时不显示该行。
                Text(plan)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            subscribedDateText
            pendingSwitchText
            if entitlement.willAutoRenew == false {
                // 到期后说明行(仅已关续费):Pro 只提升每日额度,如实只说额度变化,
                // 不列「失去的功能」——那是编造,且有 2.3 误导风险。数字取常量,不写死 3。
                Text(String(localized: "paywall.subscribed.after_expiry_free \(NetworkConfig.freeDailyLimit)"))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(WarmSpacing.md)
        .background(WarmTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.card))
        .padding(.horizontal, WarmSpacing.lg)
        // combine:整卡作为一个 a11y 元素(标题+方案+日期合并朗读),UI 测试按 id 定位。
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("PaywallSubscribedCard")
    }

    /// 选定商品(读不到 → nil):已订阅状态页的方案/价格展示元数据都从它来。
    private var subscribedProduct: Product? {
        guard let id = entitlement.activeProductID else { return nil }
        return entitlement.products.first(where: { $0.id == id })
    }

    /// 「¥39.99/年」价格段:displayPrice + 本地化周期单位(三语下 "/" 分隔一致,直接插值)。
    private var subscribedPricePeriodText: String? {
        guard let product = subscribedProduct else { return nil }
        return "\(product.displayPrice)/\(paywallPeriodUnit(for: product))"
    }

    /// 方案行文本:「Pro 年付 · ¥39.99/年」。
    private var subscribedPlanText: String? {
        guard let product = subscribedProduct,
              let pricePeriod = subscribedPricePeriodText else { return nil }
        return String(
            format: String(localized: "paywall.subscribed.plan %@ %@"),
            product.displayName,
            pricePeriod
        )
    }

    /// 状态卡标题:已关续费且 ≤7 天到期(黄色警告带)时改「Pro 有效期至 X」——
    /// 即将失去时还写「你已是 Pro」,与下方警示日期行语气矛盾(外部建议第 3 条)。
    /// 其余(续费中/未知/已关续费但 >7 天)保持「你已是 Pro」。days < 0(已过期
    /// stale-true)同样落入警告带,显示带日期版本。
    private var subscribedTitleText: String {
        if entitlement.willAutoRenew == false,
           let expiration = entitlement.subscriptionExpirationDate,
           Self.calendarDaysUntil(expiration, now: .now, calendar: .current) <= Self.nearExpiryWarningDayLimit {
            let dateText = expiration.formatted(date: .abbreviated, time: .omitted)
            return String(
                format: String(localized: "paywall.subscribed.title_until_expiry %@"),
                dateText
            )
        }
        return String(localized: "paywall.subscribed.title")
    }

    /// 待切换行(仅续费中且下次续期换方案):「将于 X 切换为 Pro 年付(¥298/年)」。
    /// 用户在系统订阅管理页选了「下次续期时切换」后,当前交易仍旧方案、
    /// renewalInfo.autoRenewPreference 指向新方案,不提示会让用户以为下次仍按旧价扣费
    /// (外部建议第 1 条)。X = 下次续期日(即 subscriptionExpirationDate);新方案
    /// 名与价格从 products 按 pendingRenewalProductID 查,查不到不显示(nil 不推断,
    /// 与方案行同口径)。
    @ViewBuilder
    private var pendingSwitchText: some View {
        if entitlement.willAutoRenew == true,
           let pendingID = entitlement.pendingRenewalProductID,
           pendingID != entitlement.activeProductID,
           let expiration = entitlement.subscriptionExpirationDate,
           let product = entitlement.products.first(where: { $0.id == pendingID }) {
            Text(String(
                format: String(localized: "paywall.subscribed.switching_plan %@ %@ %@"),
                expiration.formatted(date: .abbreviated, time: .omitted),
                product.displayName,
                "\(product.displayPrice)/\(paywallPeriodUnit(for: product))"
            ))
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundColor(WarmTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        }
    }

    /// 日期行,按续费状态区分(任务书条目 4.2):
    /// - 试用中且会续费 →「免费试用至 X，之后按 ¥39.99/年 收费」;
    ///   有待切换方案时退「下次续费 X」——价格让待切换行说,见 .some(true) 分支注释;
    /// - 已付费且会续费 →「下次续费 X」;
    /// - 已关闭自动续费 → 7 天内「今天/明天/X 天后到期」+ 警示色,其余「有效期至 X，到期后不再续费」;
    /// - willAutoRenew 读取不到(nil)→ 退回「有效期至 X」。
    /// 试用中但商品读不到(拼不出价格)时退「下次续费 X」,仍比裸日期多一层语义。
    @ViewBuilder
    private var subscribedDateText: some View {
        if let expiration = entitlement.subscriptionExpirationDate {
            let dateText = expiration.formatted(date: .abbreviated, time: .omitted)
            switch entitlement.willAutoRenew {
            case .some(true):
                // 有待切换方案时不走试用价格文案:「试用至 X 之后按 当前方案价 收费」
                // 与下方待切换行「将于 X 切换为新方案(新价)」对同一续期时点的价格陈述
                // 矛盾——实际按新方案价扣费。退「下次续费 X」,不替用户猜价格。
                let hasPendingPlanSwitch = entitlement.pendingRenewalProductID != nil
                if !hasPendingPlanSwitch, entitlement.isInIntroOffer, let pricePeriod = subscribedPricePeriodText {
                    Text(String(
                        format: String(localized: "paywall.subscribed.trial_renews %@ %@"),
                        dateText,
                        pricePeriod
                    ))
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(String(
                        format: String(localized: "paywall.subscribed.next_renewal %@"),
                        dateText
                    ))
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            case .some(false):
                subscribedNoRenewExpiryText(expiration: expiration, dateText: dateText)
            case .none:
                Text(String(localized: "paywall.subscribed.expires \(dateText)"))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// 已关续费的日期行:按剩余日历天分档。
    /// - <0(已过期)→「有效期至 X，到期后不再续费」+ `warningText`(日期已过还说
    ///   「今天到期」是错的,改显示具体日期);
    /// - 0(今天)/1(明天)/2…7 → 相对说法 + `warningText` 警示色;
    /// - >7 天 → 沿用「有效期至 X，到期后不再续费」+ `textSecondary`。
    /// 只在临期时提醒:真实用户取消年付后多数还有几个月有效期,全时段倒计时是焦虑噪音;
    /// 红色在本 App 语义是错误,不用。已过期的旧订阅理论上翻不进 isPro 分支(refresh
    /// 会翻回 false),本分支只为 stale-true 的短暂窗口兜底。
    /// - Parameter dateText: 调用方(`subscribedDateText`)已格式化好的日期串,
    ///   >7 天与已过期段直接复用,与其它日期行保持同一格式来源。
    private func subscribedNoRenewExpiryText(expiration: Date, dateText: String) -> some View {
        let days = Self.calendarDaysUntil(expiration, now: .now, calendar: .current)
        let text: String
        let color: Color
        switch days {
        case ..<0:
            // 已过期(isPro stale-true 的短暂窗口):显示具体日期,不说「今天到期」。
            text = String(
                format: String(localized: "paywall.subscribed.expires_no_renew %@"),
                dateText
            )
            color = WarmTheme.warningText
        case 0:
            text = String(localized: "paywall.subscribed.expires_today_no_renew")
            color = WarmTheme.warningText
        case 1:
            text = String(localized: "paywall.subscribed.expires_tomorrow_no_renew")
            color = WarmTheme.warningText
        case 2...Self.nearExpiryWarningDayLimit:
            text = String(localized: "paywall.subscribed.expires_in_days_no_renew \(days)")
            color = WarmTheme.warningText
        default:
            text = String(
                format: String(localized: "paywall.subscribed.expires_no_renew %@"),
                dateText
            )
            color = WarmTheme.textSecondary
        }
        return Text(text)
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundColor(color)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    /// 到期日距今的日历天数(今天 = 0,已过 = 负数)。
    /// 按 `startOfDay` 差算,不用秒数除 86400——夏令时切换日实际只有 23/25 小时,
    /// 秒数除法会差一天。`now`/`calendar` 注入,便于单测跨天/跨月/跨夏令时。
    static func calendarDaysUntil(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// 已关续费的「临期警告带」天数上限(0...此值 → 相对说法/具体日期 + 警示色,
    /// 标题也换「Pro 有效期至 X」;超过则维持原色与「你已是 Pro」)。
    /// 标题(subscribedTitleText)与日期行(subscribedNoRenewExpiryText)共用,
    /// 两带必须同宽,否则标题警示而日期行不警示(或反之)。
    static let nearExpiryWarningDayLimit = 7

    /// 「管理订阅」主按钮:打开系统订阅管理页(切换月/年、取消续费都在这里)。
    /// 已关续费时文案改「重新开启自动续费」——按钮如实描述点下去会发生什么:
    /// 用户在系统页做的是重新打开自动续费,不是重新购买;此时 Pro 仍有效,
    /// 「Resume Pro」类文案暗示 Pro 已停,与状态卡矛盾(外部 review 第 4 条)。
    /// 关闭后重读权益——用户可能刚取消续费或换了方案,日期行要跟着变(任务书条目 4.4);
    /// 重新开启续费后 willAutoRenew 翻回 true,按钮/日期行/说明行随之恢复。
    /// iOS 26 SDK 的 manageSubscriptionsSheet(isPresented:) 已无 onDismiss 参数,
    /// 用自定义 Binding 在置回 false 时触发刷新,语义等价。
    private var manageSubscriptionButton: some View {
        Button {
            showManageSubscriptions = true
        } label: {
            Text(String(localized: manageSubscriptionLabelKey))
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
        .accessibilityIdentifier("PaywallManageSubscriptionButton")
        .padding(.horizontal, WarmSpacing.lg)
        .manageSubscriptionsSheet(isPresented: Binding(
            get: { showManageSubscriptions },
            set: { showing in
                showManageSubscriptions = showing
                if !showing {
                    Task { await entitlement.refreshEntitlements() }
                }
            }
        ))
    }

    /// 主按钮文案:已关续费(willAutoRenew == false)→「重新开启自动续费」;
    /// 续费中/未知(nil)→「管理订阅」。nil 不推断,按现状处理。
    private var manageSubscriptionLabelKey: String.LocalizationValue {
        entitlement.willAutoRenew == false
            ? "paywall.manage_subscription.turn_on_renew"
            : "paywall.manage_subscription"
    }

    /// 订阅被代理拒的警示行(`QuotaUsage.proxyRejectedSubscription`:请求带了凭证、
    /// 代理仍按 free 档计——验签失败/计费宽限期/已退款)。此时 StoreKit 说已订阅、
    /// 实际只剩免费额度,状态页若只说「你已是 Pro」,用户会以为一切正常,直到撞上
    /// 免费额度才从 toast 得知。给出原因与出口——「恢复购买」按钮就在下方法务块。
    /// 代理重新按 Pro 计(下次请求的响应头)后本行自动消失。
    /// 首页额度胶囊同状态改警示样式,与这里互为呼应。
    private var subscriptionRejectedHint: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WarmTheme.warning)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.subscribed.rejected_hint"))
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.warning)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .padding(.horizontal, WarmSpacing.lg)
        .accessibilityIdentifier("PaywallSubscriptionRejectedHint")
    }

    // MARK: - Value Props

    /// 价值主张:quota 卡已删(一屏化去重 —— 额度信息由对比胶囊表达);
    /// trial 卡在 intro offer 资格查询完成且 isEligibleForIntroOffer 为 true 时才渲染 (C 点防抖);
    /// capture 卡(核心价值主张)总是显示。两卡均为 PaywallCopyCard 纯文字居中形态
    /// (2026-10-26 产品拍板:去 emoji 圆 + 居中,与整页中轴对称节奏一致;不再复用
    /// ValuePropCard,onboarding 欢迎页保持原形态)。试用卡文案仍复用
    /// `onboarding.pro.bullet.trial.*`,capture 卡用新 key `paywall.value.capture.*`。
    private var valuePropsList: some View {
        VStack(spacing: WarmSpacing.sm) {
            // 查询期间不渲染试用卡,避免查完前后「无试用 ↔ 有试用」抖动 (C 点)。
            // 试用时长从 StoreKit 的 introOfferPeriod 插值(与 CTA/法务行/商品卡同口径,
            // 不手写「7 天」)。
            if !entitlement.isCheckingIntroOffer && entitlement.isEligibleForIntroOffer,
               let trialPeriod = entitlement.introOfferPeriod {
                PaywallCopyCard(
                    title: String(localized: "onboarding.pro.bullet.trial.title \(trialPeriod.formattedLocalizedPeriod())"),
                    description: String(localized: "onboarding.pro.bullet.trial.desc")
                )
            }
            PaywallCopyCard(
                title: String(localized: "paywall.value.capture.title"),
                description: String(localized: "paywall.value.capture.desc")
            )
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    // MARK: - PaywallCopyCard(付费页专用价值主张卡)

    /// 付费页价值主张卡:纯文字、整体居中,无 emoji 圆。
    ///
    /// 2026-10-26(paywall-copy-v2)产品拍板:试用卡与核心卡放弃 ValuePropCard 的
    /// 「emoji 圆 + 左对齐」形态 —— 两卡文字块高度不一,emoji 圆垂直居中后彼此错位,
    /// 且左对齐与付费页整体的中轴对称节奏(对比条/CTA/法务说明均居中)不一致。
    /// `ValuePropCard` 本体不动,onboarding 欢迎页继续用原形态。
    /// 容器视觉参数(padding/圆角/阴影/描边)沿用 ValuePropCard compact 规格,卡片质感不变。
    private struct PaywallCopyCard: View {
        let title: String
        let description: String

        var body: some View {
            VStack(spacing: WarmSpacing.xxs) {
                Text(title)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                // 不限制行数:卡片在 ScrollView 中可纵向自由扩展,
                // 避免 zh-Hans / ja 等长文本下出现「...」截断(项目零容忍规则)。
                Text(description)
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.sketch)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(WarmSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.sketch.opacity(0.08), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .stroke(WarmTheme.sketch.opacity(0.15), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
        }
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
                // 视图层排序:默认方案(年付)置顶,其余维持 manager 的价格升序。
                // 不改 entitlement.products 本身的顺序 —— checkIntroOffer 等
                // 逻辑依赖 manager 侧的稳定序。
                ForEach(displayOrderedProducts, id: \.id) { product in
                    ProductCard(
                        product: product,
                        isSelected: product.id == selectedProductID,
                        // 成功窗口内同样弱化禁用,防止约 1 秒的展示期内再选方案
                        // (沿用购买中的弱化样式,任务书条目 1.2)。
                        isPurchasing: entitlement.isPurchasing || successEvent != nil,
                        showsTrialIncluded: entitlement.isEligibleForIntroOffer,
                        action: { selectedProductID = product.id }
                    )
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
        }
    }

    /// 商品展示序:默认方案(年付)在前,其余按 manager 的价格升序。
    /// 只影响渲染顺序,不动 `entitlement.products`。
    private var displayOrderedProducts: [Product] {
        guard let preferred = entitlement.products.first(where: { $0.id == Self.defaultProductID }) else {
            return entitlement.products
        }
        return [preferred] + entitlement.products.filter { $0.id != Self.defaultProductID }
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
        Group {
            if let successEvent {
                successCTA(successEvent)
            } else {
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
        }
        // 任务书条目 1.2:CTA ↔ 成功态的切换要 0.25s 过渡。动画必须挂在包含
        // if/else 的父层——挂在 successCTA 自身时,该视图出现首帧 value 已是
        // 新值、没有变化事件,插入/移除过渡不会播(切换会直接跳变)。
        .animation(.easeOut(duration: 0.25), value: successEvent)
    }

    /// 成功态 CTA:原地变绿(WarmTheme.success 底 + checkmark + 「已升级为 Pro / 已恢复 Pro」)。
    /// 反馈出现在用户刚点的按钮上,视线不用挪(任务书条目 1.2)。
    /// disabled 语义保留(成功窗口内不可再购买),但用 UndimmedButtonStyle 绕开系统
    /// 对 disabled 按钮的降透明度——成功态必须醒目。
    private func successCTA(_ event: PaywallView.SuccessEvent) -> some View {
        Button {} label: {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
                Text(event.message)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(WarmTheme.success)
                    .shadow(color: WarmTheme.success.opacity(0.3), radius: 8, y: 4)
            )
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(true)
        .accessibilityIdentifier("PaywallPurchaseButton")
        // UI 测试以 value == "success" 判断成功态(S20 Step 6)。
        .accessibilityValue("success")
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 购买/恢复失败的显式反馈(错误显式传播):`.success` 态下 `lastError` 此前无处渲染,
    /// 购买失败、验签失败(unverified)、恢复无可恢复项都会静默无反馈。
    /// 「等待批准」(paywallPending)与「订阅状态已是最新」(paywallRestoreUpToDate)是
    /// 中性提示,不走警示色——前者显示成错误会让用户以为交易出了问题,后者本来就不是
    /// 失败(已订阅用户点恢复的对账结论)。purchase/restore 开始时会清 lastError,
    /// 双 isPurchasing/isRestoring 守卫只是兜底防飞行中显示陈旧错误。
    @ViewBuilder
    private var inlineErrorText: some View {
        if !entitlement.isPurchasing, !entitlement.isRestoring, let error = entitlement.lastError {
            if error == ErrorMessages.paywallPending {
                neutralInlineInfo(icon: "clock", text: error)
            } else if error == ErrorMessages.paywallRestoreUpToDate {
                neutralInlineInfo(icon: "checkmark", text: error)
            } else {
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
    }

    /// 行内中性提示(灰):图标 + 文案,不占警示色。paywallPending / paywallRestoreUpToDate 共用。
    private func neutralInlineInfo(icon: String, text: String) -> some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WarmTheme.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .padding(.horizontal, WarmSpacing.lg)
        .accessibilityIdentifier("PaywallInlineError")
    }

    /// CTA 是否显示 spinner:资格查询中 或 购买中。
    private var showsCTASpinner: Bool {
        entitlement.isCheckingIntroOffer || entitlement.isPurchasing
    }

    private var ctaDisabled: Bool {
        // 恢复购买进行中也禁用:AppStore.sync 与购买并发会让两边的 lastError/isPro 结果互相覆盖。
        showsCTASpinner || entitlement.isRestoring || currentSelectedProduct == nil
    }

    private var currentSelectedProduct: Product? {
        if let id = selectedProductID,
           let product = entitlement.products.first(where: { $0.id == id }) {
            return product
        }
        // fallback: 默认年付,找不到则取排序后第一个
        return entitlement.products.first(where: { $0.id == Self.defaultProductID })
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

    /// 法务块(自动续费说明 + 隐私·条款链接 + 独立开发者小字 + 恢复购买),间距压到
    /// xxs 换取一屏预算。legalText 仍只在商品加载成功且 intro 资格查询落定后渲染
    /// (C 点防抖,依赖 isEligibleForIntroOffer 分流);链接与恢复不依赖商品加载结果
    /// (3.1.2:商品加载失败时付费墙仍可见,链接也必须可点)。
    /// `showsPriceDisclosure == false`(已订阅分支)时只留链接、小字与恢复——价格披露
    /// 服务购买决策,对已订阅者是错误信息(见 body 已订阅分支注释)。
    private func legalBlock(showsPriceDisclosure: Bool) -> some View {
        VStack(spacing: WarmSpacing.xxs) {
            if showsPriceDisclosure && entitlement.productLoadState == .success && !entitlement.isCheckingIntroOffer {
                legalText
            }
            legalLinks
            indieFooter
            restoreButton
        }
    }

    /// 独立开发者致谢小字(2026-10-26 paywall-copy-v2 新增,原 🌱 卡的职能移到这里)。
    /// 放在链接与「恢复购买」之间;legalBlock 在已订阅分支同样调用,
    /// 已订阅用户看到「感谢你的支持」更贴切(任务书 §4,有意为之)。
    /// 样式与 legalText 同规格(11pt rounded / textMuted / 居中),不做成卡片。
    private var indieFooter: some View {
        Text(String(localized: "paywall.footer.indie"))
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundColor(WarmTheme.textMuted)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, WarmSpacing.lg)
    }

    /// App Store 审核要求的自动续费合规说明(价格随选中方案即时更新):
    /// 第一行价格条款(试用资格决定文案),第二行取消路径。
    /// 价格/周期一律取当前选中商品的 StoreKit 数据,不手写 ¥39.99 / 7 天——
    /// 各店面币种价格不同,试用时长以 introductoryOffer.period 为准。
    private var legalText: some View {
        VStack(spacing: WarmSpacing.xxs) {
            Text(legalPriceLine)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textMuted)
                .multilineTextAlignment(.center)
                // 合规文案不可截断:en 长文案 AX 大字号下需 3 行,
                // lineLimit(2)+0.85 缩放兜不住会出 "..."(审核风险),保持 3 行预算。
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            Text(String(localized: "paywall.legal.cancel_path"))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(WarmTheme.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, WarmSpacing.lg)
    }

    /// 价格条款行:有试用资格 →「试用 N 天后按 ¥xx/年 自动续费，可随时取消」;
    /// 无资格 →「¥xx/年，自动续费，可随时取消」。切换选中方案时随 body 即时更新。
    private var legalPriceLine: String {
        // legalBlock 只在 productLoadState == .success 时渲染 legalText,
        // 这里取不到选中商品属于防御性兜底,给空串防呆。
        guard let product = currentSelectedProduct else { return "" }
        let periodUnit = paywallPeriodUnit(for: product)
        if entitlement.isEligibleForIntroOffer, let period = entitlement.introOfferPeriod {
            return String(
                format: String(localized: "paywall.legal.trial_then_price"),
                period.formattedLocalizedPeriod(),
                product.displayPrice,
                periodUnit
            )
        }
        return String(
            format: String(localized: "paywall.legal.price_autorenew"),
            product.displayPrice,
            periodUnit
        )
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

// MARK: - 计费周期单位

/// 商品的本地化计费周期单位(「年」/「月」)。年付=年,其余(月付)=月。
/// 价格条款行(legalPriceLine)与商品卡(ProductCard)共用同一口径。
/// @MainActor:引用 EntitlementManager.yearlyProductID(@MainActor 隔离的常量)。
@MainActor
private func paywallPeriodUnit(for product: Product) -> String {
    product.id == EntitlementManager.yearlyProductID
        ? String(localized: "paywall.period.year")
        : String(localized: "paywall.period.month")
}

// MARK: - 不降透明度的按钮样式

/// 只透传 label 的按钮样式。系统 ButtonStyle 在 disabled 时会给内容降透明度,
/// 成功态 CTA 需要保持醒目(任务书条目 1.2),禁用语义交给 Button.disabled。
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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

    /// 年付折合月价(「约 ¥3.33/月」):`price / 12` 用 StoreKit 的 `priceFormatStyle`
    /// 格式化,币种/小数位跟随店面,不手写价格。月付不显示。
    private var monthlyEquivalentPrice: String? {
        guard isYearly else { return nil }
        return product.priceFormatStyle.format(product.price / 12)
    }

    private var periodUnit: String {
        paywallPeriodUnit(for: product)
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
                    // 试用时长从该商品自身的 introductoryOffer 取(与 CTA/法务行同口径),
                    // 不手写「7 天」—— ASC 后台改试用时长时这里自动跟随。
                    if showsTrialIncluded, let offer = product.subscription?.introductoryOffer {
                        Text(String(localized: "paywall.card.trial_included \(offer.period.formattedLocalizedPeriod())"))
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
                    if let perMonth = monthlyEquivalentPrice {
                        // 年付折合月价:让「省 33%」的直觉落到每月花销上。
                        Text(String(localized: "paywall.yearly_per_month \(perMonth)"))
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundColor(WarmTheme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
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
