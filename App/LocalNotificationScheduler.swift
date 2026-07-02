import Foundation
import UserNotifications

/// 到点提醒的排程能力（协议便于注入 no-op 于测试）。
protocol NotificationScheduling: AnyObject {
    /// 用"应存在的提醒集合"对账系统待发通知：多退少补。
    func reconcile(reminders: [PlannedReminder]) async
}

/// 基于 `UNUserNotificationCenter` 的本地通知调度器。
/// 权限懒申请（首次有可排提醒时才弹）；对账式排程，天然处理 iOS 64 条待发上限（上游已截断）。
final class LocalNotificationScheduler: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate {
    /// 本 App 排的通知标识前缀，用于对账时只清理自己的请求。
    static let identifierPrefix = "todo-reminder-"

    /// 点击通知打开对应待办的回调（由 App 注入，路由到深链）。
    var onOpenTodo: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()

    func reconcile(reminders: [PlannedReminder]) async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // 没有要排的提醒就不打扰用户，等首次真有带时间待办再申请。
            guard !reminders.isEmpty else { return }
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
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            if let body = reminder.body { content.body = body }
            content.sound = .default
            content.userInfo = ["todoID": reminder.id.uuidString]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.identifierPrefix + reminder.id.uuidString,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                VoiceTodoLog.notification.error("notification.add.failed todoID=\(reminder.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
        VoiceTodoLog.notification.info("notification.reconcile.done requested=\(reminders.count) scheduled=\(scheduled)")
    }

    private func clearOurPending() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
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

    /// 点击通知 → 路由打开对应待办。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let raw = response.notification.request.content.userInfo["todoID"] as? String,
           let todoID = UUID(uuidString: raw) {
            let handler = onOpenTodo
            DispatchQueue.main.async { handler?(todoID) }
        }
        completionHandler()
    }
}

/// 测试/UI 测试用的空实现：不申请权限、不排程。
final class NoopNotificationScheduler: NotificationScheduling {
    func reconcile(reminders: [PlannedReminder]) async {}
}
