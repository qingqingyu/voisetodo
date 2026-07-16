import Foundation
import UserNotifications

/// 周回顾通知调度——每周一早上提醒用户查看上周完成情况。
/// 独立于待办到点提醒,用单独 identifier 避免 reconcile 误删。
enum ReviewNotificationScheduler {
    static let weeklyIdentifier = "voicetodo.review.weekly"

    /// 排程每周一 9:00 的回顾通知(repeats)。权限未授予时静默跳过。
    static func scheduleWeekly() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            VoiceTodoLog.notification.info("review_notification.skip reason=not_authorized")
            return
        }

        // 先移除旧的(幂等)
        center.removePendingNotificationRequests(withIdentifiers: [weeklyIdentifier])

        var dc = DateComponents()
        dc.hour = 9
        dc.minute = 0
        dc.weekday = 2  // 周一(Calendar weekday: 2=Monday)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "review.notification.title")
        content.body = String(localized: "review.notification.body")
        content.sound = .default
        content.userInfo = ["deepLink": "review"]

        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        let request = UNNotificationRequest(
            identifier: weeklyIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            VoiceTodoLog.notification.info("review_notification.scheduled weekly Monday 9:00")
        } catch {
            VoiceTodoLog.notification.error("review_notification.schedule_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    /// 取消周回顾通知(用户关闭时调用)。
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [weeklyIdentifier])
        VoiceTodoLog.notification.info("review_notification.cancelled")
    }
}
