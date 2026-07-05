import Foundation

/// 待办重复频率
enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
}

/// 待办重复规则。weekday 使用 Calendar 的 weekday 语义：1=周日，2=周一 ... 7=周六。
struct RecurrenceRule: Codable, Hashable, Sendable {
    var frequency: RecurrenceFrequency
    var weekdays: [Int]
    var dayOfMonth: Int?
    var endDate: Date?

    private enum CodingKeys: String, CodingKey {
        case frequency
        case weekdays
        case dayOfMonth
        case endDate
    }

    init(
        frequency: RecurrenceFrequency,
        weekdays: [Int] = [],
        dayOfMonth: Int? = nil,
        endDate: Date? = nil
    ) {
        self.frequency = frequency
        self.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        self.dayOfMonth = dayOfMonth.flatMap { (1...31).contains($0) ? $0 : nil }
        self.endDate = endDate.map { Calendar.current.startOfDay(for: $0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frequency = try container.decode(RecurrenceFrequency.self, forKey: .frequency)
        let weekdays = try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        let dayOfMonth = try container.decodeIfPresent(Int.self, forKey: .dayOfMonth)
        let endDate = try Self.decodeEndDate(from: container)

        self.init(
            frequency: frequency,
            weekdays: weekdays,
            dayOfMonth: dayOfMonth,
            endDate: endDate
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(dayOfMonth, forKey: .dayOfMonth)
        try container.encodeIfPresent(endDate, forKey: .endDate)
    }

    private static func decodeEndDate(from container: KeyedDecodingContainer<CodingKeys>) throws -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: .endDate) {
            return date
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: .endDate),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return parseEndDateString(raw)
    }

    private static func parseEndDateString(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullDateFormatter = DateFormatter()
        fullDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        fullDateFormatter.calendar = Calendar(identifier: .gregorian)
        fullDateFormatter.dateFormat = "yyyy-MM-dd"
        if let date = fullDateFormatter.date(from: text) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: text) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: text)
    }

    var isValid: Bool {
        switch frequency {
        case .daily:
            return true
        case .weekly:
            return !weekdays.isEmpty
        case .monthly:
            return dayOfMonth != nil
        }
    }

    func occurs(on date: Date, startDate: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        guard day >= start else { return false }
        if let endDate, day > calendar.startOfDay(for: endDate) {
            return false
        }

        switch frequency {
        case .daily:
            return true
        case .weekly:
            return weekdays.contains(calendar.component(.weekday, from: day))
        case .monthly:
            guard let dayOfMonth else { return false }
            return calendar.component(.day, from: day) == dayOfMonth
        }
    }

    var displayText: String {
        switch frequency {
        case .daily:
            return String(localized: "recurrence.daily")
        case .weekly:
            let names = weekdays.map { RecurrenceRule.shortWeekdayName($0) }.joined(separator: " ")
            return String(localized: "recurrence.weekly \(names)")
        case .monthly:
            return String(localized: "recurrence.monthly \(dayOfMonth ?? 1)")
        }
    }

    /// 带 end_date 的完整重复描述（用于 ConfirmSheet 用户校对）。
    /// 例：`recurrence.displayText` → "每天"；`recurrence.displayTextWithEndDate` → "每天 · 至 8月5日"。
    /// end_date nil 或解析失败时退化为 displayText。
    /// 翻译策略：用"至 M月D日"而不是"至 YYYY-MM-DD"，更符合中文口语习惯且更紧凑；
    /// 英文用 "until Mon D"。
    var displayTextWithEndDate: String {
        let base = displayText
        guard let endDate else { return base }
        let formatter = Self.cachedEndDateFormatter
        let endStr = formatter.string(from: endDate)
        let template = String(localized: "recurrence.with_end_date")
        return String(format: template, base, endStr)
    }

    /// 缓存的 endDate 格式化器——避免每次 view 重渲染都重建 DateFormatter。
    /// locale 跟随 Bundle.main.preferredLocalizations；用户改系统语言后下次进程启动会重新解析。
    private static let cachedEndDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        if let identifier = Bundle.main.preferredLocalizations.first(where: { $0 != "Base" }) {
            formatter.locale = Locale(identifier: identifier)
        }
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static func shortWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }
}
