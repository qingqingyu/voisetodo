import Foundation
import UserNotifications

/// 到点提醒的排程能力（协议便于注入 no-op 于测试）。
protocol NotificationScheduling: AnyObject {
    /// 用"应存在的通知集合"对账系统待发通知：多退少补。
    func reconcile(notifications: [PlannedNotification]) async
}

/// 基于 `UNUserNotificationCenter` 的本地通知调度器。
/// 权限懒申请（首次有可排提醒时才弹）；对账式排程，天然处理 iOS 64 条待发上限（上游已截断）。
final class LocalNotificationScheduler: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate {
    /// 点击通知打开对应待办的回调（由 App 注入，路由到深链）。
    var onOpenTodo: ((UUID) -> Void)?
    /// 点击回顾通知打开回顾页的回调（由 App 注入）。
    var onOpenReview: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    func reconcile(notifications: [PlannedNotification]) async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // 没有要排的提醒就不打扰用户，等首次真有带时间待办再申请。
            guard !notifications.isEmpty else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            VoiceTodoLog.notification.info("notification.authorization.requested granted=\(granted)")
            guard granted else {
                await clearOurPending()
                return
            }
        case .denied:
            await clearOurPending()
            VoiceTodoLog.notification.info("notification.reconcile.skipped reason=denied")
            return
        default:
            break // authorized / provisional / ephemeral
        }

        await clearOurPending()
        var scheduled = 0
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            if let body = notification.body { content.body = body }
            content.sound = .default
            content.userInfo = ["todoID": notification.todoID.uuidString]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: notification.dateComponents,
                repeats: notification.repeats
            )
            let request = UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                VoiceTodoLog.notification.error("notification.add.failed id=\(notification.identifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
        VoiceTodoLog.notification.info("notification.reconcile.done requested=\(notifications.count) scheduled=\(scheduled)")
    }

    private func clearOurPending() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(NotificationPlanner.identifierPrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也展示 banner + 声音。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知 → 路由打开对应待办或回顾页。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo["todoID"] as? String,
           let todoID = UUID(uuidString: raw) {
            let handler = onOpenTodo
            DispatchQueue.main.async { handler?(todoID) }
        }
        if let deepLink = userInfo["deepLink"] as? String, deepLink == "review",
           let handler = onOpenReview {
            DispatchQueue.main.async { handler() }
        }
        completionHandler()
    }
}

/// 测试/UI 测试用的空实现：不申请权限、不排程。
final class NoopNotificationScheduler: NotificationScheduling {
    func reconcile(notifications: [PlannedNotification]) async {}
}
