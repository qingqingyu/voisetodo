import XCTest
import UserNotifications
@testable import VoiceTodo

/// `IntentNotificationReconciler` 局部通知对账的分支覆盖(纯 spy,不碰真实通知)。
/// 背景见类型注释:widget/Siri 勾选后 App 进程 `$todos` 不发布,窗口期内提醒
/// 不取消/不恢复,由本对账器在 intent 进程内就地收敛。
final class IntentNotificationReconcilerTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeDueTomorrow(hour: Int) throws -> Date {
        let today = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()))
        return try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
    }

    /// 已完成的一次性待办:移除其已排通知,不重排(planner 跳过 completed)。
    func testCompletedOneShotRemovesPendingWithoutReAdd() async throws {
        let id = UUID()
        let todo = TodoItemData(
            id: id,
            title: "带提醒",
            dueDate: try makeDueTomorrow(hour: 8),
            hasDueTime: true,
            isCompleted: true
        )
        let spy = SpyNotificationPort(pending: [Self.identifier(of: id)])

        await IntentNotificationReconciler.reconcile(todo: todo, enabled: true, port: spy)

        XCTAssertEqual(spy.removed, [Self.identifier(of: id)])
        XCTAssertTrue(spy.added.isEmpty)
    }

    /// 反勾恢复(未完成)的一次性待办:移除旧通知后按最新状态重排。
    func testUncompletedOneShotRemovesThenReAdds() async throws {
        let id = UUID()
        let due = try makeDueTomorrow(hour: 8)
        let todo = TodoItemData(
            id: id,
            title: "带提醒",
            dueDate: due,
            hasDueTime: true,
            isCompleted: false
        )
        let spy = SpyNotificationPort(pending: [Self.identifier(of: id)])

        await IntentNotificationReconciler.reconcile(
            todo: todo, enabled: true, now: due.addingTimeInterval(-3600), port: spy
        )

        XCTAssertEqual(spy.removed, [Self.identifier(of: id)])
        XCTAssertEqual(spy.added.map(\.identifier), [Self.identifier(of: id)])
        XCTAssertFalse(spy.added[0].repeats)
    }

    /// 全局开关 OFF:只移除不重排(镜像语义,见 AppGroupConfig)。
    func testDisabledGlobalToggleRemovesOnly() async throws {
        let id = UUID()
        let todo = TodoItemData(
            id: id,
            title: "带提醒",
            dueDate: try makeDueTomorrow(hour: 8),
            hasDueTime: true,
            isCompleted: false
        )
        let spy = SpyNotificationPort(pending: [Self.identifier(of: id)])

        await IntentNotificationReconciler.reconcile(todo: todo, enabled: false, port: spy)

        XCTAssertEqual(spy.removed, [Self.identifier(of: id)])
        XCTAssertTrue(spy.added.isEmpty)
    }

    /// 权限未决:只移除不重排、不申请(notDetermined 只能由 App 进程申请)。
    func testNotDeterminedAuthorizationRemovesOnly() async throws {
        let id = UUID()
        let todo = TodoItemData(
            id: id,
            title: "带提醒",
            dueDate: try makeDueTomorrow(hour: 8),
            hasDueTime: true,
            isCompleted: false
        )
        let spy = SpyNotificationPort(pending: [Self.identifier(of: id)], status: .notDetermined)

        await IntentNotificationReconciler.reconcile(todo: todo, enabled: true, port: spy)

        XCTAssertEqual(spy.removed, [Self.identifier(of: id)])
        XCTAssertTrue(spy.added.isEmpty)
    }

    /// 只动本待办的通知:其他待办的标识(含同前缀不同 uuid)不受影响。
    func testOnlyTouchesThisTodosIdentifiers() async throws {
        let id = UUID()
        let other = UUID()
        let todo = TodoItemData(
            id: id,
            title: "带提醒",
            dueDate: try makeDueTomorrow(hour: 8),
            hasDueTime: true,
            isCompleted: true
        )
        // 同前缀"族"内的变体(有界展开 -d / weekly -w)与别人的一并混入,验证只删自己的。
        let expanded = Self.identifier(of: id) + "-d20260823"
        let pending = [Self.identifier(of: other), expanded, Self.identifier(of: id)]
        let spy = SpyNotificationPort(pending: pending)

        await IntentNotificationReconciler.reconcile(todo: todo, enabled: true, port: spy)

        XCTAssertEqual(spy.removed, [expanded, Self.identifier(of: id)])
    }

    /// 重复任务:base 未完成(occurrence 模型),planner 仍产出 repeating 触发器——
    /// 勾掉当天后提醒保持(与 App 内路径同口径,见走查报告"发现 2")。
    func testRecurringTodoKeepsRepeatingPlan() async throws {
        let id = UUID()
        let todo = TodoItemData(
            id: id,
            title: "每天吃药",
            dueDate: try makeDueTomorrow(hour: 8),
            hasDueTime: true,
            recurrenceRule: RecurrenceRule(frequency: .daily)
        )
        let spy = SpyNotificationPort(pending: [Self.identifier(of: id)])

        await IntentNotificationReconciler.reconcile(todo: todo, enabled: true, port: spy)

        XCTAssertEqual(spy.removed, [Self.identifier(of: id)])
        XCTAssertEqual(spy.added.map(\.identifier), [Self.identifier(of: id)])
        XCTAssertTrue(spy.added[0].repeats)
    }

    // MARK: - 开关镜像(AppGroupConfig)

    func testNotificationsEnabledMirrorRoundTripAndFallback() throws {
        let defaults = try makeTemporaryDefaults()

        // 从未写入 → 回退 true(= 默认开)
        XCTAssertTrue(AppGroupConfig.mirroredNotificationsEnabled(defaults: defaults))

        AppGroupConfig.mirrorNotificationsEnabled(false, defaults: defaults)
        XCTAssertFalse(AppGroupConfig.mirroredNotificationsEnabled(defaults: defaults))

        AppGroupConfig.mirrorNotificationsEnabled(true, defaults: defaults)
        XCTAssertTrue(AppGroupConfig.mirroredNotificationsEnabled(defaults: defaults))
    }

    /// 启动同步:standard 的值(含缺省回退)灌进镜像。
    func testSyncMirrorFromStandardFillsMirror() throws {
        let standard = try makeTemporaryDefaults()
        let mirror = try makeTemporaryDefaults()

        // standard 从未写入 → 同步缺省 true
        AppGroupConfig.syncNotificationsEnabledMirrorFromStandard(standard: standard, mirrorDefaults: mirror)
        XCTAssertTrue(AppGroupConfig.mirroredNotificationsEnabled(defaults: mirror))

        // standard = false → 镜像跟随(兜住老用户已拨 OFF 的窗口)
        standard.set(false, forKey: NotificationPlanner.enabledDefaultsKey)
        AppGroupConfig.syncNotificationsEnabledMirrorFromStandard(standard: standard, mirrorDefaults: mirror)
        XCTAssertFalse(AppGroupConfig.mirroredNotificationsEnabled(defaults: mirror))
    }

    // MARK: - Helpers

    private static func identifier(of id: UUID) -> String {
        NotificationPlanner.identifierPrefix + id.uuidString
    }

    private func makeTemporaryDefaults() throws -> UserDefaults {
        let suiteName = "VoiceTodoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// 通知端口 spy:记录移除/新增调用,不碰真实通知中心。
private final class SpyNotificationPort: IntentNotificationReconciler.Port {
    let pending: [String]
    let status: UNAuthorizationStatus
    private(set) var removed: [String] = []
    private(set) var added: [PlannedNotification] = []

    init(pending: [String], status: UNAuthorizationStatus = .authorized) {
        self.pending = pending
        self.status = status
    }

    func pendingIdentifiers() async -> [String] { pending }
    func removePending(identifiers: [String]) async { removed.append(contentsOf: identifiers) }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func add(_ notification: PlannedNotification) async throws { added.append(notification) }
}
