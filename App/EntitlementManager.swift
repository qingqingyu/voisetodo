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
    /// 当前生效订阅的到期时间（自动续期开启时即下次续期日）。
    /// 付费墙"已订阅"态用它展示「有效期至 X」。无生效订阅时为 nil。
    @Published private(set) var subscriptionExpirationDate: Date?
    /// 当前生效订阅对应的商品 ID(年付/月付)。仅供已订阅状态页展示方案名与价格,
    /// 不参与权益判定;随 performEntitlementRefresh 选定交易时一并赋值。
    @Published private(set) var activeProductID: String?
    /// 当前生效订阅是否处于介绍性优惠(免费试用)期(transaction.offer?.type == .introductory)。
    @Published private(set) var isInIntroOffer = false
    /// 自动续费是否开启。nil = 读取不到(商品未加载 / status 缺失 / 验签不过),
    /// UI 遇 nil 回退「有效期至 X」文案。
    @Published private(set) var willAutoRenew: Bool?
    @Published private(set) var products: [Product] = []
    /// 初始为 .loading —— 首帧应显示 spinner 而不是「加载失败」卡片。
    /// 真正的空/错误态由 loadProducts() 落定。
    @Published private(set) var productLoadState: ProductLoadState = .loading
    /// 最近一次购买/恢复/加载错误（用于 UI error 态）。nil 表示无错误。
    @Published private(set) var lastError: String?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    /// 购买成功计数(只增不减的事件信号,与 isPro 状态解耦)。付费墙成功反馈观察它:
    /// isPro 在订阅过期后可能停留在 stale-true,二次购买成功时无 false→true 跳变,
    /// 靠 isPro 跳变驱动反馈会漏(2026-08 二次订阅「成功但不收起」事故根因之一)。
    @Published private(set) var purchaseSuccessCount = 0
    /// 恢复购买成功计数(**恢复前不是 Pro**、恢复后确认为 Pro 时 +1)。付费墙据此给出
    /// 「已恢复 Pro」反馈后收起。原本已订阅的用户点恢复只是对账,不计数——计了会让
    /// 已订阅状态页闪回购买页播 1 秒成功态再收起,已付费用户看着像出了错。
    @Published private(set) var restoreSuccessCount = 0
    /// 最近一次刷新是否「有本 App 订阅、但验签不过、且没有任何可信订阅」。
    /// 用于购买返回非成功时给出可行动的提示(恢复购买),而不是静默。
    private var hasUnverifiedEntitlement = false
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
    /// 最近一次购买是否停在「等待批准」(家长 Ask to Buy)。批准经 Transaction.updates
    /// 到账、isPro 翻正后据此补一次成功信号(purchaseSuccessCount += 1,只加一次);
    /// 任何直接购买/恢复成功都会清掉它,防止后续无关的续订推送重复计成功。
    private var hasPendingPurchase = false

    private var transactionListener: Task<Void, Never>?
    /// refreshEntitlements 串行链:每次调用排在上一次之后执行。
    /// 购买弹窗收起时 scenePhase 回到 .active 会触发一次刷新,与 purchase() 自己的
    /// 刷新并发;并发时若前者(快照取于交易落地前)晚于后者写回,会把刚买到的 isPro 覆盖回 false。
    /// 串行后「后发起的一定后快照、后写回」,且每个调用方 await 返回时看到的都是落定状态
    /// (restorePurchases 紧接着读 isPro 判断「无可恢复」依赖这一点)。
    private var entitlementRefreshChain: Task<Bool, Never>?
    /// willAutoRenew 异步读的代际号:每轮刷新自增,回填前校验仍是最新一代,
    /// 慢网下旧一轮读完成时新一轮已发起,其结果作废——防旧值覆盖新值。
    private var willAutoRenewReadGeneration = 0
    /// 订阅到期时刻的兜底刷新。到期(用户已取消续订)不会经 Transaction.updates 推送,
    /// App 一直在前台时 isPro 会停在 stale-true;到点主动重读一次 currentEntitlements。
    private var expirationRefreshTask: Task<Void, Never>?

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
        expirationRefreshTask?.cancel()
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
        let previous = entitlementRefreshChain
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performEntitlementRefresh()
        }
        entitlementRefreshChain = task
        return await task.value
    }

    private func performEntitlementRefresh() async -> Bool {
        var foundPro = false
        var jws: String?
        var expiration: Date?
        // 选定的那条交易:除 JWS/到期时间外,还供已订阅状态页展示元数据
        // (activeProductID / isInIntroOffer / willAutoRenew)。选择逻辑与 JWS 同源。
        var selectedTransaction: Transaction?
        // currentEntitlements 只返回当前生效（未过期、未退款）的权益。撤销/升级两道过滤是防御:
        // 代理零信任会拒掉带 revocationDate 的 JWS,客户端不该把它当 Pro 发出去。
        var unverifiedCount = 0
        for await result in Transaction.currentEntitlements {
            let transaction: Transaction
            switch result {
            case .verified(let verified):
                transaction = verified
            case .unverified(let unverified, let error):
                guard Self.productIDs.contains(unverified.productID) else { continue }
                // 旧代码这里静默 continue:StoreKit 明明认为已订阅(再点购买弹「你已订阅」),
                // App 却按未订阅渲染,且日志里毫无痕迹。至少要留痕,才能区分「没买到」与「验签失败」。
                VoiceTodoLog.app.warning("entitlement.entitlement_unverified productID=\(unverified.productID, privacy: .public) environment=\(unverified.environment.rawValue, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                guard Self.trustsUnverifiedLocally(unverified) else {
                    unverifiedCount += 1
                    continue
                }
                transaction = unverified
            }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            // 多条时取到期最晚的一条(JWS 与「有效期至」同源),不依赖遍历顺序。
            if foundPro, let current = expiration,
               (transaction.expirationDate ?? .distantPast) <= current {
                continue
            }
            foundPro = true
            jws = result.jwsRepresentation
            expiration = transaction.expirationDate
            selectedTransaction = transaction
        }
        if !foundPro, let fallback = await latestActiveSubscription() {
            // currentEntitlements 没给出、但 latest(for:) 有未过期的订阅:真机实测购买成功后
            // 权益仍显示免费档(系统弹窗却说已订阅),留痕以便确认是哪条路径漏的。
            VoiceTodoLog.app.warning("entitlement.refresh_fallback_latest productID=\(fallback.transaction.productID, privacy: .public) environment=\(fallback.transaction.environment.rawValue, privacy: .public)")
            foundPro = true
            jws = fallback.jws
            expiration = fallback.transaction.expirationDate
            selectedTransaction = fallback.transaction
        }
        hasUnverifiedEntitlement = !foundPro && unverifiedCount > 0
        scheduleExpirationRefresh(at: expiration)
        let changed = isPro != foundPro || jwsString != jws || subscriptionExpirationDate != expiration
        isPro = foundPro
        jwsString = jws
        subscriptionExpirationDate = expiration
        // 已订阅状态页的展示元数据(任务书条目 4):随选定交易一并赋值,
        // 只读展示用途,不影响上面的权益判定与 changed 语义。
        activeProductID = selectedTransaction?.productID
        isInIntroOffer = selectedTransaction?.offer?.type == .introductory
        // willAutoRenew 不能 await 在这里:读取要联网问 App Store(见 refreshWillAutoRenew),
        // 而购买成功路径要等本方法返回才 purchaseSuccessCount += 1(CTA 变绿),
        // 串在刷新里会把成功反馈拖到这次网络往返之后。改为异步读到再回填。
        refreshWillAutoRenew(for: selectedTransaction)
        VoiceTodoLog.app.info("entitlement.refresh isPro=\(foundPro) hasJWS=\(jws != nil) unverified=\(unverifiedCount) changed=\(changed) willAutoRenew=deferred")
        return changed
    }

    /// 异步读自动续费状态并回填。`Product.SubscriptionInfo.status` 可能联网问
    /// App Store,await 在 performEntitlementRefresh 里会拖慢它的所有调用方——
    /// 购买成功(等刷新返回才计成功数,CTA 变绿要 ≤0.5s)、恢复购买、
    /// Transaction.updates 监听、到期重读;断网时还会让每次刷新多记一条
    /// renewal_info_failed 警告。读到再回填,日期行短暂停留在上一值/回退文案,
    /// 属可接受的展示延迟(纯展示元数据,不影响权益判定)。
    /// 晚到的旧读按代际丢弃;无选定交易(未订阅)时同步置 nil,不做无谓的网络读。
    private func refreshWillAutoRenew(for transaction: Transaction?) {
        willAutoRenewReadGeneration += 1
        let generation = willAutoRenewReadGeneration
        guard let transaction else {
            willAutoRenew = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let value = await self.renewalWillAutoRenew(for: transaction)
            let isLatest = generation == self.willAutoRenewReadGeneration
            // willAutoRenew 打裸值(true/false/nil),不套 Optional(...) 包装,key=value 好解析。
            let label = value.map(String.init(describing:)) ?? "nil"
            VoiceTodoLog.app.info("entitlement.renewal_info willAutoRenew=\(label, privacy: .public) latest=\(isLatest, privacy: .public)")
            guard isLatest else { return }
            self.willAutoRenew = value
        }
    }

    /// 从 `Product.subscription.status` 读选定交易的 `renewalInfo.willAutoRenew`。
    /// 商品未加载(启动期只刷权益不加载商品)/status 里找不到该交易/renewalInfo
    /// 验签不过时返回 nil,UI 回退「有效期至 X」。
    private func renewalWillAutoRenew(for transaction: Transaction?) async -> Bool? {
        guard let transaction else { return nil }
        for product in products where product.id == transaction.productID {
            do {
                for status in try await product.subscription?.status ?? [] {
                    let statusTransaction: Transaction
                    switch status.transaction {
                    case .verified(let verified):
                        statusTransaction = verified
                    case .unverified:
                        continue
                    }
                    guard statusTransaction.id == transaction.id else { continue }
                    switch status.renewalInfo {
                    case .verified(let info):
                        return info.willAutoRenew
                    case .unverified:
                        return nil
                    }
                }
            } catch {
                // 显式留痕不静默:status 读不到时日期文案会退回「有效期至 X」,
                // 有这条日志才能区分「真读不到」与「没走到」。
                VoiceTodoLog.app.warning("entitlement.renewal_info_failed productID=\(transaction.productID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// 兜底:逐个商品读 `Transaction.latest(for:)`,取未撤销、未升级、未过期的那条
    /// (授信规则与 currentEntitlements 相同)。多条取到期最晚。
    private func latestActiveSubscription() async -> (transaction: Transaction, jws: String)? {
        var best: (transaction: Transaction, jws: String)?
        let now = Date()
        for productID in Self.productIDs {
            guard let result = await Transaction.latest(for: productID) else { continue }
            let transaction: Transaction
            switch result {
            case .verified(let verified):
                transaction = verified
            case .unverified(let unverified, _):
                guard Self.trustsUnverifiedLocally(unverified) else { continue }
                transaction = unverified
            }
            guard transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expirationDate = transaction.expirationDate, expirationDate > now else { continue }
            if let current = best?.transaction.expirationDate, expirationDate <= current { continue }
            best = (transaction, result.jwsRepresentation)
        }
        return best
    }

    /// 验签失败的权益是否仍在本地按 Pro 渲染。仅 DEBUG + Xcode 本地 StoreKit 环境:
    /// Command+R 真机调试时交易由 Xcode 本地证书签发,端侧验签可能不过,
    /// 不放行就会出现「系统说已订阅、App 显示未订阅」。只影响客户端 UI ——
    /// 代理锚定 Apple 根证书,Xcode 签发的 JWS 本来就按免费档处理(见 docs/payment-test-plan.md)。
    /// Release 构建永远不信任未验签交易(Xcode 环境交易也不可能出现在 TestFlight/App Store)。
    private static func trustsUnverifiedLocally(_ transaction: Transaction) -> Bool {
        #if DEBUG
        return transaction.environment == .xcode
        #else
        return false
        #endif
    }

    /// 在订阅到期时刻(+2s 余量)重读一次权益。续订成功会经 Transaction.updates 推送并重排本任务;
    /// 只有「已取消续订、到点过期」这条路径需要它。沙盒下月付 5 分钟一续,过期在前台很常见。
    private func scheduleExpirationRefresh(at expiration: Date?) {
        expirationRefreshTask?.cancel()
        expirationRefreshTask = nil
        // 已过到期时刻仍在 currentEntitlements 里(计费宽限期)时不排:否则每 2s 自我重排成忙循环。
        // 宽限期结束会经 Transaction.updates 推送,回前台也会重读。
        guard let expiration, expiration > Date() else { return }
        let delay = expiration.timeIntervalSinceNow + 2
        expirationRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.refreshEntitlements()
        }
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    await self.refreshEntitlements()
                    // Ask to Buy 批准到账:补发购买成功信号(付费墙还开着则显示成功态;
                    // 已关闭则 onDismiss 快照判定早已结束,计数增加无副作用)。
                    // 拒绝路径不产生 active 交易、isPro 不翻,不会走到这里。
                    if self.hasPendingPurchase, self.isPro {
                        self.hasPendingPurchase = false
                        self.purchaseSuccessCount += 1
                        Telemetry.record(.purchaseSucceeded(productID: transaction.productID, path: PurchaseSucceededPath.pendingApproval))
                        VoiceTodoLog.app.info("entitlement.purchase_approved_after_pending")
                    }
                case .unverified(let transaction, let error):
                    // 不 finish、不授信,但必须留痕 —— 静默丢弃会让续订/到账的验签异常无从归因。
                    VoiceTodoLog.app.warning("entitlement.transaction_unverified transactionID=\(transaction.id) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    // 是否授信由 performEntitlementRefresh 统一判定(DEBUG + Xcode 环境放行),这里只触发重读。
                    await self.refreshEntitlements()
                }
            }
        }
    }

    // MARK: - 购买

    func purchase(_ product: Product) async {
        // 重入守卫(在第一个 await 之前同步判定):CTA 的 disabled 要等下一帧渲染才生效,
        // 连点两下会排进两个 purchase Task,第二个在这里被挡掉,不会叠出第二个系统购买弹窗。
        guard !isPurchasing, !isRestoring else {
            VoiceTodoLog.app.info("entitlement.purchase_ignored reason=in_flight productID=\(product.id, privacy: .public)")
            return
        }
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        let wasPro = isPro
        Telemetry.record(.purchaseInitiated(productID: product.id))
        do {
            let outcome = try await product.purchase()
            switch outcome {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    // 直接购买成功:清掉可能残留的 pending 标志,防止后续无关的
                    // 续订推送(Transaction.updates)重复计成功。
                    hasPendingPurchase = false
                    if !isPro {
                        // StoreKit 已给出验签通过的成功交易,权益重读却没反映出来:以这笔交易为准,
                        // 否则付费墙停在购买态、用户付了钱看不到任何变化。
                        VoiceTodoLog.app.warning("entitlement.purchase_entitlement_missing productID=\(product.id, privacy: .public) transactionID=\(transaction.id)")
                        applyPurchasedEntitlement(transaction, jws: verification.jwsRepresentation)
                    }
                    purchaseSuccessCount += 1
                    Telemetry.record(.purchaseSucceeded(productID: product.id, path: PurchaseSucceededPath.direct))
                    VoiceTodoLog.app.info("entitlement.purchase_success productID=\(product.id, privacy: .public) isPro=\(self.isPro)")
                    return
                case .unverified(let transaction, let error):
                    // 端侧 StoreKit 验签失败:不 finish(不可信交易不授信也不消费,Apple
                    // checkVerified 范式),显式报错而非静默 —— 旧代码这里什么都不做还照打
                    // 成功日志,正是「提示成功但不收起/不生效」的直接根因之一。
                    VoiceTodoLog.app.error("entitlement.purchase_unverified productID=\(product.id, privacy: .public) transactionID=\(transaction.id) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    Telemetry.record(.purchaseFailed(productID: product.id, reason: "unverified"))
                    lastError = ErrorMessages.paywallPurchaseUnverified
                }
            case .userCancelled:
                Telemetry.record(.purchaseCancelled(productID: product.id))
                VoiceTodoLog.app.info("entitlement.purchase_cancelled productID=\(product.id, privacy: .public)")
            case .pending:
                // 等待审批 / 家庭共享等，updates 监听会在最终状态刷新。
                // 置 hasPendingPurchase:批准经 Transaction.updates 到账、权益翻 Pro 后
                // 补一次 purchaseSuccessCount,付费墙若还开着就能走成功态(任务书条目 2a.4)。
                Telemetry.record(.purchasePending(productID: product.id))
                VoiceTodoLog.app.info("entitlement.purchase_pending productID=\(product.id, privacy: .public)")
                hasPendingPurchase = true
                lastError = ErrorMessages.paywallPending
            @unknown default:
                // 未来 SDK 新增 outcome 时编译兜底:显式留痕 + 用户可见反馈,不静默。
                Telemetry.record(.purchaseFailed(productID: product.id, reason: "unknown_outcome"))
                VoiceTodoLog.app.warning("entitlement.purchase_unknown_outcome productID=\(product.id, privacy: .public)")
                lastError = ErrorMessages.paywallPurchaseFailed
            }
        } catch {
            Telemetry.record(.purchaseFailed(productID: product.id, reason: Telemetry.reason(for: error)))
            VoiceTodoLog.app.error("entitlement.purchase_failed productID=\(product.id, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            lastError = ErrorMessages.paywallPurchaseFailed
        }
        await reconcileAfterNonSuccessPurchase(productID: product.id, wasPro: wasPro)
    }

    /// 直接以刚购买成功(已验签)的交易设置权益。下次 refreshEntitlements 会按 StoreKit 重新落定。
    private func applyPurchasedEntitlement(_ transaction: Transaction, jws: String) {
        isPro = true
        jwsString = jws
        subscriptionExpirationDate = transaction.expirationDate
        hasUnverifiedEntitlement = false
        scheduleExpirationRefresh(at: transaction.expirationDate)
    }

    /// 购买没有走到「verified 成功」时,以 StoreKit 当前权益为准再对账一次。
    /// 典型场景:App 的 isPro 是 stale-false,用户再点购买,系统弹「你已订阅」后
    /// purchase() 返回取消/失败 —— 此前 App 什么都不做,用户只能从系统弹窗得知已订阅。
    /// 对账后发现已是 Pro → 按购买成功处理(付费墙显示成功反馈后收起);
    /// 仍不是 Pro 但存在验签失败的订阅 → 明确提示恢复购买,不再静默。
    private func reconcileAfterNonSuccessPurchase(productID: String, wasPro: Bool) async {
        await refreshEntitlements()
        if isPro, !wasPro {
            lastError = nil
            purchaseSuccessCount += 1
            Telemetry.record(.purchaseSucceeded(productID: productID, path: PurchaseSucceededPath.reconciled))
            VoiceTodoLog.app.info("entitlement.purchase_reconciled productID=\(productID, privacy: .public)")
        } else if !isPro, hasUnverifiedEntitlement, lastError == nil {
            lastError = ErrorMessages.paywallPurchaseUnverified
        }
    }

    // MARK: - 恢复购买（App Store 审核必需入口）

    func restorePurchases() async {
        guard !isRestoring, !isPurchasing else {
            VoiceTodoLog.app.info("entitlement.restore_ignored reason=in_flight")
            return
        }
        isRestoring = true
        lastError = nil
        defer { isRestoring = false }
        // 恢复前是否已是 Pro:已订阅用户点「恢复购买」是对账(确认订阅仍在),
        // 不是一次「恢复成功」事件。若照样计成功,已订阅状态页会闪回购买页播
        // 1 秒绿色成功态再收起——已付费用户突然看到购买页,像出了错。
        // 改为只给行内中性「订阅状态已是最新」,页面保持在状态页。
        let wasPro = isPro
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isPro {
                // 恢复成功同样清 pending 标志(口径与直接购买成功一致)。
                hasPendingPurchase = false
                if wasPro {
                    Telemetry.record(.restoreOutcome(outcome: RestoreOutcomeValue.alreadyPro))
                    lastError = ErrorMessages.paywallRestoreUpToDate
                } else {
                    Telemetry.record(.restoreOutcome(outcome: RestoreOutcomeValue.recovered))
                    restoreSuccessCount += 1
                }
            } else {
                Telemetry.record(.restoreOutcome(outcome: RestoreOutcomeValue.nothing))
                lastError = ErrorMessages.paywallRestoreNothing
            }
            VoiceTodoLog.app.info("entitlement.restore_done isPro=\(self.isPro) wasPro=\(wasPro)")
        } catch StoreKitError.userCancelled {
            // 用户在 Apple 账户验证弹窗点了取消:不是失败,不报错。
            Telemetry.record(.restoreOutcome(outcome: RestoreOutcomeValue.cancelled))
            VoiceTodoLog.app.info("entitlement.restore_cancelled")
        } catch {
            Telemetry.record(.restoreOutcome(outcome: RestoreOutcomeValue.failed))
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
    func setEntitlementForTesting(isPro: Bool, jwsString: String? = nil, expirationDate: Date? = nil) {
        self.isPro = isPro
        self.jwsString = jwsString
        self.subscriptionExpirationDate = expirationDate
    }
#endif
}
