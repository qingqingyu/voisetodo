import Foundation

// MARK: - 枚举类型

/// 优先级
enum Priority: String, Codable, CaseIterable {
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
enum TodoCategory: String, Codable, CaseIterable {
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

/// 语音捕捉历史记录状态。
enum VoiceCaptureStatus: String, Codable, CaseIterable {
    case processing
    case reviewing
    case saved
    case noTodos
    case pending
    case failed
    case cancelled

    /// 终态或重置态：进入这些状态时应清空已生成 todo 关联数据。
    /// `updateRecord` 用此判断是否要把 generatedTodoIDs / generatedTodoCount 置空。
    var resetsGeneratedArtifacts: Bool {
        switch self {
        case .processing, .pending, .noTodos, .failed, .cancelled:
            return true
        case .reviewing, .saved:
            return false
        }
    }
}

/// 更新语音历史与离线 pending todo 的关联方式。
enum VoiceCapturePendingTodoLinkUpdate: Equatable {
    case keepCurrent
    case set(UUID)
    case clear

    static func replacing(with pendingTodoID: UUID?) -> VoiceCapturePendingTodoLinkUpdate {
        pendingTodoID.map(VoiceCapturePendingTodoLinkUpdate.set) ?? .clear
    }
}

/// 语音捕捉入口来源。
enum VoiceCaptureSource: String, Codable, CaseIterable {
    case recordButton
    case actionButton
}

/// 历史记录列表加载状态。
enum VoiceCaptureHistoryLoadState: String, Codable, Equatable {
    case loading
    case empty
    case error
    case success
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
    /// 本地附加的输入语言标识；AI 响应不会提供，离线恢复用于保留原 pending locale。
    var localeIdentifier: String?

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
        categoryHint: TodoCategory = .other,
        localeIdentifier: String? = nil
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
        self.localeIdentifier = localeIdentifier
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
        // 标题长度保护：AI 可能返回异常超长串，截断到合理上限（200，远大于正常标题，不影响常规内容）
        let rawTitle = try container.decode(String.self, forKey: .title)
        title = TextUtils.truncateTitle(from: rawTitle, maxLength: 200)
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
        self.dueDate = TodoDueDateResolver.resolve(
            dueHint: extracted.dueHint,
            title: extracted.title,
            detail: extracted.detail
        )
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

/// 语音捕捉历史记录 DTO，不依赖 SwiftData。
struct VoiceCaptureRecordData: Identifiable, Codable, Hashable {
    let id: UUID
    var transcript: String
    var createdAt: Date
    var status: VoiceCaptureStatus
    var source: VoiceCaptureSource
    var localeIdentifier: String
    var generatedTodoCount: Int
    var generatedTodoIDs: [UUID]
    var pendingTodoID: UUID?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        transcript: String,
        createdAt: Date = Date(),
        status: VoiceCaptureStatus = .processing,
        source: VoiceCaptureSource,
        localeIdentifier: String,
        generatedTodoCount: Int = 0,
        generatedTodoIDs: [UUID] = [],
        pendingTodoID: UUID? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.transcript = transcript
        self.createdAt = createdAt
        self.status = status
        self.source = source
        self.localeIdentifier = localeIdentifier
        self.generatedTodoCount = generatedTodoCount
        self.generatedTodoIDs = generatedTodoIDs
        self.pendingTodoID = pendingTodoID
        self.errorMessage = errorMessage
    }
}
