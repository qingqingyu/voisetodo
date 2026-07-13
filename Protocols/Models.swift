import Foundation

// MARK: - 枚举类型

/// 优先级
enum Priority: String, Codable, CaseIterable, Sendable {
    case high
    case normal

    /// 从原始字符串容错构造：大小写不敏感，未知/缺失回落 .normal。
    /// 用于解码 AI 响应这类不可信边界，避免单个未知值导致整次解码失败。
    static func tolerant(_ raw: String?) -> Priority {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = Priority(rawValue: raw) else {
            return .normal
        }
        return value
    }
}

/// 待办分类
enum TodoCategory: String, Codable, CaseIterable, Sendable {
    case work     // 工作
    case study    // 学习
    case life     // 生活
    case health   // 健康
    case finance  // 财务
    case social   // 社交
    case other    // 其他

    /// 从原始字符串容错构造：大小写不敏感，未知/缺失回落 .other。
    /// 用于解码 AI 响应这类不可信边界，避免单个未知值导致整次解码失败。
    static func tolerant(_ raw: String?) -> TodoCategory {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = TodoCategory(rawValue: raw) else {
            return .other
        }
        return value
    }

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

    /// 分类对应的 SF Symbol 名称——比 emoji 更统一可控（emoji 在不同平台渲染差异大，
    /// 且当前 AI 提取的 life 分类全是 🏠，没区分度）。用 SF Symbol + categoryColor
    /// 着色，形成一套视觉一致的图标体系。
    var sfSymbolName: String {
        switch self {
        case .work: return "briefcase.fill"
        case .study: return "book.fill"
        case .life: return "house.fill"
        case .health: return "heart.fill"
        case .finance: return "yensign.circle.fill"
        case .social: return "person.2.fill"
        case .other: return "tag.fill"
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

/// 日历中某一天实际出现的一条待办。
struct TodoOccurrenceData: Identifiable, Codable, Hashable, Sendable {
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

// MARK: - AI 提取结果（从 API 返回的结构）

/// 单条提取的待办（AI 返回格式）
struct ExtractedTodo: Identifiable, Codable {
    let id: UUID
    var title: String
    var detail: String
    /// AI 返回的 ISO 8601 绝对日期（"2026-07-15"），已结合参考日期换算。
    /// 优先于此前的 dueHint 文本解析——dueHint 会过期（"next Wednesday"下周含义就变了），
    /// 而 dueDate 是绝对日期，不会随时间推移产生歧义。
    var dueDate: Date?
    var dueHint: String?
    /// AI 结构化返回的明确钟点（"HH:mm"，24 小时制），无则 nil。与 dueHint（freeform 文本）互补。
    var dueTime: String?
    /// AI 返回的模糊时段；仅在没有明确钟点时存在。
    var timeBucket: TimeBucket?
    var recurrenceRule: RecurrenceRule?
    var priority: Priority
    var categoryHint: TodoCategory
    /// 本地附加的输入语言标识；AI 响应不会提供，离线恢复用于保留原 pending locale。
    var localeIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case dueDate = "due_date"
        case dueHint
        case dueTime
        case timeBucket = "time_bucket"
        case recurrenceRule
        case recurrenceEnd  // 仅用于 init(from:) 解码 AI 返回的结构化截止边界
        case priority
        case categoryHint
    }

    /// 自定义 encode：跳过 `recurrenceEnd` case。
    /// 这个字段只是 init(from:) 里的临时变量（解码后通过 RecurrenceEndResolver
    /// 算出 endDate 塞进 recurrenceRule），不需要持久化。
    /// 不写自定义 encode，Swift 合成的 Encodable 会要求 CodingKeys 所有 case
    /// 对应存储属性，编译报 "Type 'ExtractedTodo' does not conform to 'Encodable'"。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encodeIfPresent(dueHint, forKey: .dueHint)
        try container.encodeIfPresent(dueTime, forKey: .dueTime)
        try container.encodeIfPresent(timeBucket, forKey: .timeBucket)
        try container.encodeIfPresent(recurrenceRule, forKey: .recurrenceRule)
        try container.encode(priority, forKey: .priority)
        try container.encode(categoryHint, forKey: .categoryHint)
        // 故意跳过 .recurrenceEnd 和 localeIdentifier——
        // recurrenceEnd 不持久化，localeIdentifier 由本地附加，AI 响应不包含。
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        dueDate: Date? = nil,
        dueHint: String? = nil,
        dueTime: String? = nil,
        timeBucket: TimeBucket? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        priority: Priority = .normal,
        categoryHint: TodoCategory = .other,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueDate = dueDate
        self.dueHint = Self.sanitizeDueHint(dueHint)
        self.dueTime = Self.sanitizeDueTime(dueTime)
        // 明确钟点与模糊时段互斥。即使上游模型异常同时返回两者，
        // 也优先保留可精确执行的钟点，避免展示和分组发生冲突。
        self.timeBucket = self.dueTime == nil && timeBucket != .anytime ? timeBucket : nil
        self.recurrenceRule = RecurrenceRuleResolver.ruleWithInferredEndDate(
            recurrenceRule,
            dueHint: dueHint,
            title: title,
            detail: detail
        )
        self.priority = priority
        self.categoryHint = categoryHint
        self.localeIdentifier = localeIdentifier
    }

    /// 解析 AI 返回的 ISO 8601 日期串（"2026-07-15"）。固定 en_US_POSIX 防 locale 漂移。
    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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

    /// 过滤伪 null 并校验 "HH:mm" 格式；非法一律视为无时间，避免脏值流入下游。
    private static func sanitizeDueTime(_ time: String?) -> String? {
        guard let normalized = sanitizeDueHint(time),
              TodoDueTimeResolver.parse(normalized) != nil else {
            return nil
        }
        return normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let referenceDate = decoder.userInfo[.recurrenceReferenceDate] as? Date ?? Date()
        let calendar = decoder.userInfo[.recurrenceCalendar] as? Calendar ?? .current
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        // title 容错：缺失/null/空白时从 detail 派生，避免单条缺 title 导致整批 ExtractionResult 解码失败。
        // 同时做长度保护：AI 可能返回异常超长串，截断到合理上限（200，远大于正常标题，不影响常规内容）。
        let rawTitle = (try container.decodeIfPresent(String.self, forKey: .title) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = TextUtils.truncateTitle(from: rawTitle.isEmpty ? detail : rawTitle, maxLength: 200)
        // AI 返回的 ISO 8601 绝对日期（"2026-07-15"），优先于 dueHint 文本解析
        if let dueDateString = try container.decodeIfPresent(String.self, forKey: .dueDate),
           let parsed = Self.isoDateFormatter.date(from: dueDateString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dueDate = parsed
        } else {
            dueDate = nil
        }
        let rawDueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
        dueHint = Self.sanitizeDueHint(rawDueHint)
        let rawDueTime = try container.decodeIfPresent(String.self, forKey: .dueTime)
        dueTime = Self.sanitizeDueTime(rawDueTime)
        // 上游可能没有完全遵守 JSON 约束；明确钟点优先，丢弃冲突的模糊时段。
        timeBucket = dueTime == nil
            ? TimeBucket.explicit(from: try container.decodeIfPresent(String.self, forKey: .timeBucket))
            : nil
        // 结构化截止边界（模型归一化产出，只分类不算日期）；malformed 一律吞成 nil，不炸整条解码。
        let recurrenceEnd = (try? container.decodeIfPresent(RecurrenceEnd.self, forKey: .recurrenceEnd)) ?? nil
        // 重复起始日：优先用 AI 算好的 dueDate，其次文本解析，无则回落今天。
        let recurrenceStart = dueDate ??
            TodoDueDateResolver.resolve(
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        ) ?? calendar.startOfDay(for: referenceDate)
        // 截止优先级：模型 end_date（绝对） > 结构化 recurrence_end（客户端确定性算） > 文本兜底（未来N天）> nil。
        let structuredEndDate = RecurrenceEndResolver.resolve(
            recurrenceEnd,
            start: recurrenceStart,
            today: referenceDate,
            calendar: calendar
        )
        if container.contains(.recurrenceRule) {
            let decodedRule = try? container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrenceRule)
            if var rule = decodedRule ?? nil, rule.isValid {
                if rule.endDate == nil, let structuredEndDate {
                    rule.endDate = structuredEndDate
                }
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
            var resolvedRule = RecurrenceRuleResolver.resolve(
                dueHint: dueHint,
                title: title,
                detail: detail,
                referenceDate: referenceDate,
                calendar: calendar
            )
            if var rule = resolvedRule, rule.endDate == nil, let structuredEndDate {
                rule.endDate = structuredEndDate
                resolvedRule = rule
            }
            recurrenceRule = resolvedRule
        }
        // 容错解码：AI 返回表外的 priority/category 值时回落默认值，而非让整次解码失败
        priority = Priority.tolerant(try container.decodeIfPresent(String.self, forKey: .priority))
        categoryHint = TodoCategory.tolerant(try container.decodeIfPresent(String.self, forKey: .categoryHint))
        localeIdentifier = nil
    }
}

/// AI 提取的完整结果
struct ExtractionResult: Codable {
    let todos: [ExtractedTodo]
    let ignored: String

    /// Memberwise init（业务代码 / Preview / 测试 fixture 用）。
    /// 加了自定义 init(from:) 后 Swift 不再合成默认 memberwise init，需显式声明。
    init(todos: [ExtractedTodo], ignored: String) {
        self.todos = todos
        self.ignored = ignored
    }

    /// 自定义解码：AI 偶尔返回 `"ignored": null` 或省略字段，
    /// 用默认 decode 会抛 DecodingError.valueNotFound 导致整次抽取失败（已有 1 条 todo 也会丢）。
    /// 兜底为空串，保持外部类型 String 不变，调用方（日志/测试）零感知。
    /// 命中兜底时记 warning 日志，便于线上追踪 AI 输出质量（日志分析 AI 可识别该模式）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todos = try container.decodeIfPresent([ExtractedTodo].self, forKey: .todos) ?? []
        // 提到局部变量避免 autoclosure 捕获 mutating self。
        let todosCount = todos.count
        // 区分 null/缺失 vs 合法 String：前者走兜底并记日志，后者正常返回。
        if let ignoredValue = try? container.decode(String.self, forKey: .ignored) {
            ignored = ignoredValue
        } else {
            ignored = ""
            VoiceTodoLog.extractor.warning("extract.result.ignored_fallback reason=null_or_missing todosCount=\(todosCount)")
        }
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
struct TodoItemData: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var dueHint: String?
    var dueDate: Date?
    /// dueDate 是否携带明确钟点：true 时系统日历写"定时事件"，false 写"全天事件"。
    var hasDueTime: Bool
    /// 用户或 AI 显式给出的模糊时段；nil 由明确钟点推导或显示为“随时”。
    var timeBucket: TimeBucket?
    var recurrenceRule: RecurrenceRule?
    var priority: Priority
    var category: TodoCategory
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var rawTranscript: String?
    var needsAIProcessing: Bool
    var sortOrder: Int
    var systemCalendarEventIdentifier: String?
    /// 创建时的语言标识（如 "zh-Hans" / "en-US"），用于词汇学习按正确 locale 归档。
    /// Optional：旧数据为 nil，回退到 voiceInput.currentLocale。
    var localeIdentifier: String?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        timeBucket: TimeBucket? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        priority: Priority = .normal,
        category: TodoCategory = .other,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        rawTranscript: String? = nil,
        needsAIProcessing: Bool = false,
        sortOrder: Int = 0,
        systemCalendarEventIdentifier: String? = nil,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        // 已有明确钟点时，时段由钟点推导，不能保留独立的模糊时段。
        self.timeBucket = hasDueTime || timeBucket == .anytime ? nil : timeBucket
        self.recurrenceRule = recurrenceRule
        self.priority = priority
        self.category = category
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
        self.systemCalendarEventIdentifier = systemCalendarEventIdentifier
        self.localeIdentifier = localeIdentifier
    }

    /// 从 ExtractedTodo 创建（AI 提取结果转 DTO）[v2]
    init(from extracted: ExtractedTodo, rawTranscript: String? = nil) {
        self.id = extracted.id
        self.title = extracted.title
        self.detail = extracted.detail.isEmpty ? nil : extracted.detail
        self.dueHint = extracted.dueHint
        // 优先用 AI 算好的绝对日期（dueDate），其次文本解析兜底。
        // dueDate 不会过期；dueHint 文本（"next Wednesday"）会随时间推移含义漂移。
        let resolvedDate = extracted.dueDate ??
            TodoDueDateResolver.resolve(
                dueHint: extracted.dueHint,
                title: extracted.title,
                detail: extracted.detail
            )
        let timed = TodoDueTimeResolver.combine(date: resolvedDate, dueTime: extracted.dueTime)
        self.dueDate = timed.date
        self.hasDueTime = timed.hasTime
        self.timeBucket = timed.hasTime ? nil : extracted.timeBucket
        self.recurrenceRule = extracted.recurrenceRule
        self.priority = extracted.priority
        self.category = extracted.categoryHint
        self.isCompleted = false
        self.completedAt = nil
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = false
        self.sortOrder = 0
        self.systemCalendarEventIdentifier = nil
        self.localeIdentifier = extracted.localeIdentifier
    }
}
