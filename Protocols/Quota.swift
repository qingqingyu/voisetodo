import Foundation

/// 免费档 UI 占位与本地估算用的额度常量。代理返回的 `X-Quota-*` 头是权威数据源，优先于此值。
enum QuotaConfig {
    /// 免费档每日本地估算上限（代理未返回额度头时用于 UI 后备，并标「非权威」）。
    static let freeDailyLimit: Int = NetworkConfig.freeDailyLimit
}

/// 代理额度更新协议。NetworkClient 读取代理响应头后通过它推送给额度模型。
/// 仅 `@MainActor`：额度状态由 UI 在主线程消费，避免额外的同步原语。
@MainActor
protocol QuotaProviding: AnyObject {
    /// 用代理响应头更新额度（权威数据源）。无任何 `X-Quota-*` 头时保留现有本地估算。
    /// - Parameter carriedSubscriptionJWS: 本次请求是否实际携带了订阅凭证
    ///   （`X-Subscription-JWS` 已随请求发出）。携带凭证而代理仍按 free 档计
    ///   = 代理拒了这份订阅（验签失败 / 计费宽限期 / 已退款），额度模型据此置
    ///   `proxyRejectedSubscription`，展示层不得再把它当「订阅前的旧数据」过渡到 Pro 档。
    func applyQuotaHeaders(from response: HTTPURLResponse, carriedSubscriptionJWS: Bool)
    /// 标记额度获取失败（UI 进入非权威 / error 态）。
    func markQuotaLoadFailed()
}

/// 用量额度展示模型。权威数据来自代理 `X-Quota-*` 响应头；无头时回退本地估算并标 `isAuthoritative=false`。
/// UI 四态：loading（读取中）/ empty（暂无用量）/ error（额度获取失败）/ success（显示用量或 Pro）。
///
/// 注意：Pro 档也是**有限**额度（`NetworkConfig.proDailyLimit`，代理 `PAID_DAILY_LIMIT`），
/// 只是上限更高。UI 一律显示「已用 used/limit」，不得对任何档位宣称「无限」。
@MainActor
final class QuotaUsage: ObservableObject, QuotaProviding {
    enum LoadState: Equatable {
        case loading
        case empty
        case error
        case success
    }

    /// Plan 标签（"free" / "pro"）。仅展示用，缺失时按 `isPro` 推断。
    enum Plan: String {
        case free
        case pro
    }

    @Published private(set) var used: Int = 0
    @Published private(set) var limit: Int = QuotaConfig.freeDailyLimit
    @Published private(set) var remaining: Int = QuotaConfig.freeDailyLimit
    @Published private(set) var resetDate: String?
    @Published private(set) var plan: Plan = .free
    @Published private(set) var isAuthoritative: Bool = false
    /// 本次离线补处理计入的条数（透明提示用）。
    @Published private(set) var backgroundIncluded: Int = 0
    /// 代理拒绝订阅：最近一次权威更新来自一次**携带了** `X-Subscription-JWS` 的请求，
    /// 代理却仍按 free 档计（验签失败 / 计费宽限期 / 已退款）。
    /// 此时 StoreKit 本地 isPro 与代理快照的矛盾**不是**「订阅前的旧数据」，
    /// `displayedLimit` 不得过渡到 Pro 常量——用户实际只剩免费档额度，
    /// 显示 x/100 会掩盖「付了钱没生效」。代理重新按 Pro 计（如下一次请求
    /// 恢复购买生效后）自动翻回 false。
    @Published private(set) var proxyRejectedSubscription = false
    @Published private(set) var loadState: LoadState = .empty

    /// 上次本地估算所基于的日期（YYYY-MM-DD，设备时区）。跨 0 点清零本地估算。
    private var localEstimateDate: String

    var isPro: Bool { plan == .pro }

    init() {
        localEstimateDate = Self.currentLocalDate()
    }

    // MARK: - QuotaProviding

    func applyQuotaHeaders(from response: HTTPURLResponse, carriedSubscriptionJWS: Bool) {
        let planRaw = response.value(forHTTPHeaderField: "X-Quota-Plan")
        let limitStr = response.value(forHTTPHeaderField: "X-Quota-Limit")
        let usedStr = response.value(forHTTPHeaderField: "X-Quota-Used")
        let remainingStr = response.value(forHTTPHeaderField: "X-Quota-Remaining")
        let resetDate = response.value(forHTTPHeaderField: "X-Quota-Reset-Date")

        // 无任何额度头 → 不是权威源，保留本地估算。
        guard planRaw != nil || limitStr != nil || usedStr != nil || remainingStr != nil else {
            return
        }
        isAuthoritative = true
        if let planRaw {
            plan = Plan(rawValue: planRaw) ?? .free
            // 拒绝判定只在代理明确表态 free 时做：带了凭证 + 代理仍说 free = 被拒；
            // 代理没给 plan 的部分头不臆断（维持既有状态，等下一次明确表态），
            // 未知档位值（如未来新增 tier）只回落 `.free` 供展示，不算明确表态
            // free——置拒绝标志会谎报「订阅验证未通过」。
            proxyRejectedSubscription = carriedSubscriptionJWS && planRaw == Plan.free.rawValue
        }
        if let l = limitStr.flatMap(Int.init) { limit = l }
        if let u = usedStr.flatMap(Int.init) { used = u }
        if let r = remainingStr.flatMap(Int.init) { remaining = r }
        if let resetDate { self.resetDate = resetDate }
        loadState = .success
        VoiceTodoLog.network.info("quota.update plan=\(planRaw ?? "nil", privacy: .public) used=\(usedStr ?? "nil", privacy: .public) remaining=\(remainingStr ?? "nil", privacy: .public) reset=\(resetDate ?? "nil", privacy: .public) rejected=\(self.proxyRejectedSubscription, privacy: .public) authoritative=true")
    }

    func markQuotaLoadFailed() {
        loadState = .error
        VoiceTodoLog.network.warning("quota.update_failed authoritative=false loadState=error")
    }

    // MARK: - 展示过渡（矛盾窗口期）

    /// 展示用 limit。**矛盾窗口期** —— StoreKit 已判定 Pro（`EntitlementManager.isPro`，
    /// 订阅成功本地即时生效）而本模型仍是订阅前的 free 档快照（代理 `X-Quota-*`
    /// 只在下一次提取请求的响应到达，订阅成功本身不产生任何代理请求）——
    /// 返回 `NetworkConfig.proDailyLimit` 过渡，避免已订阅用户在 paywall 看到
    /// 「已订阅」状态卡与「x/3」免费额度自相矛盾。其余情况返回权威/估算 limit。
    ///
    /// **例外：代理拒订阅**（`proxyRejectedSubscription`，请求带了凭证代理仍回
    /// free 档）不在此过渡之列——那不是旧数据，是订阅验证被拒的现行事实，
    /// 显示 Pro 常量会让用户以为还有 100 次，第 3 次被拦时只看到「额度已用完」，
    /// 完全不知道订阅出了问题。此时返回代理权威的 free 档 limit。
    ///
    /// `used` 由调用方保留：代理配额 key（`quota:<date>:<device>`）不分档位，
    /// 免费期用量在订阅后同样计入当天配额，旧 used 对 Pro 档仍然准确。
    /// 窗口在下一次 `applyQuotaHeaders` 后自动消失，调用方无需清理。
    ///
    /// 已知偏差：①若 `PAID_DAILY_LIMIT`（wrangler.toml）改配置而客户端常量未随
    /// 版本同步，窗口期显示偏小（如 x/100 vs 实际 x/200），首次使用后被权威值
    /// 纠正，双端同步前提下不存在此方向的「承诺偏大」。②反向场景：订阅过期后
    /// `isPro` 停留 stale-true 而代理权威快照已翻 free 时（`X-Quota-Plan: free`
    /// 且该请求未带凭证，不算「被拒」），本方法短暂返回 Pro 常量（显示偏大）——
    /// 与 `comparisonCard` 分流同口径跟随 StoreKit 本地判定，
    /// paywall 的 `refresh()` 翻正后自动消失，仅影响展示不影响执行。
    /// 双端同步约定见 Constants.swift。
    func displayedLimit(storeKitIsPro: Bool) -> Int {
        guard storeKitIsPro, !isPro, !proxyRejectedSubscription else { return limit }
        return NetworkConfig.proDailyLimit
    }

    // MARK: - 本地估算（无权威头时的后备）

    /// 记一次本地估算的用量增加（如离线补处理成功一条）。仅在非权威态下驱动 UI。
    func recordLocalUsageIncrement(background: Bool = false) {
        rolloverLocalEstimateIfNeeded()
        guard !isAuthoritative else { return }
        used += 1
        remaining = max(0, limit - used)
        if background { backgroundIncluded += 1 }
        if loadState == .empty { loadState = .success }
    }

    /// 跨 0 点清零本地估算，与代理 key 的本地日期边界对齐。
    func rolloverLocalEstimateIfNeeded() {
        let today = Self.currentLocalDate()
        guard today != localEstimateDate else { return }
        localEstimateDate = today
        if !isAuthoritative {
            used = 0
            remaining = limit
            backgroundIncluded = 0
        }
    }

    /// 重置为初始空态（如切换账号 / 调试）。
    func reset() {
        used = 0
        limit = QuotaConfig.freeDailyLimit
        remaining = QuotaConfig.freeDailyLimit
        resetDate = nil
        plan = .free
        isAuthoritative = false
        proxyRejectedSubscription = false
        backgroundIncluded = 0
        loadState = .empty
        localEstimateDate = Self.currentLocalDate()
    }

    // MARK: - 日期工具

    /// 设备时区下的 `YYYY-MM-DD`，与代理 `X-Local-Date` 同源。
    nonisolated static func currentLocalDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
