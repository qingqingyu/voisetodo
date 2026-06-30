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
    func applyQuotaHeaders(from response: HTTPURLResponse)
    /// 标记额度获取失败（UI 进入非权威 / error 态）。
    func markQuotaLoadFailed()
}

/// 用量额度展示模型。权威数据来自代理 `X-Quota-*` 响应头；无头时回退本地估算并标 `isAuthoritative=false`。
/// UI 四态：loading（读取中）/ empty（暂无用量）/ error（额度获取失败）/ success（显示用量或 Pro）。
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
    @Published private(set) var loadState: LoadState = .empty

    /// 上次本地估算所基于的日期（YYYY-MM-DD，设备时区）。跨 0 点清零本地估算。
    private var localEstimateDate: String

    var isPro: Bool { plan == .pro }

    /// Pro 档：UI 显示「无限」，内部仍记 `used` 供诊断。
    var showsUnlimited: Bool { isPro }

    init() {
        localEstimateDate = Self.currentLocalDate()
    }

    // MARK: - QuotaProviding

    func applyQuotaHeaders(from response: HTTPURLResponse) {
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
        if let planRaw { plan = Plan(rawValue: planRaw) ?? .free }
        if let l = limitStr.flatMap(Int.init) { limit = l }
        if let u = usedStr.flatMap(Int.init) { used = u }
        if let r = remainingStr.flatMap(Int.init) { remaining = r }
        if let resetDate { self.resetDate = resetDate }
        loadState = .success
        VoiceTodoLog.network.info("quota.update plan=\(planRaw ?? "nil", privacy: .public) used=\(usedStr ?? "nil", privacy: .public) remaining=\(remainingStr ?? "nil", privacy: .public) reset=\(resetDate ?? "nil", privacy: .public) authoritative=true")
    }

    func markQuotaLoadFailed() {
        loadState = .error
        VoiceTodoLog.network.warning("quota.update_failed authoritative=false loadState=error")
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
