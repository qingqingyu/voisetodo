import Foundation

struct UITestTodoPayload: Codable, Equatable {
    let id: UUID
    let title: String
    let detail: String?
    let dueHint: String?
    let dueDate: Date?
    let hasDueTime: Bool
    let timeBucket: String?
    let priority: String
    let category: String
    let isCompleted: Bool
    let createdAt: Date
    let rawTranscript: String?
    let needsAIProcessing: Bool
    let sortOrder: Int

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        timeBucket: String? = nil,
        priority: UITestPriority = .normal,
        category: UITestCategory = .other,
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
        self.hasDueTime = hasDueTime
        self.timeBucket = timeBucket
        self.priority = priority.rawValue
        self.category = category.rawValue
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
    }
}

enum UITestPriority: String, Codable {
    case high
    case normal
}

enum UITestCategory: String, Codable {
    case work
    case study
    case life
    case health
    case finance
    case social
    case other

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
}
