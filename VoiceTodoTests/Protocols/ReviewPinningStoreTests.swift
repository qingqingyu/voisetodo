import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `ReviewPinningStore`(App Group UserDefaults 置顶集合)与
/// `ReviewPinningSort.pinnedFirst`(浮顶排序比较器)的验收(阶段 3,拍板 6)。
final class ReviewPinningStoreTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!
    private var store: ReviewPinningStore!

    override func setUp() {
        super.setUp()
        suiteName = "ReviewPinningStoreTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        store = ReviewPinningStore(defaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        store = nil
        super.tearDown()
    }

    // MARK: 读写

    func testSetAndReadRoundtrip() {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        store.setPinned(ids)
        XCTAssertEqual(store.pinnedIDs(), ids)
    }

    func testEmptyByDefault() {
        XCTAssertTrue(store.pinnedIDs().isEmpty)
    }

    func testOverwrite() {
        let first: Set<UUID> = [UUID(), UUID()]
        store.setPinned(first)
        let second: Set<UUID> = [UUID()]
        store.setPinned(second)
        XCTAssertEqual(store.pinnedIDs(), second)
    }

    func testPruneRemovesVanishedIDs() {
        let keep = UUID()
        let vanish = UUID()
        store.setPinned([keep, vanish])
        store.prune(existingIDs: [keep])
        XCTAssertEqual(store.pinnedIDs(), [keep])
        // 全存在时 prune 不动集合。
        store.prune(existingIDs: [keep])
        XCTAssertEqual(store.pinnedIDs(), [keep])
    }

    func testDirtyDataDegradesToEmpty() {
        suite.set(Data("not-json".utf8), forKey: ReviewPinningStore.pinnedIDsKey)
        XCTAssertTrue(store.pinnedIDs().isEmpty)
    }

    // MARK: 浮顶排序(读比较器,不动 sortOrder,拍板 6)

    func testPinnedFirstStablePartition() {
        let a = UUID(), c = UUID()
        let items = [
            TodoItemData(id: a, title: "a"),
            TodoItemData(id: UUID(), title: "b"),
            TodoItemData(id: c, title: "c"),
        ]
        let sorted = ReviewPinningSort.pinnedFirst(items, pinned: [c])
        XCTAssertEqual(sorted.map(\.title), ["c", "a", "b"])
        // pinned 为空 → 原样返回(零开销路径)。
        XCTAssertEqual(ReviewPinningSort.pinnedFirst(items, pinned: []).map(\.title), ["a", "b", "c"])
    }
}
