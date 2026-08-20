import Foundation
import StoreKit
import Combine

/// StoreKit 2 订阅权益管理。负责判定 Pro 状态、提供 JWS 凭证（代理验签用）、购买与恢复。
///
/// - 仅 Pro 提高额度，不改核心工作流。
/// - JWS 来自 `Transaction.currentEntitlements` 的 `VerificationResult<Transaction>.jwsRepresentation`，
///   端侧已由 StoreKit 验签；代理侧（Phase 4）做独立的零信任验签。
/// - `nil` JWS / 过期 / 验签失败 → 代理按免费档处理（fail-safe）。
@MainActor
final class EntitlementManager: ObservableObject {
    /// App Store Connect 中的自动续费订阅产品 ID（月付 / 年付，同一订阅组）。
    /// 这两个 ID 必须与 VoiceTodo/Products.storekit（本地调试）以及 App Store Connect 上注册的
    /// 订阅（上架后）**逐字一致**,否则 Product.products(for:) 返回空数组。
    /// 注:IAP product ID 只要求全局唯一,并不要求以 bundle ID 为前缀 —— 这里对齐前缀纯属命名约定。
    static let monthlyProductID = "com.qingqingyu.voicetodo.pro.monthly"
    static let yearlyProductID = "com.qingqingyu.voicetodo.pro.yearly"
    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID]

    @Published private(set) var isPro: Bool = false
    /// 当前生效订阅的 JWS 字符串（发给代理做 Pro 档验签）。无生效订阅时为 nil。
    @Published private(set) var jwsString: String?
    @Published private(set) var products: [Product] = []
    /// 初始为 .loading —— 首帧应显示 spinner 而不是「加载失败」卡片。
    /// 真正的空/错误态由 loadProducts() 落定。
    @Published private(set) var productLoadState: ProductLoadState = .loading
    /// 最近一次购买/恢复/加载错误（用于 UI error 态）。nil 表示无错误。
    @Published private(set) var lastError: String?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    /// 当前 Apple ID 是否还能享受该订阅组的介绍性优惠（免费试用）。
    /// 老用户退订后重订将为 false —— 此时必须隐藏试用文案（App Store 审核要求）。
    @Published private(set) var isEligibleForIntroOffer = false
    /// 介绍性优惠时长（如 7 天）。nil 表示商品未配置试用或当前无资格。
    /// 取第一个带 introductoryOffer 的商品的试用周期 —— 月付/年付配置可能不同。
    @Published private(set) var introOfferPeriod: Product.SubscriptionPeriod?
    /// intro offer 资格查询的加载态。true 期间 CTA 显示 spinner、不渲染文案，
    /// 避免资格查询完成前后文案抖动造成「先承诺再变脸」（详见 docs/onboarding-paywall-merge.md 3.1 C 点）。
    /// 商品加载失败（.empty/.error）时此值翻为 false —— CTA 那时不渲染，spinner 也不需要转。
    @Published private(set) var isCheckingIntroOffer = true
    /// 商品加载重入守卫:避免用户连点 retry 触发并发 StoreKit 请求。
    /// `productLoadState == .loading` 已能反映此状态,但 UI 可能在 .empty/.error 时
    /// 也尝试触发 refresh,此标志提供显式护栏。
    private var isLoadingProducts = false

    private var transactionListener: Task<Void, Never>?

    enum ProductLoadState: Equatable {
        case loading
        case empty
        case error
        case success
    }

    /// - Parameter enableTransactionListener: 是否监听 `Transaction.updates`(StoreKit 2 异步流)。
    ///   生产环境传 true(默认)。测试/默认兜底场景传 false 避免:
    ///   (1) 启动常驻 Task 在测试方法结束后才释放;
    ///   (2) StoreKit mock 缺失时进入异常分支导致 flakiness。
    init(enableTransactionListener: Bool = true) {
        if enableTransactionListener {
            transactionListener = listenForTransactionUpdates()
        } else {
            transactionListener = nil
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - 加载

    /// 加载商品 + 刷新权益。App 启动与打开 paywall 时调用。
    func refresh() async {
        await loadProducts()
        await refreshEntitlements()
    }

    func loadProducts() async {
        // 重入守卫:已在加载时直接返回,避免并发 StoreKit 请求造成响应乱序。
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        productLoadState = .loading
        defer { isLoadingProducts = false }
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            products = storeProducts.sorted { $0.price < $1.price }
            lastError = nil
            if storeProducts.isEmpty {
                VoiceTodoLog.app.warning("entitlement.products_empty ids=\(Self.productIDs, privacy: .public)")
                productLoadState = .empty
                resetIntroOfferState()
            } else {
                productLoadState = .success
                await checkIntroOffer()
            }
        } catch {
            VoiceTodoLog.app.error("entitlement.products_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            lastError = ErrorMessages.paywallProductsLoadFailed
            productLoadState = .error
            resetIntroOfferState()
        }
    }

    /// 重置 intro offer 状态。商品加载失败时调用,让 CTA 不依赖过期的资格判断。
    /// isCheckingIntroOffer 翻 false —— CTA 在 .empty/.error 下根本不渲染,spinner 不需要继续转。
    private func resetIntroOfferState() {
        isEligibleForIntroOffer = false
        introOfferPeriod = nil
        isCheckingIntroOffer = false
    }

    /// 查询订阅组的介绍性优惠（免费试用）资格和时长。
    /// 失败保守处理（无 subscription 信息 / groupID 缺失 → 一律当无资格）,
    /// 宁可少承诺不可多承诺 —— 老用户重订场景下"承诺试用再变脸"是 App Store 审核硬伤。
    /// 注:iOS 26 SDK 起 isEligibleForIntroOffer(for:) 为非 throwing async,不再有异常路径。
    private func checkIntroOffer() async {
        isCheckingIntroOffer = true
        defer { isCheckingIntroOffer = false }

        // introductoryOffer 可能只在部分商品上配置(如年付有试用、月付没有)。
        // 取第一个带 introductoryOffer 的商品的试用周期;都没配则 nil。
        guard let productWithOffer = products.first(where: { $0.subscription?.introductoryOffer != nil }),
              let subscription = productWithOffer.subscription else {
            VoiceTodoLog.app.info("entitlement.intro_offer eligible=false hasPeriod=false reason=no_subscription")
            isEligibleForIntroOffer = false
            introOfferPeriod = nil
            return
        }

        introOfferPeriod = subscription.introductoryOffer?.period

        // iOS 26 SDK: Product.SubscriptionInfo.isEligibleForIntroOffer(for:) 已是非 throwing async。
        // 若未来 SDK 改回 throws,编译器会重新报错提醒恢复 do/try/catch。
        let eligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: subscription.subscriptionGroupID)
        isEligibleForIntroOffer = eligible

        VoiceTodoLog.app.info("entitlement.intro_offer eligible=\(self.isEligibleForIntroOffer) hasPeriod=\(self.introOfferPeriod != nil)")
    }

    /// 重读当前生效订阅。返回权益是否发生变化。
    @discardableResult
    func refreshEntitlements() async -> Bool {
        var foundPro = false
        var jws: String?
        // currentEntitlements 只返回当前生效（未过期）的权益，无需额外过期校验。
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            foundPro = true
            jws = result.jwsRepresentation
        }
        let changed = isPro != foundPro || jwsString != jws
        isPro = foundPro
        jwsString = jws
        VoiceTodoLog.app.info("entitlement.refresh isPro=\(foundPro) hasJWS=\(jws != nil) changed=\(changed)")
        return changed
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    // MARK: - 购买

    func purchase(_ product: Product) async {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        do {
            let outcome = try await product.purchase()
            switch outcome {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                }
                VoiceTodoLog.app.info("entitlement.purchase_success productID=\(product.id, privacy: .public) isPro=\(self.isPro)")
            case .userCancelled:
                VoiceTodoLog.app.info("entitlement.purchase_cancelled productID=\(product.id, privacy: .public)")
            case .pending:
                // 等待审批 / 家庭共享等，updates 监听会在最终状态刷新
                VoiceTodoLog.app.info("entitlement.purchase_pending productID=\(product.id, privacy: .public)")
                lastError = String(localized: "paywall.pending")
            @unknown default:
                break
            }
        } catch {
            VoiceTodoLog.app.error("entitlement.purchase_failed productID=\(product.id, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            lastError = ErrorMessages.paywallPurchaseFailed
        }
    }

    // MARK: - 恢复购买（App Store 审核必需入口）

    func restorePurchases() async {
        isRestoring = true
        lastError = nil
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro {
                lastError = ErrorMessages.paywallRestoreNothing
            }
            VoiceTodoLog.app.info("entitlement.restore_done isPro=\(self.isPro)")
        } catch {
            VoiceTodoLog.app.error("entitlement.restore_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            lastError = ErrorMessages.paywallRestoreFailed
        }
    }

    /// 供 NetworkClient 构造器注入的 JWS provider（保持构造器注入风格，不回退 ServiceContainer）。
    /// 弱引用 self，避免 NetworkClient 常驻导致 EntitlementManager 无法释放。
    var jwsProvider: @MainActor () -> String? { { [weak self] in self?.jwsString } }

#if DEBUG
    /// 测试注入口：单测环境无法驱动 StoreKit `currentEntitlements`，
    /// 直接注入 isPro / JWS 状态以覆盖订阅相关分支。
    /// Release 配置编译缺席（与 TelemetryQueue 的测试 seam 同一取舍），
    /// 若以 Release 跑测试，订阅分支相关测试将编译不过（预期）。
    func setEntitlementForTesting(isPro: Bool, jwsString: String? = nil) {
        self.isPro = isPro
        self.jwsString = jwsString
    }
#endif
}
