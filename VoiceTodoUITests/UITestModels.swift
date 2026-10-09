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
    /// App 端 `TodoItemData` 的**非 Optional** 字段:合成 Codable 对非 Optional 键用
    /// `decode`(缺键即 keyNotFound → `VoiceTodoApp.init` 的 fatalError,app 启动即崩)。
    /// 必须随 payload 编码;类型用镜像枚举(同 `UITestPriority`/`UITestCategory` 模式,
    /// rawValue 与 App 端 `ExtractionOutcome`/`TodoSource` 对齐),传错值编译期即报。
    let extractionOutcome: UITestExtractionOutcome
    let source: UITestSource

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
        sortOrder: Int = 0,
        extractionOutcome: UITestExtractionOutcome = .parsed,
        source: UITestSource = .voice
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
        self.extractionOutcome = extractionOutcome
        self.source = source
    }
}

enum UITestPriority: String, Codable {
    case high
    case normal
}

/// `ExtractionOutcome`(Protocols/Domain/ExtractionOutcome.swift)的镜像:
/// UI 测试 target 不编译 app 源码,rawValue 必须逐字对齐 App 端解码值。
enum UITestExtractionOutcome: String, Codable {
    case parsed
    case rawFallback
    case unparsed
}

/// `TodoSource`(Protocols/Domain/TodoSource.swift)的镜像,rawValue 对齐同上。
enum UITestSource: String, Codable {
    case voice
    case calendarImport
    case collaboration
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
