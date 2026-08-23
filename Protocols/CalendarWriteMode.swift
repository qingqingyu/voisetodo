import Foundation

enum CalendarWriteMode: String, CaseIterable, Identifiable {
    case appOnly
    case appAndSystemCalendar

    static let storageKey = "calendarWriteMode"

    /// 「首次确认带日期待办后的一次性日历同步询问」是否已弹过(2026-08-23 决策:
    /// 删 onboarding 日历页,询问延后到用户刚看到日期被识别出来的那一刻)。
    /// 弹过一次(无论用户选开启还是暂不)即永久置位;真正的开关在设置页。
    static let deferredAskShownKey = "calendarSyncDeferredAskShown"

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .appOnly:
            return String(localized: "settings.calendar_write.app_only")
        case .appAndSystemCalendar:
            return String(localized: "settings.calendar_write.app_and_system")
        }
    }

    static var current: CalendarWriteMode {
        let rawValue = UserDefaults.standard.string(forKey: storageKey)
        return CalendarWriteMode(rawValue: rawValue ?? "") ?? .appOnly
    }
}
