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
        ]))

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
        ]))

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
        ]))

        XCTAssertEqual(sut.limit, 100)
    }

    // MARK: - 无额度头：保留本地估算

    func testNoQuotaHeadersKeepsLocalEstimate() {
        let sut = QuotaUsage()
        sut.applyQuotaHeaders(from: Self.response(headers: ["Content-Type": "application/json"]))

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
        ]))
        sut.recordLocalUsageIncrement()

        XCTAssertEqual(sut.used, 5, "权威值到位后，本地估算不应再自增")
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
