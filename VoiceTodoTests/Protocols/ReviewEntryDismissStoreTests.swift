import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class ReviewEntryDismissStoreTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!
    private var store: ReviewEntryDismissStore!

    override func setUp() {
        super.setUp()
        suiteName = "ReviewEntryDismissStoreTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        store = ReviewEntryDismissStore(defaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Store

    /// 从未关闭过 → nil(卡常驻,不冷却)。
    func testDefaultsToNilWhenNeverDismissed() {
        XCTAssertNil(store.dismissedAt())
    }

    /// 写入后读回一致(精确到秒;UserDefaults 的 Date 存取无损)。
    func testMarkDismissedPersistsDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.markDismissed(date)
        XCTAssertEqual(store.dismissedAt(), date)
    }

    /// 覆写更新:再次关闭取最新时刻,冷却窗口自新时刻重起算。
    func testMarkDismissedOverwritesWithLatest() {
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_086_400)
        store.markDismissed(older)
        store.markDismissed(newer)
        XCTAssertEqual(store.dismissedAt(), newer)
    }

    /// defaults 注入 nil(容器不可用):读降级为 nil、写不崩溃——展示偏好
    /// 不阻塞渲染,失败已在 store 内显式记 warning 日志。
    func testNilDefaultsDegradesGracefully() {
        let degraded = ReviewEntryDismissStore(defaults: nil)
        XCTAssertNil(degraded.dismissedAt())
        degraded.markDismissed()  // 不崩溃即通过
        XCTAssertNil(degraded.dismissedAt())
    }

    // MARK: - 冷却判定(纯函数)

    /// 每天恒定 86400s,避免魔法数。
    private let day: TimeInterval = 24 * 60 * 60
    /// 固定锚点(UTC 字面量),判定只做时间差,与本地时区/夏令时无关。
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 双锚点皆 nil(从未复盘、从未关闭)→ 不冷却,卡常驻。
    func testNoAnchorsNotCoolingDown() {
        XCTAssertFalse(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: nil, manuallyDismissedAt: nil,
            now: now, window: 7 * day
        ))
    }

    /// 距上次复盘不足 7 天 → 冷却(原有口径不回归)。
    func testLastReviewWithinWindowCoolingDown() {
        XCTAssertTrue(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: now.addingTimeInterval(-3 * day),
            manuallyDismissedAt: nil,
            now: now, window: 7 * day
        ))
    }

    /// 距上次复盘超窗、但距手动关闭不足 7 天 → 冷却(本次新增锚点)。
    func testDismissalWithinWindowCoolingDown() {
        XCTAssertTrue(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: now.addingTimeInterval(-10 * day),
            manuallyDismissedAt: now.addingTimeInterval(-3 * day),
            now: now, window: 7 * day
        ))
    }

    /// 双锚点取较近者:复盘近(2 天)而关闭远(20 天)→ 仍由复盘锚定冷却;
    /// 期间再复盘重起算的语义即「较近者说了算」。
    func testNearestAnchorGoverns() {
        XCTAssertTrue(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: now.addingTimeInterval(-2 * day),
            manuallyDismissedAt: now.addingTimeInterval(-20 * day),
            now: now, window: 7 * day
        ))
    }

    /// 两锚点都超窗(手动关闭 8 天前、复盘 30 天前)→ 不冷却,卡回来。
    func testBothAnchorsBeyondWindowNotCoolingDown() {
        XCTAssertFalse(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: now.addingTimeInterval(-30 * day),
            manuallyDismissedAt: now.addingTimeInterval(-8 * day),
            now: now, window: 7 * day
        ))
    }

    /// 恰好满 7 天 → 不冷却(< 严格判定,第 7 天结束时点即恢复)。
    func testExactlyAtWindowBoundaryNotCoolingDown() {
        XCTAssertFalse(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: nil,
            manuallyDismissedAt: now.addingTimeInterval(-7 * day),
            now: now, window: 7 * day
        ))
    }

    /// 锚点在未来(时钟回拨/设备时间跳变)→ 视为冷却中,宁可不显示也不打扰。
    func testFutureAnchorTreatedAsCoolingDown() {
        XCTAssertTrue(ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: nil,
            manuallyDismissedAt: now.addingTimeInterval(2 * day),
            now: now, window: 7 * day
        ))
    }
}
