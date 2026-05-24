import Foundation

extension CodingUserInfoKey {
    static let recurrenceReferenceDate = CodingUserInfoKey(rawValue: "VoiceTodo.recurrenceReferenceDate")!
    static let recurrenceCalendar = CodingUserInfoKey(rawValue: "VoiceTodo.recurrenceCalendar")!
}

// MARK: - 枚举类型

/// 优先级
enum Priority: String, Codable, CaseIterable {
    case high
    case normal
}

/// 待办分类
enum TodoCategory: String, Codable, CaseIterable {
    case work     // 工作
    case study    // 学习
    case life     // 生活
    case health   // 健康
    case finance  // 财务
    case social   // 社交
    case other    // 其他

    var emoji: String {
        switch self {
        case .work: return "💼"
        case .study: return "📚"
        case .life: return "🏠"
        case .health: return "💪"
        case .finance: return "💰"
        case .social: return "👥"
        case .other: return "📌"
        }
    }

    var displayName: String {
        switch self {
        case .work: return String(localized: "category.work")
        case .study: return String(localized: "category.study")
        case .life: return String(localized: "category.life")
        case .health: return String(localized: "category.health")
        case .finance: return String(localized: "category.finance")
        case .social: return String(localized: "category.social")
        case .other: return String(localized: "category.other")
        }
    }
}

// MARK: - 重复规则

/// 待办重复频率
enum RecurrenceFrequency: String, Codable, CaseIterable {
    case daily
    case weekly
    case monthly
}

/// 待办重复规则。weekday 使用 Calendar 的 weekday 语义：1=周日，2=周一 ... 7=周六。
struct RecurrenceRule: Codable, Hashable {
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
        self.weekdays = weekdays
            .filter { (1...7).contains($0) }
            .uniqued()
            .sorted()
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

/// 日历中某一天实际出现的一条待办。
struct TodoOccurrenceData: Identifiable, Codable, Hashable {
    let todo: TodoItemData
    let occurrenceDate: Date
    var isCompleted: Bool

    var id: String {
        "\(todo.id.uuidString)-\(Self.dayKey(for: occurrenceDate))"
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: date))
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

enum WidgetTodoFilter {
    static func visibleTodos(
        from items: [TodoItemData],
        completionKeys: Set<String>,
        today: Date,
        limit: Int,
        calendar: Calendar = .current
    ) -> [TodoItemData] {
        guard limit > 0 else { return [] }

        let day = calendar.startOfDay(for: today)
        var scheduled: [TodoItemData] = []
        var unscheduled: [TodoItemData] = []

        for item in items {
            var data = item
            if let rule = data.recurrenceRule {
                guard rule.occurs(on: day, startDate: data.dueDate ?? data.createdAt, calendar: calendar) else {
                    continue
                }
                let key = "\(data.id.uuidString)-\(TodoOccurrenceData.dayKey(for: day, calendar: calendar))"
                guard !completionKeys.contains(key) else { continue }
                data.isCompleted = false
                scheduled.append(data)
                continue
            }
            guard !data.isCompleted else { continue }
            if data.dueDate == nil {
                unscheduled.append(data)
                continue
            }
            if calendar.isDate(data.dueDate ?? day, inSameDayAs: day) {
                scheduled.append(data)
            }
        }

        return Array((scheduled + unscheduled).prefix(limit))
    }
}

// MARK: - AI 提取结果（从 API 返回的结构）

/// 单条提取的待办（AI 返回格式）
struct ExtractedTodo: Identifiable, Codable {
    let id: UUID
    var title: String
    var detail: String
    var dueHint: String?
    var recurrenceRule: RecurrenceRule?
    var priority: Priority
    var categoryHint: TodoCategory

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case dueHint
        case recurrenceRule
        case priority
        case categoryHint
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        dueHint: String? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        priority: Priority = .normal,
        categoryHint: TodoCategory = .other
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = Self.sanitizeDueHint(dueHint)
        self.recurrenceRule = RecurrenceRuleResolver.ruleWithInferredEndDate(
            recurrenceRule,
            dueHint: dueHint,
            title: title,
            detail: detail
        )
        self.priority = priority
        self.categoryHint = categoryHint
    }

    /// 过滤 AI 可能返回的伪 null 值（如 "null"、"None"、"none"）
    private static func sanitizeDueHint(_ hint: String?) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty,
              hint.lowercased() != "null",
              hint.lowercased() != "none" else {
            return nil
        }
        return hint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let referenceDate = decoder.userInfo[.recurrenceReferenceDate] as? Date ?? Date()
        let calendar = decoder.userInfo[.recurrenceCalendar] as? Calendar ?? .current
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        let rawDueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
        dueHint = Self.sanitizeDueHint(rawDueHint)
        if container.contains(.recurrenceRule) {
            let decodedRule = try? container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrenceRule)
            if let rule = decodedRule ?? nil, rule.isValid {
                recurrenceRule = RecurrenceRuleResolver.ruleWithInferredEndDate(
                    rule,
                    dueHint: dueHint,
                    title: title,
                    detail: detail,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
            } else {
                recurrenceRule = nil
            }
        } else {
            recurrenceRule = RecurrenceRuleResolver.resolve(
                dueHint: dueHint,
                title: title,
                detail: detail,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
        priority = try container.decode(Priority.self, forKey: .priority)
        categoryHint = try container.decode(TodoCategory.self, forKey: .categoryHint)
    }
}

/// AI 提取的完整结果
struct ExtractionResult: Codable {
    let todos: [ExtractedTodo]
    let ignored: String
}

// MARK: - 共享工具方法

/// 待办日期解析工具：把 AI 返回的自然语言时间提示转换成自然日
enum TodoDueDateResolver {
    static func resolve(
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let text = [dueHint, title, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !text.isEmpty else { return nil }

        let today = calendar.startOfDay(for: referenceDate)
        let lowercasedText = text.lowercased()

        if text.contains("今天") || text.contains("今晚") ||
            lowercasedText.containsEnglishPhrase("today") ||
            lowercasedText.containsEnglishPhrase("tonight") {
            return today
        }
        if text.contains("后天") ||
            lowercasedText.containsEnglishPhrase("day after tomorrow") {
            return calendar.date(byAdding: .day, value: 2, to: today)
        }
        if text.contains("明天") || text.contains("明晚") ||
            lowercasedText.containsEnglishPhrase("tomorrow") ||
            lowercasedText.containsEnglishPhrase("tmr") {
            return calendar.date(byAdding: .day, value: 1, to: today)
        }

        if let weekday = weekdayNumber(in: text) {
            if text.contains("下周") || text.contains("下星期") || text.contains("下礼拜") ||
                lowercasedText.containsEnglishPhrase("next week") ||
                lowercasedText.containsNextEnglishWeekday(weekday) {
                return dateInWeek(offset: 1, matchingWeekday: weekday, from: today, calendar: calendar)
            }
            return nextDate(matchingWeekday: weekday, from: today, calendar: calendar)
        }

        return nil
    }

    private static func weekdayNumber(in text: String) -> Int? {
        let weekdays: [(tokens: [String], value: Int)] = [
            (["周日", "星期日", "礼拜日", "周天", "星期天", "礼拜天"], 1),
            (["周一", "星期一", "礼拜一"], 2),
            (["周二", "星期二", "礼拜二"], 3),
            (["周三", "星期三", "礼拜三"], 4),
            (["周四", "星期四", "礼拜四"], 5),
            (["周五", "星期五", "礼拜五"], 6),
            (["周六", "星期六", "礼拜六"], 7)
        ]

        if let chineseWeekday = weekdays.first(where: { entry in
            entry.tokens.contains { text.contains($0) }
        })?.value {
            return chineseWeekday
        }

        let lowercasedText = text.lowercased()
        return englishWeekdays.first { entry in
            entry.tokens.contains { lowercasedText.containsEnglishPhrase($0) }
        }?.value
    }

    fileprivate static let englishWeekdays: [(tokens: [String], value: Int)] = [
        (["sunday", "sun"], 1),
        (["monday", "mon"], 2),
        (["tuesday", "tue", "tues"], 3),
        (["wednesday", "wed"], 4),
        (["thursday", "thu", "thur", "thurs"], 5),
        (["friday", "fri"], 6),
        (["saturday", "sat"], 7)
    ]

    private static func nextDate(matchingWeekday weekday: Int, from today: Date, calendar: Calendar) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysAhead = (weekday - currentWeekday + 7) % 7
        let offset = daysAhead == 0 ? 7 : daysAhead
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    private static func dateInWeek(offset: Int, matchingWeekday weekday: Int, from today: Date, calendar: Calendar) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (currentWeekday + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysFromMonday + offset * 7, to: today) else {
            return nil
        }
        let mondayBasedOffset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: mondayBasedOffset, to: weekStart)
    }
}

/// 轻量重复规则解析器：只处理 v1 明确表达，模糊表达继续交给 dueHint。
enum RecurrenceRuleResolver {
    static func resolve(
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> RecurrenceRule? {
        let text = normalizedText(dueHint: dueHint, title: title, detail: detail)
        guard !text.isEmpty else { return nil }

        let endDate = inferredEndDate(
            in: text,
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        )

        let lower = text.lowercased()
        if text.contains("每天") || text.contains("每日") ||
            lower.containsEnglishPhrase("every day") ||
            lower.containsEnglishPhrase("daily") {
            return RecurrenceRule(frequency: .daily, endDate: endDate)
        }

        if let monthlyDay = monthlyDay(in: text) {
            return RecurrenceRule(frequency: .monthly, dayOfMonth: monthlyDay, endDate: endDate)
        }

        if isWeeklyExpression(text) {
            let weekdays = weekdayNumbers(in: text)
            if !weekdays.isEmpty {
                return RecurrenceRule(frequency: .weekly, weekdays: weekdays, endDate: endDate)
            }
        }

        return nil
    }

    static func ruleWithInferredEndDate(
        _ rule: RecurrenceRule?,
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> RecurrenceRule? {
        guard var rule else {
            return resolve(
                dueHint: dueHint,
                title: title,
                detail: detail,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
        guard rule.endDate == nil else { return rule }

        let text = normalizedText(dueHint: dueHint, title: title, detail: detail)
        rule.endDate = inferredEndDate(
            in: text,
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return rule
    }

    private static func normalizedText(dueHint: String?, title: String, detail: String) -> String {
        let text = [dueHint, title, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text
    }

    private static func inferredEndDate(
        in text: String,
        dueHint: String?,
        title: String,
        detail: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        guard let dayCount = durationDays(in: text), dayCount > 0 else { return nil }
        let start = TodoDueDateResolver.resolve(
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        ) ?? calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: dayCount - 1, to: calendar.startOfDay(for: start))
    }

    private static func durationDays(in text: String) -> Int? {
        let compactText = text.replacingOccurrences(of: " ", with: "")
        let chinesePatterns = [
            #"(?:(?:未来|接下来|接下来的|连续|连着|往后|之后的|未来的))([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天"#,
            #"([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天(?:内|里|之内)"#
        ]
        for pattern in chinesePatterns {
            if let value = firstRegexCapture(pattern, in: compactText),
               let days = parseDayCount(value),
               (1...366).contains(days) {
                return days
            }
        }

        let lower = text.lowercased()
        let englishPatterns = [
            #"over\s+the\s+next\s+([0-9]{1,3})\s+days"#,
            #"for\s+(?:the\s+)?next\s+([0-9]{1,3})\s+days"#,
            #"next\s+([0-9]{1,3})\s+days"#,
            #"for\s+([0-9]{1,3})\s+days"#
        ]
        for pattern in englishPatterns {
            if let value = firstRegexCapture(pattern, in: lower),
               let days = Int(value),
               (1...366).contains(days) {
                return days
            }
        }

        return nil
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func parseDayCount(_ raw: String) -> Int? {
        if let value = Int(raw) { return value }

        let values: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if raw == "十" { return 10 }
        if raw.contains("十") {
            let parts = raw.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts.first?.first.flatMap { values[$0] } ?? 1
            let ones = parts.dropFirst().first?.first.flatMap { values[$0] } ?? 0
            return tens * 10 + ones
        }
        return raw.first.flatMap { values[$0] }
    }

    private static func isWeeklyExpression(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("每周") ||
            text.contains("每星期") ||
            text.contains("每礼拜") ||
            lower.containsEnglishPhrase("every week") ||
            lower.containsEnglishPhrase("weekly") ||
            TodoDueDateResolver.englishWeekdays.contains { entry in
                entry.tokens.contains { lower.containsEnglishPhrase("every \($0)") }
            }
    }

    private static func weekdayNumbers(in text: String) -> [Int] {
        let chineseWeekdays: [(tokens: [String], value: Int)] = [
            (["周日", "星期日", "礼拜日", "周天", "星期天", "礼拜天", "每周日", "每星期日"], 1),
            (["周一", "星期一", "礼拜一", "每周一", "每星期一"], 2),
            (["周二", "星期二", "礼拜二", "每周二", "每星期二"], 3),
            (["周三", "星期三", "礼拜三", "每周三", "每星期三"], 4),
            (["周四", "星期四", "礼拜四", "每周四", "每星期四"], 5),
            (["周五", "星期五", "礼拜五", "每周五", "每星期五"], 6),
            (["周六", "星期六", "礼拜六", "每周六", "每星期六"], 7)
        ]

        var values: [Int] = chineseWeekdays.compactMap { entry in
            entry.tokens.contains { text.contains($0) } ? entry.value : nil
        }

        let lower = text.lowercased()
        for entry in TodoDueDateResolver.englishWeekdays {
            if entry.tokens.contains(where: { lower.containsEnglishPhrase("every \($0)") || lower.containsEnglishPhrase($0) }) {
                values.append(entry.value)
            }
        }

        return values.uniqued().sorted()
    }

    private static func monthlyDay(in text: String) -> Int? {
        let lower = text.lowercased()
        let hasMonthlyCue = text.contains("每月") ||
            text.contains("每个月") ||
            lower.containsEnglishPhrase("every month") ||
            lower.containsEnglishPhrase("monthly")
        guard hasMonthlyCue else { return nil }

        let patterns = [
            #"每(?:个)?月\s*(\d{1,2})\s*[号日]"#,
            #"monthly\s+on\s+the\s+(\d{1,2})"#,
            #"every\s+month\s+on\s+the\s+(\d{1,2})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let dayRange = Range(match.range(at: 1), in: text),
                  let day = Int(text[dayRange]),
                  (1...31).contains(day) else {
                continue
            }
            return day
        }

        return nil
    }
}

private extension String {
    func containsEnglishPhrase(_ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        return range(
            of: "(?<![A-Za-z])\(escaped)(?![A-Za-z])",
            options: .regularExpression
        ) != nil
    }

    func containsNextEnglishWeekday(_ weekday: Int) -> Bool {
        guard let tokens = TodoDueDateResolver.englishWeekdays.first(where: { $0.value == weekday })?.tokens else {
            return false
        }
        return tokens.contains { containsEnglishPhrase("next \($0)") }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// 文本工具（enum namespace）
enum TextUtils {
    /// 智能截断标题：在指定长度内寻找标点/空格作为截断点，避免截断在单词中间
    /// - Parameters:
    ///   - text: 原始文本
    ///   - maxLength: 最大长度
    /// - Returns: 截断后的标题
    static func truncateTitle(from text: String, maxLength: Int = 20) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }
        let prefix = trimmed.prefix(maxLength)
        if let lastBreak = prefix.lastIndex(where: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "。" || $0 == "、" }) {
            return String(trimmed[...lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prefix)
    }
}

// MARK: - 跨模块传递的通用数据类型（不依赖 SwiftData）

/// 待办数据传输对象，用于跨模块传递
/// Agent D 的 UI 和 Widget 只依赖这个类型，不需要知道 SwiftData 的存在
struct TodoItemData: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var detail: String?
    var dueHint: String?
    var dueDate: Date?
    var recurrenceRule: RecurrenceRule?
    var priority: Priority
    var category: TodoCategory
    var isCompleted: Bool
    var createdAt: Date
    var rawTranscript: String?
    var needsAIProcessing: Bool
    var sortOrder: Int
    var systemCalendarEventIdentifier: String?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        priority: Priority = .normal,
        category: TodoCategory = .other,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        rawTranscript: String? = nil,
        needsAIProcessing: Bool = false,
        sortOrder: Int = 0,
        systemCalendarEventIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.recurrenceRule = recurrenceRule
        self.priority = priority
        self.category = category
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
        self.systemCalendarEventIdentifier = systemCalendarEventIdentifier
    }

    /// 从 ExtractedTodo 创建（AI 提取结果转 DTO）[v2]
    init(from extracted: ExtractedTodo, rawTranscript: String? = nil) {
        self.id = extracted.id
        self.title = extracted.title
        self.detail = extracted.detail.isEmpty ? nil : extracted.detail
        self.dueHint = extracted.dueHint
        self.dueDate = TodoDueDateResolver.resolve(
            dueHint: extracted.dueHint,
            title: extracted.title,
            detail: extracted.detail
        )
        self.recurrenceRule = extracted.recurrenceRule
        self.priority = extracted.priority
        self.category = extracted.categoryHint
        self.isCompleted = false
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = false
        self.sortOrder = 0
        self.systemCalendarEventIdentifier = nil
    }
}
