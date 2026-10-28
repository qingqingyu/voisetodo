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

/// 订阅页 Paywall (sheet 形态)。2026-10-28 v3 改版:自绘页头(去 NavigationStack)、
/// 中间滚动(额度条/大标题/权益卡)+ 底部购买区固定(safeAreaInset),小屏不用滚动
/// 即可见方案卡与购买按钮。
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

    var body: some View {
        VStack(spacing: 0) {
            headerView
            PaywallContent(successEvent: successEvent)
        }
        .background(WarmTheme.background.ignoresSafeArea())
        // 成功反馈画在 CTA 本身上(原地变绿):用户视线不用挪,顶部额度胶囊同时升到
        // Pro 档,「买到了什么」一眼可见。约 1 秒后收起;toast 由 AppCoordinator 在 sheet
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

    /// 自绘页头(v3):标题左对齐 + 圆形关闭按钮。替代原 NavigationStack 导航栏——
    /// 底部购买区固定后,页头也不随中间内容滚动。
    private var headerView: some View {
        HStack(spacing: WarmSpacing.md) {
            Text(String(localized: headerTitleKey))
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("PaywallHeaderTitle")
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(WarmTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(WarmTheme.cardBackground)
                            .shadow(color: WarmTheme.shadowLight, radius: 3, y: 1)
                    )
            }
            .accessibilityLabel(String(localized: "paywall.close"))
        }
        // v3 设计稿:页面左右边距 24pt。
        .padding(.horizontal, 24)
        .padding(.vertical, WarmSpacing.sm)
    }

    /// 页头标题文案:已订阅(且非成功窗口)用「VoiceTodo Pro」,否则沿用「升级」。
    /// 条件必须与 `PaywallContent` 的已订阅分支一致——成功窗口内页面仍停在购买 UI,
    /// 标题也要留在「升级」,不得闪成已订阅页。
    private var headerTitleKey: String.LocalizationValue {
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

/// 付费墙主体内容(仅 sheet 形态)。
///
/// v3 结构(未订阅):中间滚动(额度条 → 大标题 → 权益卡)+ 底部购买区固定
/// (方案卡 → 购买按钮 → 错误提示 → 续费说明 → 链接行 → 小字)。内容自然高度
/// 超一屏(中文 792pt),SE 视口只有 ~600pt——购买区任何机型不滚动可见是硬要求,
/// 中间区可滚。已订阅分支沿用原内容,放进滚动区,底部只换链接行 + 小字。
struct PaywallContent: View {
    @EnvironmentObject private var entitlement: EntitlementManager
    @EnvironmentObject private var quotaUsage: QuotaUsage

    /// 购买/恢复成功事件(来自 PaywallView)。非 nil 时:
    /// - 未订阅分支保持渲染(CTA 原地变绿而不是整页切走,反馈出现在用户刚点的按钮上);
    /// - 顶部额度胶囊升到 Pro 档上限(NetworkConfig.proDailyLimit);
    /// - 方案卡弱化禁用,防止成功窗口内再选方案。
    let successEvent: PaywallView.SuccessEvent?

    /// 默认选中的商品 ID(产品建议推年付,不是硬要求——以后想改推月付改这一行即可)。
    /// 只在「当前没有有效选中」时生效;用户手动选过的方案不会被覆盖。
    static let defaultProductID = EntitlementManager.yearlyProductID

    /// 当前选中的商品 ID。productList 加载后默认选年付;找不到则取排序后的第一个。
    /// 购买期间用户仍可点其它卡片切换 —— A 点已要求此时所有卡 disabled,实际不会改值。
    @State private var selectedProductID: String?
    /// 系统订阅管理页(.manageSubscriptionsSheet)是否展示。关闭后重读权益。
    @State private var showManageSubscriptions = false

    /// 中间滚动区视口高度。初值 .infinity 表示「尚未测得」,拿到真值前不参与
    /// contentFits 判定。挂在 ScrollView 自身测,高度由容器决定、与内容无关,
    /// 不会形成布局反馈环。v3 语义:测**中间滚动区**(不含底部固定购买区)。
    @State private var viewportHeight: CGFloat = .infinity
    /// 中间滚动区全部内容的自然高。
    @State private var contentHeight: CGFloat = 0

    /// 中间滚动区是否一屏装下(不滚动)。DEBUG 下经隐藏元素暴露给 UI 测试记录(S18)。
    /// v3 起整页允许滚动(购买区固定),本值只记录中间区状态,不再作断言口径。
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
    /// state 附带商品加载态,异常时可判断卡在哪个分支。
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

    /// DEBUG UI 测试钩子(照 OnboardingView 的 OnboardingContentFits 范式):
    /// overlay 里的元素进不了 XCUI a11y 树,只能放回流内;0×0 会被剪掉,
    /// 给 1×1 占位,其高度已计入 contentFits 的 DEBUG +1。放中间滚动内容末尾。
    #if DEBUG
    private var contentFitsHook: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("PaywallContentFits")
            .accessibilityValue(contentFitsRawValue)
    }
    #endif

    var body: some View {
        // 成功窗口内不切已订阅分支:反馈要落在用户刚点的那颗 CTA 上(变绿),
        // 整页切换会把按钮、方案列表一并抽走,「页面突然变了」反而像出错。
        // 约 1 秒后 sheet 收起,下次再进付费墙自然走已订阅状态卡。
        if entitlement.isPro && successEvent == nil {
            subscribedBody
        } else {
            purchaseBody
        }
    }

    // MARK: - 未订阅主体(v3)

    private var purchaseBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                quotaBadge
                    // v3 设计稿:额度条在页头下方 20pt。
                    .padding(.top, WarmSpacing.lg)
                heroTitle
                    // v3 设计稿:大标题上方 28pt。
                    .padding(.top, 28)
                benefitsCard
                    // v3 设计稿:权益卡上方 24pt。
                    .padding(.top, 24)
                    .padding(.bottom, WarmSpacing.md)

                #if DEBUG
                contentFitsHook
                #endif
            }
            // v3 设计稿:页面左右边距 24pt。
            .padding(.horizontal, 24)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, newHeight in
                contentHeight = newHeight
            }
        }
        .scrollIndicators(.hidden)
        .background(WarmTheme.background.ignoresSafeArea())
        // 测**可见**滚动视口(§7「中间滚动区」口径):ScrollView 全帧含被
        // safeAreaInset 购买区遮挡的部分,须减去其注入的底部 safe area
        // (购买区高度 + 设备底部安全区),否则 viewport 虚高、fits 假阳性。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height - proxy.safeAreaInsets.bottom
        } action: { _, newHeight in
            viewportHeight = newHeight
        }
        // 底部购买区固定(v3):任何机型不滚动即可见方案卡与购买按钮。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseSection
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

    // MARK: - 额度条(v3 §5.2 状态机)

    /// 额度条:按用量状态分流。设计稿只画了「用完」一种,这里补齐全部状态。
    /// 免费 0 用量不显示——权益卡里已写「免费版每天 3 次」,重复是噪音。
    @ViewBuilder
    private var quotaBadge: some View {
        if quotaUsage.loadState == .error {
            quotaErrorBadge
        } else if successEvent != nil || quotaUsage.isPro || entitlement.isPro {
            // 成功窗口/Pro:实时用量(购买成功 x/3 → x/100 的跳变立即可见)。
            liveUsageBadge
        } else if quotaUsage.used > 0 {
            freeUsageBadge(isExhausted: quotaUsage.used >= quotaUsage.limit)
        }
    }

    /// 额度条胶囊外壳:v3 统一样式(底色 cardBackground、内边距 上下 8/左右 14、间距 8)。
    private func quotaBadgeShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(WarmTheme.cardBackground))
        .accessibilityElement(children: .combine)
    }

    /// 免费用量态:「今日免费次数已用(完)」+ 加粗「n/m」。
    private func freeUsageBadge(isExhausted: Bool) -> some View {
        quotaBadgeShell {
            Image(systemName: "bolt")
                .font(.system(size: 16))
                .foregroundColor(WarmTheme.primaryText)
                .accessibilityHidden(true)
            Text(String(localized: isExhausted ? "paywall.quota.exhausted" : "paywall.quota.used"))
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Text(verbatim: "\(quotaUsage.used)/\(quotaUsage.limit)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // 与 liveUsageBadge 同口径(§5.2):非权威数据跟「（估算）」小字,
            // 离线估算的 n/m 不冒充权威计数。
            if !quotaUsage.isAuthoritative {
                estimateNote
            }
        }
    }

    /// 实时用量态(Pro/成功窗口):沿用 quota.today_used 与数字滚动动画。
    private var liveUsageBadge: some View {
        quotaBadgeShell {
            Image(systemName: "bolt")
                .font(.system(size: 16))
                .foregroundColor(WarmTheme.primaryText)
                .accessibilityHidden(true)
            Text(liveUsageText)
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                // 购买成功 x/3 → x/100 的跳变用数字滚动呈现。
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: liveUsageText)
            if !quotaUsage.isAuthoritative {
                estimateNote
            }
        }
    }

    /// 「（估算）」小字:非权威配额数据的标注,免费/实时两态共用(§5.2)。
    private var estimateNote: some View {
        Text(String(localized: "quota.non_authoritative"))
            .font(.system(size: 12))
            .foregroundColor(WarmTheme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// 额度读取失败态:沿用 v2 quotaErrorPill 的内容(警告图标 + quota.error),套新胶囊样式。
    private var quotaErrorBadge: some View {
        quotaBadgeShell {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.warning)
                .accessibilityHidden(true)
            Text(String(localized: "quota.error"))
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    /// Pro 档也是有限额度，与免费档同样显示「已用 used/limit」。
    /// `limit` 由代理 `X-Quota-Limit` 提供（Pro 时为 `PAID_DAILY_LIMIT`）。
    /// 矛盾窗口期（刚订阅、代理响应未到）经 `displayedLimit` 过渡到 Pro 常量。
    private var liveUsageText: String {
        let limit = successEvent != nil
            // 成功窗口内的展示覆盖:一律按 Pro 上限显示,让「买到了什么」立即可见。
            // 代理权威头到来后由 displayedLimit 正常接管。
            ? NetworkConfig.proDailyLimit
            : quotaUsage.displayedLimit(storeKitIsPro: entitlement.isPro)
        return String(
            format: String(localized: "quota.today_used"),
            quotaUsage.used,
            limit
        )
    }

    // MARK: - 大标题(v3)

    /// 大标题:30pt heavy 两行,按文案 key 里的换行断行。零容忍不截断——
    /// 不设行数上限 + fixedSize 让两行完整显示。
    private var heroTitle: some View {
        Text(String(localized: "paywall.hero.title"))
            .font(.system(size: 30, weight: .heavy))
            .tracking(heroTracking)
            .lineSpacing(4)
            .foregroundColor(WarmTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// 设计稿字距:英文 -0.5,其余(zh/ja)-0.3。语言判定跟随 **App 实际渲染所用
    /// 的本地化**(`Bundle.main.preferredLocalizations`,与 `String(localized:)`
    /// 同源,同 `ReviewFlowVisuals.usesCJKTraits` 口径)——不是系统语言设置:
    /// 系统语言不在 zh/en/ja 内时界面回落英文渲染,若按 `Locale.current` 判
    /// 会给英文文字错配 -0.3。
    private var heroTracking: CGFloat {
        Bundle.main.preferredLocalizations.first == "en" ? -0.5 : -0.3
    }

    // MARK: - 权益卡(v3)

    /// 权益卡:标题组(「升级 Pro,每天 100 次都能这样用」+「免费版每天 3 次」)
    /// + 两行权益(语音录入 / 日期理解)。次数取常量不写死(§5.3):
    /// Pro 上限用 `NetworkConfig.proDailyLimit`;免费上限用 `NetworkConfig.freeDailyLimit`
    /// 而不是 `quotaUsage.limit`——成功窗口内它会变成 Pro 上限,副标题会错成「免费版每天 100 次」。
    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(benefitsHeading)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "paywall.benefits.free_note \(NetworkConfig.freeDailyLimit)"))
                    .font(.system(size: 13))
                    .foregroundColor(WarmTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                benefitRow(icon: "mic", text: String(localized: "paywall.benefits.voice"))
                benefitRow(icon: "calendar", text: String(localized: "paywall.benefits.dates"))
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
    }

    /// 权益行:32×32 图标块(浅橙底)+ 15pt 文字。图标不朗读。
    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(WarmTheme.primaryText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WarmTheme.primaryTint)
                )
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(WarmTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
    }

    /// 权益卡标题:「100 次」段上色。整句经 heading key 本地化后再用
    /// AttributedString 定位 count 子串改色——不在代码里拼语序(日文语序不同)。
    /// 找不到子串(理论上不该发生)保持不上色,不让布局失败。
    private var benefitsHeading: AttributedString {
        let countText = String(localized: "paywall.benefits.count \(NetworkConfig.proDailyLimit)")
        let heading = String(
            format: String(localized: "paywall.benefits.heading %@"),
            countText
        )
        var attributed = AttributedString(heading)
        if let swiftRange = heading.range(of: countText),
           let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
           let upper = AttributedString.Index(swiftRange.upperBound, within: attributed) {
            attributed[lower..<upper].foregroundColor = WarmTheme.primaryText
        }
        return attributed
    }

    // MARK: - 底部购买区(v3 固定)

    /// 底部购买区:方案卡(或加载占位/错误态)→ 购买按钮 → 错误提示 → 续费说明
    /// → 链接行 → 小字。背景铺页面底色,滚动内容不从底下透出;底部 12pt + 系统
    /// 安全区(设计稿画布内的 28pt 留白已由安全区取代)。
    private var purchaseSection: some View {
        VStack(spacing: 0) {
            switch entitlement.productLoadState {
            case .loading:
                loadingPlansPlaceholder
            case .empty:
                // StoreKit 返回空数组时静默无原因(模拟器 storekitd 抽风 / 商品未上架 / 真断网 都走这里)。
                // 用当前网络状态间接归因:无网 → 提示网络(归因正确);
                // 有网但空 → 中性"无法连接 App Store",不误导用户去查一个没坏的网络。
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
                planList
                purchaseCTA
                    // v3 设计稿:方案卡下 16pt。
                    .padding(.top, WarmSpacing.md)
                inlineErrorText
                renewalNotice
            }

            // 链接行与小字不依赖商品加载结果(3.1.2:商品加载失败时链接也必须可点)。
            footerLinksContent
        }
        .padding(.horizontal, 24)
        // v3 设计稿:购买区顶部 16pt 呼吸;底部 12pt + 系统安全区。
        .padding(.top, WarmSpacing.md)
        .padding(.bottom, 12)
        .background(WarmTheme.background)
    }

    /// 方案卡列表(v3 §5.1):年度在上默认选中(沿用 defaultProductID 与 displayOrderedProducts)。
    @ViewBuilder
    private var planList: some View {
        VStack(spacing: WarmSpacing.sm) {
            ForEach(displayOrderedProducts, id: \.id) { product in
                PlanCard(
                    product: product,
                    isSelected: product.id == selectedProductID,
                    // 成功窗口内同样弱化禁用,防止约 1 秒的展示期内再选方案(沿用购买中的弱化)。
                    isDisabled: entitlement.isPurchasing || successEvent != nil,
                    saveBadgeText: product.id == Self.defaultProductID ? yearlySaveBadgeText : nil,
                    action: { selectedProductID = product.id }
                )
            }
        }
    }

    /// 商品展示序:默认方案(年付)在前,其余按 manager 的价格升序。
    /// 只影响渲染顺序,不动 `entitlement.products`。
    private var displayOrderedProducts: [Product] {
        guard let preferred = entitlement.products.first(where: { $0.id == Self.defaultProductID }) else {
            return entitlement.products
        }
        return [preferred] + entitlement.products.filter { $0.id != preferred.id }
    }

    /// 「省 X%」角标文字(v3 §5.1):1 − 年付价 ÷(月付价 × 12),Decimal 计算,
    /// × 100 后**向下取整**——人民币 34.6% 显示「省 34%」、美区 33.2% 显示「省 33%」,
    /// 四舍五入成 35% 是夸大(设计稿的 35% 不照抄)。找不到月付商品或结果 ≤ 0 →
    /// 不显示角标。
    private var yearlySaveBadgeText: String? {
        guard let yearly = entitlement.products.first(where: { $0.id == Self.defaultProductID }),
              let monthly = entitlement.products.first(where: { $0.id == EntitlementManager.monthlyProductID })
        else { return nil }
        // Decimal 全程显式类型:整数字面量与 Decimal 混算会推断成浮点,精度口径漂移。
        let monthlyAnnualTotal = monthly.price * Decimal(12)
        guard monthlyAnnualTotal > Decimal(0) else { return nil }
        let saveFraction = Decimal(1) - yearly.price / monthlyAnnualTotal
        guard saveFraction > Decimal(0) else { return nil }
        // × 100 向下取整成整数(34.6 → 34):NSDecimalNumber.intValue 向零截断,
        // 正数即向下取整;再用整数的 .percent 样式格式化(「34%」,随语言)。
        let percentInt = ((saveFraction * Decimal(100)) as NSDecimalNumber).intValue
        let formatted = percentInt.formatted(.percent)
        return String(localized: "paywall.plan.save \(formatted)")
    }

    /// 商品加载占位(v3 §5.5):高度约等于两张方案卡,中间转圈,避免加载完页面跳动。
    private var loadingPlansPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(WarmTheme.cardBackground)
            .frame(height: 170)
            .overlay(ProgressView().tint(WarmTheme.primaryText))
    }

    /// `.empty` 态副文案:有网但商品空 → 中性"无法连接 App Store";无网 → 提示检查网络。
    /// StoreKit 空数组不携带失败原因,只能用当前网络状态间接归因(见 purchaseSection `.empty` 注释)。
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(WarmTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retryAction) {
                HStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "paywall.products_empty.retry"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(WarmTheme.primaryText)
                .padding(.horizontal, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    Capsule()
                        .stroke(WarmTheme.primaryText, lineWidth: 1.5)
                )
            }
            .disabled(entitlement.productLoadState == .loading)
            .accessibilityIdentifier("PaywallRetryButton")
        }
        .frame(maxWidth: .infinity)
        .padding(WarmSpacing.lg)
        .background(WarmTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Purchase CTA

    /// 主 CTA:点下去直接调 `entitlement.purchase(product)` —— Apple 系统购买弹窗随后弹出。
    /// 行为(沿用):
    /// - `isCheckingIntroOffer == true` → spinner 不显文案,避免资格查询前后文案抖动 (C 点)
    /// - `isPurchasing == true` → spinner + disabled,方案卡同步弱化 (A 点)
    /// - 成功窗口 → 原地变绿(见 successCTA)
    /// v3 样式:56pt 高胶囊、ctaFill 深橙(白字对比度 ~3.8:1)、19pt bold 白字。
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
                    Group {
                        if showsCTASpinner {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(ctaTitle)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
                    .background(
                        Capsule()
                            .fill(WarmTheme.ctaFill)
                            .shadow(color: WarmTheme.ctaFill.opacity(0.28), radius: 18, y: 6)
                    )
                }
                .disabled(ctaDisabled)
                .accessibilityIdentifier("PaywallPurchaseButton")
            }
        }
        // CTA ↔ 成功态的切换要 0.25s 过渡。动画必须挂在包含 if/else 的父层——
        // 挂在 successCTA 自身时,该视图出现首帧 value 已是新值、没有变化事件,
        // 插入/移除过渡不会播(切换会直接跳变)。
        .animation(.easeOut(duration: 0.25), value: successEvent)
    }

    /// 成功态 CTA:原地变绿(WarmTheme.success 底 + checkmark + 「已升级为 Pro / 已恢复 Pro」)。
    /// 反馈出现在用户刚点的按钮上,视线不用挪。disabled 语义保留(成功窗口内不可再购买),
    /// 但用 UndimmedButtonStyle 绕开系统对 disabled 按钮的降透明度——成功态必须醒目。
    private func successCTA(_ event: PaywallView.SuccessEvent) -> some View {
        Button {} label: {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
                Text(event.message)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(
                Capsule()
                    .fill(WarmTheme.success)
                    .shadow(color: WarmTheme.success.opacity(0.3), radius: 18, y: 6)
            )
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(true)
        .accessibilityIdentifier("PaywallPurchaseButton")
        // UI 测试以 value == "success" 判断成功态(S20 Step 6)。
        .accessibilityValue("success")
    }

    /// 购买/恢复失败的显式反馈(错误显式传播):`lastError` 显示在购买按钮下、
    /// 续费说明上。「等待批准」(paywallPending)与「订阅状态已是最新」
    /// (paywallRestoreUpToDate)是中性提示,不走警示色——前者显示成错误会让
    /// 用户以为交易出了问题,后者本来就不是失败(已订阅用户点恢复的对账结论)。
    /// purchase/restore 开始时会清 lastError,双 isPurchasing/isRestoring 守卫
    /// 只是兜底防飞行中显示陈旧错误。
    @ViewBuilder
    private var inlineErrorText: some View {
        if !entitlement.isPurchasing, !entitlement.isRestoring, let error = entitlement.lastError {
            if error == ErrorMessages.paywallPending {
                neutralInlineInfo(icon: "clock", text: error)
            } else if error == ErrorMessages.paywallRestoreUpToDate {
                neutralInlineInfo(icon: "checkmark", text: error)
            } else {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(WarmTheme.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WarmSpacing.xs)
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
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(.top, WarmSpacing.xs)
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

    /// CTA 文案(v3 §5.4):两款商品都带 7 天试用——有试用资格时按钮统一
    /// 「开始 N 天免费试用」(N 来自 StoreKit,不手写);无资格随选中方案变
    /// 「订阅年度/月度 Pro」。资格查询中显示 spinner(见 showsCTASpinner)。
    private var ctaTitle: String {
        if entitlement.isEligibleForIntroOffer, let period = entitlement.introOfferPeriod {
            let periodStr = period.formattedLocalizedPeriod()
            return String(localized: "paywall.cta.start_trial \(periodStr)")
        }
        return currentSelectedProduct?.id == EntitlementManager.monthlyProductID
            ? String(localized: "paywall.cta.subscribe_monthly")
            : String(localized: "paywall.cta.subscribe_yearly")
    }

    // MARK: - 续费说明(v3)

    /// 续费说明(3.1.2:试用多久、之后收多少钱,必须在按钮附近写清):
    /// 价格随选中方案即时更新,沿用 legalPriceLine 的取数;试用信息只出现在
    /// 按钮与这里,方案卡不再带「含免费试用」小字(两种状态卡高一致,页面不跳)。
    /// 资格查询中暂不显示(C 点防抖,查询落定前文案会抖)。
    @ViewBuilder
    private var renewalNotice: some View {
        if entitlement.productLoadState == .success && !entitlement.isCheckingIntroOffer {
            Text(legalPriceLine)
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                // 合规文案不可截断:最多 3 行 + 0.85 缩放兜底(零容忍规则)。
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .padding(.top, WarmSpacing.sm)
        }
    }

    /// 价格条款行:有试用资格 →「免费试用 N 天,之后按 ¥xx/年 自动续费…」;
    /// 无资格 →「¥xx/年,自动续费…」。切换选中方案时随 body 即时更新。
    private var legalPriceLine: String {
        // renewalNotice 只在 productLoadState == .success 时渲染,
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

    // MARK: - 链接行 + 小字(v3)

    /// 链接行:一行居中「恢复购买 · 隐私政策 · 使用条款」。每个可点项的点击
    /// 区域高度至少 36pt(WarmSize.secondaryHit),视觉上仍是小字;分隔点不朗读。
    /// 恢复进行中:「恢复购买」位换转圈 +「正在恢复…」,购买按钮同步禁用(ctaDisabled)。
    private var linkRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await entitlement.restorePurchases() }
            } label: {
                HStack(spacing: WarmSpacing.xxs) {
                    if entitlement.isRestoring {
                        ProgressView()
                            .tint(WarmTheme.ink)
                        Text(ErrorMessages.paywallRestoring)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WarmTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(String(localized: "paywall.restore"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WarmTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(minHeight: WarmSize.secondaryHit)
            }
            .disabled(entitlement.isRestoring || entitlement.isPurchasing)

            linkDot
            Link(String(localized: "paywall.legal.privacy_link"), destination: PaywallLegal.privacyPolicyURL)
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: WarmSize.secondaryHit)
            linkDot
            Link(String(localized: "paywall.legal.terms_link"), destination: PaywallLegal.termsOfUseURL)
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: WarmSize.secondaryHit)
        }
    }

    private var linkDot: some View {
        Text("·")
            .font(.system(size: 13))
            .foregroundColor(WarmTheme.textMuted)
            .accessibilityHidden(true)
    }

    /// 独立开发者小字:v3 起叶子用代码画的 `leaf` 图标(原 🌱 移除),12pt 居中。
    private var indieFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf")
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.success)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.footer.indie"))
                .font(.system(size: 12))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 底部链接块(未订阅/已订阅分支共用):链接行 + 小字。
    /// 链接行不依赖商品加载结果(3.1.2:商品加载失败时链接也必须可点);
    /// 水平边距、底部安全区 padding 与背景由调用方套(两分支外层结构不同)。
    private var footerLinksContent: some View {
        VStack(spacing: 0) {
            linkRow
                // v3 设计稿:说明下 12pt。
                .padding(.top, WarmSpacing.sm)
            indieFooter
                // v3 设计稿:链接行下 10pt。
                .padding(.top, 10)
        }
    }

    // MARK: - 已订阅分支

    /// 已订阅(v3 §5.7):内容全部沿用,放进滚动区;底部固定区只放链接行 + 小字
    /// (无续费说明——那是购买前披露,对已订阅者是错误信息)。
    /// refresh() 仍无条件跑:isPro 若是 stale-true(订阅实际已过期),
    /// refreshEntitlements 会翻回 false,本分支自动退回完整购买 UI。
    private var subscribedBody: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.sm) {
                quotaBadge
                    .padding(.top, WarmSpacing.lg)
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

                #if DEBUG
                contentFitsHook
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, WarmSpacing.md)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, newHeight in
                contentHeight = newHeight
            }
        }
        .scrollIndicators(.hidden)
        .background(WarmTheme.background.ignoresSafeArea())
        // 同 purchaseBody:减去底部链接区 safeAreaInset 注入的 safe area,
        // 测可见滚动视口(§7「中间滚动区」口径)。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height - proxy.safeAreaInsets.bottom
        } action: { _, newHeight in
            viewportHeight = newHeight
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerLinksContent
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(WarmTheme.background)
        }
        .task { await entitlement.refresh() }
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let plan = subscribedPlanText {
                // 方案行:「Pro 年付 · ¥39.99/年」。displayName/displayPrice 全取 StoreKit,
                // 商品未加载(activeProductID 对不上 products)时不显示该行。
                Text(plan)
                    .font(.system(size: 13))
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
                    .font(.system(size: 12))
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
                .font(.system(size: 13))
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
                        .font(.system(size: 13))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(String(
                        format: String(localized: "paywall.subscribed.next_renewal %@"),
                        dateText
                    ))
                        .font(.system(size: 13))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            case .some(false):
                subscribedNoRenewExpiryText(expiration: expiration, dateText: dateText)
            case .none:
                Text(String(localized: "paywall.subscribed.expires \(dateText)"))
                    .font(.system(size: 13))
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
            .font(.system(size: 13))
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
                .font(.system(size: 16, weight: .semibold))
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
    /// 免费额度才从 toast 得知。给出原因与出口——「恢复购买」按钮就在下方链接行。
    /// 代理重新按 Pro 计(下次请求的响应头)后本行自动消失。
    /// 首页额度胶囊同状态改警示样式,与这里互为呼应。
    private var subscriptionRejectedHint: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WarmTheme.warning)
                .accessibilityHidden(true)
            Text(String(localized: "paywall.subscribed.rejected_hint"))
                .font(.system(size: 13))
                .foregroundColor(WarmTheme.warning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .accessibilityIdentifier("PaywallSubscriptionRejectedHint")
    }
}

// MARK: - 计费周期单位

/// 商品的本地化计费周期单位(「年」/「月」)。年付=年,其余(月付)=月。
/// 续费说明(legalPriceLine)与已订阅方案行共用同一口径。
/// @MainActor:引用 EntitlementManager.yearlyProductID(@MainActor 隔离的常量)。
@MainActor
private func paywallPeriodUnit(for product: Product) -> String {
    product.id == EntitlementManager.yearlyProductID
        ? String(localized: "paywall.period.year")
        : String(localized: "paywall.period.month")
}

/// 方案卡价格旁的短周期单位(「年」/「yr」)。v3 方案卡价格行用短单位。
@MainActor
private func paywallShortPeriodUnit(for product: Product) -> String {
    product.id == EntitlementManager.yearlyProductID
        ? String(localized: "paywall.period.year_short")
        : String(localized: "paywall.period.month_short")
}

// MARK: - 不降透明度的按钮样式

/// 只透传 label 的按钮样式。系统 ButtonStyle 在 disabled 时会给内容降透明度,
/// 成功态 CTA 需要保持醒目(任务书条目 1.2),禁用语义交给 Button.disabled。
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Plan Card(v3 方案卡)

/// 方案卡:点击切换 selectedProductID(选择语义,不触发购买)。
/// v3 布局:单选圈 + (方案名[+省 X% 角标] / 副标题)+ 右对齐价格(22pt heavy +
/// 短周期)。两种状态都画 2pt 描边(选中 ctaFill / 未选中 cardBackground 不可见),
/// 切换时尺寸不跳;选中态带 ctaFill 阴影。
/// 整卡合并为一个朗读元素并带 .isSelected;单选圈不参与朗读。
private struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    let isDisabled: Bool
    /// 「省 X%」角标文字(年度专属);nil 不显示。
    let saveBadgeText: String?
    let action: () -> Void

    private var isYearly: Bool {
        product.id == EntitlementManager.yearlyProductID
    }

    /// 年付折合月价(「约 ¥3.33/月」):`price / 12` 用 StoreKit 的 `priceFormatStyle`
    /// 格式化,币种/小数位跟随店面,不手写价格。月付副标题用固定「按月付费」。
    private var subtitleText: String? {
        if isYearly {
            let perMonth = product.priceFormatStyle.format(product.price / 12)
            return String(localized: "paywall.yearly_per_month \(perMonth)")
        }
        return String(localized: "paywall.plan.monthly_note")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                radioCircle
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(String(localized: isYearly ? "paywall.plan.yearly" : "paywall.plan.monthly"))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let saveBadgeText {
                            Text(saveBadgeText)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(WarmTheme.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(Capsule().fill(WarmTheme.primaryTint))
                        }
                    }
                    if let subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 13))
                            .foregroundColor(WarmTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                    }
                }
                Spacer(minLength: 8)
                // 价格:22pt heavy + 短周期(「/年」「/yr」)14pt。保持显示(弱化后),
                // 购买中用户仍知道在买什么;spinner 只在主 CTA 上,避免双 spinner。
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(product.displayPrice)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: "/\(paywallShortPeriodUnit(for: product))")
                        .font(.system(size: 14))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .fixedSize()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(WarmTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    // 两种状态都画 2pt 描边:未选中用 cardBackground(不可见),
                    // 保证选中切换时尺寸不跳。
                    .stroke(isSelected ? WarmTheme.ctaFill : WarmTheme.cardBackground, lineWidth: 2)
            )
            .shadow(
                color: WarmTheme.ctaFill.opacity(0.14),
                radius: isSelected ? 14 : 0,
                y: isSelected ? 4 : 0
            )
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .disabled(isDisabled)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 单选圈:22pt。选中 = ctaFill 实心 + 8pt 白点;未选中 = 2pt textMuted 圆环。
    /// 不参与朗读(整卡已合并)。
    private var radioCircle: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(WarmTheme.ctaFill)
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .stroke(WarmTheme.textMuted, lineWidth: 2)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
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
