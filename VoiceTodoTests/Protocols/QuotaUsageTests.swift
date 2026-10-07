import XCTest
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// 额度展示模型的档位语义测试。
///
/// 核心不变量：**Pro 档是更高的有限额度，不是无限**。
/// 曾经 `QuotaUsage.showsUnlimited` 让 UI 对 Pro 用户显示「无限」，而代理侧
/// `PAID_DAILY_LIMIT` 是一个具体上限（甚至一度完全没配置 → Pro 和免费额度相同），
/// 属于「付费权益虚标」。这组测试锁住修复后的语义。
@MainActor
final class QuotaUsageTests: XCTestCase {

    // MARK: - 常量一致性

    func testProDailyLimitExceedsFreeDailyLimit() {
        XCTAssertGreaterThan(
            NetworkConfig.proDailyLimit,
            NetworkConfig.freeDailyLimit,
            "Pro 档上限必须高于免费档，否则订阅不带来任何额度提升，paywall 的承诺无法兑现"
        )
    }

    func testFreeDailyLimitIsPositive() {
        XCTAssertGreaterThan(NetworkConfig.freeDailyLimit, 0)
        XCTAssertEqual(
            QuotaConfig.freeDailyLimit,
            NetworkConfig.freeDailyLimit,
            "QuotaConfig 只是 NetworkConfig 的转发，两者不应出现第三个数字来源"
        )
    }

    // MARK: - Pro 档：有限额度，不是无限

    func testProPlanReportsFiniteLimitFromProxyHeaders() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "pro",
            "X-Quota-Limit": "100",
            "X-Quota-Used": "7",
            "X-Quota-Remaining": "93",
            "X-Quota-Reset-Date": "2026-05-26"
        ]), carriedSubscriptionJWS: false)

        XCTAssertTrue(sut.isPro)
        XCTAssertTrue(sut.isAuthoritative)
        XCTAssertEqual(sut.loadState, .success)
        // Pro 也是具体上限，UI 据此显示「已用 7/100」而非「无限」
        XCTAssertEqual(sut.limit, 100)
        XCTAssertEqual(sut.used, 7)
        XCTAssertEqual(sut.remaining, 93)
        XCTAssertEqual(sut.resetDate, "2026-05-26")
    }

    func testFreePlanReadsProxyHeaders() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "2",
            "X-Quota-Used": "2",
            "X-Quota-Remaining": "0"
        ]), carriedSubscriptionJWS: false)

        XCTAssertFalse(sut.isPro)
        XCTAssertEqual(sut.plan, .free)
        XCTAssertEqual(sut.limit, 2)
        XCTAssertEqual(sut.remaining, 0)
    }

    /// 代理返回的 limit 是权威值，覆盖客户端常量后备。
    /// 这让「代理侧改额度」不需要发新版 App 就能生效。
    func testProxyLimitOverridesLocalFallback() {
        let sut = QuotaUsage()
        XCTAssertEqual(sut.limit, NetworkConfig.freeDailyLimit, "初始应是本地后备值")

        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "100"
        ]), carriedSubscriptionJWS: false)

        XCTAssertEqual(sut.limit, 100)
    }

    // MARK: - 无额度头：保留本地估算

    func testNoQuotaHeadersKeepsLocalEstimate() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: ["Content-Type": "application/json"]), carriedSubscriptionJWS: false)

        XCTAssertFalse(sut.isAuthoritative, "没有任何 X-Quota-* 头时不得声称权威")
        XCTAssertEqual(sut.limit, NetworkConfig.freeDailyLimit)
        XCTAssertEqual(sut.loadState, .empty)
    }

    func testLocalEstimateIncrementsOnlyWhileNonAuthoritative() {
        let sut = QuotaUsage()
        sut.recordLocalUsageIncrement()
        XCTAssertEqual(sut.used, 1)
        XCTAssertEqual(sut.remaining, max(0, NetworkConfig.freeDailyLimit - 1))

        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Used": "5",
            "X-Quota-Limit": "100"
        ]), carriedSubscriptionJWS: false)
        sut.recordLocalUsageIncrement()

        XCTAssertEqual(sut.used, 5, "权威值到位后，本地估算不应再自增")
    }

    // MARK: - 矛盾窗口期展示过渡（displayedLimit）

    /// 刚订阅（StoreKit 已 Pro）但代理响应未到：quotaUsage 仍是订阅前的
    /// free 档权威快照（订阅成功不产生代理请求，X-Quota-* 只随下一次提取
    /// 响应到达）。此窗口期实时卡显示 X/proDailyLimit，而非 X/3 与
    /// 「已订阅」状态卡自相矛盾（2026-10 沙盒真机复现）。
    func testDisplayedLimitUsesProConstantDuringEntitlementGap() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3",
            "X-Quota-Used": "1",
            "X-Quota-Remaining": "2"
        ]), carriedSubscriptionJWS: false)

        XCTAssertEqual(
            sut.displayedLimit(storeKitIsPro: true),
            NetworkConfig.proDailyLimit,
            "矛盾窗口期应过渡到 Pro 档常量，而不是沿用 free 档权威快照"
        )
        // used 由调用方保留权威值：配额 key 不分档位，免费期用量在订阅后仍计入
        XCTAssertEqual(sut.used, 1)
    }

    /// 代理权威快照追上（下一次提取请求后）窗口消失，返回权威值。
    /// limit 用与 `proDailyLimit`（100）错开的 150：若实现退化为
    /// 「storeKitIsPro 时无条件返回常量」，150≠100 会让本测试失败，
    /// 从而真正锁住「权威优先于常量」的语义。
    func testDisplayedLimitReturnsAuthoritativeValueOnceProxyCaughtUp() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "pro",
            "X-Quota-Limit": "150",
            "X-Quota-Used": "2"
        ]), carriedSubscriptionJWS: false)

        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: true), 150)
    }

    /// 未订阅：不动用 Pro 常量，返回原 limit（权威或本地后备）。
    func testDisplayedLimitIgnoresProConstantWhenNotSubscribed() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3",
            "X-Quota-Used": "1"
        ]), carriedSubscriptionJWS: false)

        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: false), 3)
    }

    /// 重启场景：quotaUsage 不持久化，重新初始化为非权威 free 后备
    /// （used=0/limit=3），已订阅用户不应看到退化的「0/3」。
    func testDisplayedLimitCoversNonAuthoritativeRestartState() {
        let sut = QuotaUsage()
        XCTAssertFalse(sut.isAuthoritative)

        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: true), NetworkConfig.proDailyLimit)
        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: false), NetworkConfig.freeDailyLimit)
    }

    // MARK: - 代理拒订阅（带了凭证仍回免费档）

    /// 请求携带了订阅凭证（carriedSubscriptionJWS=true），代理仍按 free 档计：
    /// StoreKit 本地 isPro 与代理快照的矛盾**不是**「订阅前的旧数据」，而是代理
    /// 拒了这份订阅（验签失败 / 计费宽限期 / 已退款）。此时 displayedLimit 不得
    /// 过渡到 Pro 常量——用户实际只剩免费档额度，显示 x/100 会掩盖「付了钱没生效」。
    /// （2026-10 沙盒会话提出此修复但分支被覆盖未落库，本组测试锁住语义防再丢。）
    func testProxyRejectedSubscriptionShowsProxyLimitNotProConstant() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3",
            "X-Quota-Used": "2",
            "X-Quota-Remaining": "1"
        ]), carriedSubscriptionJWS: true)

        XCTAssertTrue(sut.proxyRejectedSubscription)
        XCTAssertEqual(
            sut.displayedLimit(storeKitIsPro: true),
            3,
            "被拒后剩余的是免费档额度，不得显示 Pro 常量 \(NetworkConfig.proDailyLimit)"
        )
    }

    /// 下一次代理按 Pro 计（如恢复购买生效后的请求）拒绝状态自动翻回，
    /// 权威值恢复显示——「被拒 → 恢复」的完整弧线。
    func testProxyRejectedSubscriptionClearsWhenProxyAcceptsAgain() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3"
        ]), carriedSubscriptionJWS: true)
        XCTAssertTrue(sut.proxyRejectedSubscription)

        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "pro",
            "X-Quota-Limit": "150"
        ]), carriedSubscriptionJWS: true)

        XCTAssertFalse(sut.proxyRejectedSubscription)
        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: true), 150)
    }

    /// 未携带凭证的 free 档是正常免费用户，不算「被拒」；
    /// 矛盾窗口期过渡（displayedLimit 过渡到 Pro 常量）照旧生效。
    func testFreePlanWithoutCredentialsIsNotRejection() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3"
        ]), carriedSubscriptionJWS: false)

        XCTAssertFalse(sut.proxyRejectedSubscription)
        XCTAssertEqual(
            sut.displayedLimit(storeKitIsPro: true),
            NetworkConfig.proDailyLimit,
            "未携带凭证的 free 快照仍是矛盾窗口期形态，照旧过渡到 Pro 常量"
        )
    }

    /// 无 X-Quota-Plan 的部分头不做拒绝判定：代理没表态档位时不臆断恢复，
    /// 维持既有状态等下一次明确表态（宁可持续提示被拒，不可假称已恢复）。
    func testPartialHeadersWithoutPlanDoNotAffectRejectionState() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3"
        ]), carriedSubscriptionJWS: true)
        XCTAssertTrue(sut.proxyRejectedSubscription)

        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Used": "9"
        ]), carriedSubscriptionJWS: true)

        XCTAssertTrue(sut.proxyRejectedSubscription, "代理未表态档位时拒绝状态维持")
        XCTAssertEqual(sut.used, 9)
    }

    /// 未知档位值（如未来代理新增 tier）只回落 `.free` 供展示,不算「明确表态
    /// free」——置拒绝标志会让 toast 谎报「订阅验证未通过」。
    func testUnknownPlanValueIsNotExplicitFreeRejection() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "team",
            "X-Quota-Limit": "50"
        ]), carriedSubscriptionJWS: true)

        XCTAssertFalse(sut.proxyRejectedSubscription, "未知档位不是明确表态 free,不得置拒绝标志")
        XCTAssertEqual(sut.plan, .free, "展示回落语义保持既有行为")
    }

    // MARK: - quotaExhausted 文案的档位口径（errorDescription）

    /// errorDescription 是 Siri snippet 等直接消费 errorDescription 的通用面数据源，
    /// tier 是代理计费口径的权威快照：按 pro 计的用户撞上限不得看到「免费」字样；
    /// 按 free 计（含凭证被拒——被拒提示由持有凭证信息的高层，如 Siri 对话框
    /// 三分流 / App 内 toast 分流负责）维持免费口径。
    func testQuotaExhaustedErrorDescriptionFollowsProxyTier() {
        XCTAssertEqual(
            VoiceTodoError.quotaExhausted(tier: "pro", resetAt: "2026-05-26").errorDescription,
            ErrorMessages.quotaExhaustedPro
        )
        XCTAssertEqual(
            VoiceTodoError.quotaExhausted(tier: "free", resetAt: "2026-05-26").errorDescription,
            ErrorMessages.quotaExhausted
        )
    }

    /// 凭证换了(恢复购买/重新购买)后清掉旧凭证的被拒判定,回到过渡态显示 Pro 常量。
    func testClearSubscriptionRejectionRestoresTransitionDisplay() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: [
            "X-Quota-Plan": "free",
            "X-Quota-Limit": "3",
            "X-Quota-Used": "1"
        ]), carriedSubscriptionJWS: true)
        XCTAssertTrue(sut.proxyRejectedSubscription)
        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: true), 3)

        sut.clearSubscriptionRejection()
        XCTAssertFalse(sut.proxyRejectedSubscription)
        XCTAssertEqual(sut.displayedLimit(storeKitIsPro: true), NetworkConfig.proDailyLimit)
    }

    // MARK: - Helpers

    private static func response(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://ai.saydo.org/v1/todo-extractions")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
