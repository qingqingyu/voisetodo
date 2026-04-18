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
        case .work: return "工作"
        case .study: return "学习"
        case .life: return "生活"
        case .health: return "健康"
        case .finance: return "财务"
        case .social: return "社交"
        case .other: return "其他"
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
        needsAIProcessing: Bool = false
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
    }

    /// 从 ExtractedTodo 创建（AI 提取结果转 DTO）[v2]
    init(from extracted: ExtractedTodo, rawTranscript: String? = nil) {
        self.id = extracted.id
        self.title = extracted.title
        self.detail = extracted.detail.isEmpty ? nil : extracted.detail
        self.dueHint = extracted.dueHint
        self.dueDate = nil  // V1 不自动解析时间
        self.priority = extracted.priority
        self.category = extracted.categoryHint
        self.isCompleted = false
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = false
    }
}
