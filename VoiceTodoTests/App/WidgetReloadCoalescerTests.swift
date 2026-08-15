import XCTest
@testable import VoiceTodo

/// 线程安全的 reload 计数器——reload closure 是 @Sendable 同步调用，用 NSLock 保护。
private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var rawCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return rawCount
    }

    func increment() {
        lock.lock()
        rawCount += 1
        lock.unlock()
    }
}

final class WidgetReloadCoalescerTests: XCTestCase {
    /// 去抖窗口内的连发请求合并为一次 reload。
    func testBurstSchedulesCoalesceToSingleReload() async throws {
        let counter = ReloadCounter()
        let coalescer = WidgetReloadCoalescer(window: 0.05, reload: { counter.increment() })

        for _ in 0..<10 {
            await coalescer.schedule()
        }

        // 等待窗口（50ms）过去 + reload 执行
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.count, 1)
    }

    /// 去抖窗口之后的新请求应触发新一次 reload（窗口会重置，不会永久吞请求）。
    func testSchedulesOutsideWindowEachReload() async throws {
        let counter = ReloadCounter()
        let coalescer = WidgetReloadCoalescer(window: 0.05, reload: { counter.increment() })

        await coalescer.schedule()
        try await Task.sleep(nanoseconds: 200_000_000)
        await coalescer.schedule()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(counter.count, 2)
    }

    /// flushNow 立即触发 pending 的 reload，且清掉 pending——不会再补第二枪。
    func testFlushNowFiresImmediatelyAndClearsPending() async throws {
        let counter = ReloadCounter()
        // 窗口放大到 5s：不 flush 就绝不该 reload
        let coalescer = WidgetReloadCoalescer(window: 5.0, reload: { counter.increment() })

        await coalescer.schedule()
        try await Task.sleep(nanoseconds: 50_000_000)
        await coalescer.flushNow()
        XCTAssertEqual(counter.count, 1)

        // pending 已清：再等也不会出现第二次
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.count, 1)
    }

    /// 无 pending 时 flushNow 不动作——不白白消耗 reload 预算。
    func testFlushNowWithoutPendingDoesNotReload() async throws {
        let counter = ReloadCounter()
        let coalescer = WidgetReloadCoalescer(window: 0.05, reload: { counter.increment() })

        await coalescer.flushNow()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(counter.count, 0)
    }
}
