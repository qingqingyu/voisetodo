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
    static let monthlyProductID = "com.voicetodo.pro.monthly"
    static let yearlyProductID = "com.voicetodo.pro.yearly"
    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID]

    @Published private(set) var isPro: Bool = false
    /// 当前生效订阅的 JWS 字符串（发给代理做 Pro 档验签）。无生效订阅时为 nil。
    @Published private(set) var jwsString: String?
    @Published private(set) var products: [Product] = []
    @Published private(set) var productLoadState: ProductLoadState = .empty
    /// 最近一次购买/恢复/加载错误（用于 UI error 态）。nil 表示无错误。
    @Published private(set) var lastError: String?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false

    private var transactionListener: Task<Void, Never>?

    enum ProductLoadState: Equatable {
        case loading
        case empty
        case error
        case success
    }

    init() {
        // 监听交易更新（购买完成 / 退款 / 过期），实时刷新权益。
        transactionListener = listenForTransactionUpdates()
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
        productLoadState = .loading
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            products = storeProducts.sorted { $0.price < $1.price }
            lastError = nil
            if storeProducts.isEmpty {
                VoiceTodoLog.app.warning("entitlement.products_empty ids=\(Self.productIDs, privacy: .public)")
                productLoadState = .empty
            } else {
                productLoadState = .success
            }
        } catch {
            VoiceTodoLog.app.error("entitlement.products_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            lastError = ErrorMessages.paywallPurchaseFailed
            productLoadState = .error
        }
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
}
