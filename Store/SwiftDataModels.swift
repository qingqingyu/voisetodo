import Foundation
import SwiftData

/// 待办事项 SwiftData 模型
@Model
final class TodoItem {
    // MARK: - Properties

    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String?
    var dueHint: String?
    var dueDate: Date?
    var priorityRaw: String
    var categoryRaw: String
    var isCompleted: Bool
    var createdAt: Date
    var rawTranscript: String?
    var needsAIProcessing: Bool
    var sortOrder: Int

    // MARK: - Computed Properties

    /// 优先级（类型安全访问）
    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    /// 分类（类型安全访问）
    var category: TodoCategory {
        get { TodoCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    // MARK: - Initialization

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
        self.priorityRaw = priority.rawValue
        self.categoryRaw = category.rawValue
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
    }

    // MARK: - Conversion

    /// 转换为跨模块传递类型 [v2]
    /// - Returns: TodoItemData 实例
    func toData() -> TodoItemData {
        TodoItemData(
            id: id,
            title: title,
            detail: detail,
            dueHint: dueHint,
            dueDate: dueDate,
            priority: Priority(rawValue: priorityRaw) ?? .normal,
            category: TodoCategory(rawValue: categoryRaw) ?? .other,
            isCompleted: isCompleted,
            createdAt: createdAt,
            rawTranscript: rawTranscript,
            needsAIProcessing: needsAIProcessing,
            sortOrder: sortOrder
        )
    }
}

// MARK: - Factory Methods

extension TodoItem {
    /// 从 ExtractedTodo 创建 TodoItem（AI 提取结果）
    /// - Parameters:
    ///   - extracted: AI 提取的待办
    ///   - rawTranscript: 原始语音转写文本
    /// - Returns: TodoItem 实例
    static func from(_ extracted: ExtractedTodo, rawTranscript: String? = nil) -> TodoItem {
        TodoItem(
            id: extracted.id,
            title: extracted.title,
            detail: extracted.detail.isEmpty ? nil : extracted.detail,
            dueHint: extracted.dueHint,
            dueDate: nil,  // V1 不自动解析时间
            priority: extracted.priority,
            category: extracted.categoryHint,
            isCompleted: false,
            createdAt: Date(),
            rawTranscript: rawTranscript,
            needsAIProcessing: false
        )
    }

    /// 创建原始转写待办（离线降级用）
    /// - Parameter transcript: 原始转写文本
    /// - Returns: TodoItem 实例
    static func rawTranscript(_ transcript: String) -> TodoItem {
        let title = TextUtils.truncateTitle(from: transcript)
        return TodoItem(
            title: title,
            detail: transcript,
            dueHint: nil,
            priority: .normal,
            category: .other,
            rawTranscript: transcript,
            needsAIProcessing: true
        )
    }
}
