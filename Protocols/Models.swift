import Foundation

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

// MARK: - AI 提取结果（从 API 返回的结构）

/// 单条提取的待办（AI 返回格式）
struct ExtractedTodo: Identifiable, Codable {
    let id: UUID
    var title: String
    var detail: String
    var dueHint: String?
    var priority: Priority
    var categoryHint: TodoCategory

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case dueHint
        case priority
        case categoryHint
    }

    init(id: UUID = UUID(), title: String, detail: String = "", dueHint: String? = nil, priority: Priority = .normal, categoryHint: TodoCategory = .other) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = Self.sanitizeDueHint(dueHint)
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
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        let rawDueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
        dueHint = Self.sanitizeDueHint(rawDueHint)
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
    var priority: Priority
    var category: TodoCategory
    var isCompleted: Bool
    var createdAt: Date
    var rawTranscript: String?
    var needsAIProcessing: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        priority: Priority = .normal,
        category: TodoCategory = .other,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        rawTranscript: String? = nil,
        needsAIProcessing: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.priority = priority
        self.category = category
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
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
        self.priority = extracted.priority
        self.category = extracted.categoryHint
        self.isCompleted = false
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = false
        self.sortOrder = 0
    }
}
