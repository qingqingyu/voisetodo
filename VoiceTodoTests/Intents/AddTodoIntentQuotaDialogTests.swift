import XCTest
@testable import VoiceTodo

/// `AddTodoIntent.quotaExhaustedDialog` 三分流的分支覆盖。
///
/// 背景（2026-10-07 代理拒订阅修复的 Siri 侧收口）：App 内配额耗尽 toast 已按
/// `proxyRejectedSubscription` 分流「订阅验证未通过」，但 Siri 路径没有
/// `QuotaUsage` 实例可读（intent 进程一次性调用、quotaProvider 有意留空），
/// 原实现恒口播「今日免费额度已用完」——被拒订阅用户听不到恢复购买出口，
/// Pro 用户撞 Pro 上限也听到「免费」字样。本组测试锁住用错误自带 tier +
/// 凭证是否随请求携带做出的同口径分流。
final class AddTodoIntentQuotaDialogTests: XCTestCase {

    /// 带了凭证仍按 free 计 = 订阅被代理拒（验签失败/宽限期/退款）：
    /// 口播恢复购买出口，不谎称「免费额度用完」。
    func testCarriedJWSWithFreeTierMeansRejectedSubscription() {
        XCTAssertEqual(
            AddTodoIntent.quotaExhaustedDialog(tier: "free", carriedSubscriptionJWS: true),
            .subscriptionRejected
        )
    }

    /// 按 pro 计的用户撞 Pro 上限：不口播「免费」字样（携带与否都按代理口径判）。
    func testProTierUsesProExhaustedWording() {
        XCTAssertEqual(
            AddTodoIntent.quotaExhaustedDialog(tier: "pro", carriedSubscriptionJWS: true),
            .proExhausted
        )
        XCTAssertEqual(
            AddTodoIntent.quotaExhaustedDialog(tier: "pro", carriedSubscriptionJWS: false),
            .proExhausted
        )
    }

    /// 真免费用户（未携带凭证、按 free 计）维持免费口径。
    func testFreeUserKeepsFreeWording() {
        XCTAssertEqual(
            AddTodoIntent.quotaExhaustedDialog(tier: "free", carriedSubscriptionJWS: false),
            .freeExhausted
        )
    }

    /// 未知档位值（如未来代理新增 tier）即使带了凭证也不判「被拒」——与 App 侧
    /// `QuotaUsageTests.testUnknownPlanValueIsNotExplicitFreeRejection` 同口径：
    /// 只有代理明确按 free 计才算拒绝表态，未知值只回落免费文案，不谎报
    /// 「订阅验证未通过」。
    func testUnknownTierIsNotTreatedAsRejection() {
        XCTAssertEqual(
            AddTodoIntent.quotaExhaustedDialog(tier: "team", carriedSubscriptionJWS: true),
            .freeExhausted
        )
    }
}
