import XCTest
import SwiftData
@testable import VoiceTodo

/// TodoItem.reminderTimes 编解码 + 内存缓存行为测试。
///
/// 缓存语义:对象从库中物化(SwiftData 不走自定义 init)时 cache 为 nil,
/// 首次 getter 触发解码;坏数据按无提醒降级并显式记日志,不崩溃。
final class TodoItemReminderTimesTests: XCTestCase {
    /// init 带 reminderTimes → getter 原样返回;空数组与 nil 对外都呈现 nil。
    func testInitRoundtripAndEmptyNormalization() {
        let withTimes = TodoItem(title: "交房租", reminderTimes: ["15:00", "17:00"])
        XCTAssertEqual(withTimes.reminderTimes, ["15:00", "17:00"])

        let empty = TodoItem(title: "交房租", reminderTimes: [])
        XCTAssertNil(empty.reminderTimes)

        let none = TodoItem(title: "交房租")
        XCTAssertNil(none.reminderTimes)
    }

    /// setter 写入 → getter 读回;置 nil 清空。
    func testSetterRoundtrip() {
        let item = TodoItem(title: "交房租")
        item.reminderTimes = ["19:00"]
        XCTAssertEqual(item.reminderTimes, ["19:00"])

        item.reminderTimes = nil
        XCTAssertNil(item.reminderTimes)
        XCTAssertNil(item.reminderTimesRaw)
    }

    /// 从库物化的对象(缓存未预热)走解码路径,值正确返回。
    func testFetchedItemDecodesRawLazily() throws {
        let container = try makeInMemoryContainer()
        let seed = ModelContext(container)
        seed.insert(TodoItem(title: "交房租", reminderTimes: ["15:00", "17:00"]))
        try seed.save()

        // 新 context 强制重新物化,排除对象缓存
        let fresh = ModelContext(container)
        let fetched = try XCTUnwrap(try fresh.fetch(FetchDescriptor<TodoItem>()).first)
        XCTAssertEqual(fetched.reminderTimes, ["15:00", "17:00"])
    }

    /// 库里是坏 JSON(历史脏数据)→ getter 返回 nil 不崩溃;后续 setter 写入仍可用。
    func testMalformedRawDegradesToNilAndRecovers() throws {
        let container = try makeInMemoryContainer()
        let seed = ModelContext(container)
        let item = TodoItem(title: "交房租", reminderTimes: ["15:00"])
        seed.insert(item)
        try seed.save()

        // 直接污染 raw,模拟历史脏数据(正常代码路径永远只写合法 JSON)
        item.reminderTimesRaw = "not-json{"
        try seed.save()

        let fresh = ModelContext(container)
        let fetched = try XCTUnwrap(try fresh.fetch(FetchDescriptor<TodoItem>()).first)
        XCTAssertNil(fetched.reminderTimes, "坏 JSON 应降级为 nil 而不是崩溃")

        // 降级不永久:重新写入合法值后可恢复
        fetched.reminderTimes = ["08:30"]
        XCTAssertEqual(fetched.reminderTimes, ["08:30"])
    }

    // MARK: - Helpers

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TodoItem.self, configurations: config)
    }
}
