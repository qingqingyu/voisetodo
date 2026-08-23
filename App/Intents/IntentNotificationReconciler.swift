import Foundation
import SwiftData
import UserNotifications

/// 单条待办的局部通知对账器,供 intent 进程(Widget Extension / Siri)使用。
///
/// **为什么需要它**:App 进程的 `TodoNotificationSync` 通过订阅 `TodoStore.$todos`
/// 驱动通知对账,但 intent 进程写库走自己的 `ModelContext`,App 的 `store.todos`
/// 不会发布——要等 App 下次回前台 `refreshIfStale()` 才对账。窗口期内:
/// 已完成的待办,其已排提醒不会被取消(照响);反勾恢复的待办,提醒不会补排。
///
/// **做了什么**:移除该待办的全部已排通知(`todo-reminder-<uuid>` 前缀,覆盖
/// 一次性/重复/有界展开全部标识变体),再按其**最新落库状态**用 `NotificationPlanner`
/// 重排。取消、恢复、幂等一次覆盖。
///
/// **与全量对账的关系**:这里是点修复;App 回前台后
/// `LocalNotificationScheduler.reconcile`(清全部 + 重排)仍是兜底,两者收敛到
/// 同一终态。即使本对账在扩展进程失败(如系统限制),最坏退化为修复前的行为。
extension PlannedNotification {
    /// 构造 `UNNotificationRequest`——内容(title/body/sound/todoID 深链 userInfo)
    /// 与 `LocalNotificationScheduler` 的内联构造保持同构(那边按约定不动);
    /// 改这里只影响 intent 进程对账路径,不会同步改 App 路径。
    var notificationRequest: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        content.userInfo = ["todoID": todoID.uuidString]
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: repeats)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}

enum IntentNotificationReconciler {
    /// 通知中心的可注入端口。生产走 `UNUserNotificationCenter`;测试注入 spy,
    /// 不碰真实通知权限与待发队列。
    protocol Port {
        func pendingIdentifiers() async -> [String]
        func removePending(identifiers: [String]) async
        func authorizationStatus() async -> UNAuthorizationStatus
        func add(_ notification: PlannedNotification) async throws
    }

    /// 对账指定待办的通知(按其当前落库状态)。
    /// - Parameters:
    ///   - todoID: 待办 ID(mutation 已落库后调用)。
    ///   - context: intent 进程的 ModelContext(用于 re-fetch 最新状态)。
    ///   - enabled: 「到点提醒」总开关。调用方按进程解析:App 进程(Siri)读
    ///     `UserDefaults.standard`;Widget 扩展进程读 App Group 镜像
    ///     (见 `AppGroupConfig.mirroredNotificationsEnabled`)。
    ///   - port: 通知端口。
    static func reconcile(todoID: UUID, context: ModelContext, enabled: Bool, port: Port) async {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.id == todoID }
        )
        descriptor.fetchLimit = 1
        let item: TodoItem?
        do {
            item = try context.fetch(descriptor).first
        } catch {
            VoiceTodoLog.notification.error("intent.reconcile.fetch_failed todoID=\(todoID.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return
        }
        guard let item else {
            VoiceTodoLog.notification.warning("intent.reconcile.todo_not_found todoID=\(todoID.uuidString, privacy: .public)")
            return
        }
        await reconcile(todo: item.toData(), enabled: enabled, port: port)
    }

    /// 对账单条待办的通知。
    /// 步骤:①移除该待办全部已排通知;②权限已授权且总开关开启时,按最新状态重排。
    /// 权限 notDetermined/denied 时只删不加——notDetermined 只能由 App 进程申请
    /// (扩展进程 requestAuthorization 无效),denied 时 App 全量对账会清空。
    static func reconcile(todo: TodoItemData, enabled: Bool, now: Date = Date(), port: Port) async {
        let prefix = NotificationPlanner.identifierPrefix + todo.id.uuidString
        let pending = await port.pendingIdentifiers()
        let ours = pending.filter { $0.hasPrefix(prefix) }
        if !ours.isEmpty {
            await port.removePending(identifiers: ours)
            VoiceTodoLog.notification.info("intent.reconcile.removed todoID=\(todo.id.uuidString, privacy: .public) count=\(ours.count, privacy: .public)")
        }

        let status = await port.authorizationStatus()
        // 与 LocalNotificationScheduler 的 default 分支同口径:authorized/provisional/ephemeral 可排。
        guard enabled, status != .notDetermined, status != .denied else { return }

        let planned = NotificationPlanner.plannedNotifications(from: [todo], now: now, enabled: enabled)
        for notification in planned {
            do {
                try await port.add(notification)
            } catch {
                // 单条 add 失败不中断其余:记录后继续,App 回前台全量对账兜底收敛。
                VoiceTodoLog.notification.error("intent.reconcile.add_failed id=\(notification.identifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
        if !planned.isEmpty {
            VoiceTodoLog.notification.info("intent.reconcile.added todoID=\(todo.id.uuidString, privacy: .public) count=\(planned.count, privacy: .public)")
        }
    }
}

/// 生产端口:直连 `UNUserNotificationCenter`。
/// 只做查询/移除/新增,不做 `requestAuthorization`(扩展进程不允许,由 App 进程申请)。
struct UNNotificationPort: IntentNotificationReconciler.Port {
    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    func removePending(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func add(_ notification: PlannedNotification) async throws {
        try await UNUserNotificationCenter.current().add(notification.notificationRequest)
    }
}
