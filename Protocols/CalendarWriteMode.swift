import Foundation

enum CalendarWriteMode: String, CaseIterable, Identifiable {
    case appOnly
    case appAndSystemCalendar

    static let storageKey = "calendarWriteMode"

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
