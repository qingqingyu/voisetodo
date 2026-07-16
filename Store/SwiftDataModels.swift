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
    /// dueDate 是否携带明确钟点：true 写系统日历"定时事件"，false 写"全天事件"。
    /// 带默认值 → SwiftData 轻量迁移，旧数据自动补 false。
    var hasDueTime: Bool = false
    /// 显式模糊时段。Optional 字段让旧数据保持 nil，并由展示层从钟点推导。
    var timeBucketRaw: String?
    var recurrenceFrequencyRaw: String?
    var recurrenceWeekdaysRaw: String?
    var recurrenceDayOfMonth: Int?
    var recurrenceEndDate: Date?
    /// 重复间隔(每 N 个周期)。默认 1 → SwiftData 轻量迁移,旧数据自动补 1。
    var recurrenceInterval: Int = 1
    /// 多个提醒时间点(JSON 数组字符串,如 "[\"15:00\",\"17:00\"]")。nil = 无多时间提醒。
    var reminderTimesRaw: String?
    var priorityRaw: String
    var categoryRaw: String
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var rawTranscript: String?
    var needsAIProcessing: Bool
    var sortOrder: Int
    var systemCalendarEventIdentifier: String?
    /// 创建时的语言标识（如 "zh-Hans" / "en-US"），用于词汇学习按正确 locale 归档。
    /// Optional 字段：旧数据为 nil，回退到 voiceInput.currentLocale。
    var localeIdentifier: String?

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

    /// 显式模糊时段；`.anytime` 规范化为 nil，避免阻断精确钟点的展示推导。
    var timeBucket: TimeBucket? {
        get { hasDueTime ? nil : TimeBucket.explicit(from: timeBucketRaw) }
        set { timeBucketRaw = hasDueTime || newValue == .anytime ? nil : newValue?.rawValue }
    }

    // MARK: - Initialization

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
        localeIdentifier: String? = nil,
        reminderTimes: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.timeBucketRaw = hasDueTime || timeBucket == .anytime ? nil : timeBucket?.rawValue
        self.recurrenceFrequencyRaw = recurrenceRule?.frequency.rawValue
        self.recurrenceInterval = recurrenceRule?.interval ?? 1
        self.recurrenceWeekdaysRaw = Self.encodeWeekdays(recurrenceRule?.weekdays ?? [])
        self.recurrenceDayOfMonth = recurrenceRule?.dayOfMonth
        self.recurrenceEndDate = recurrenceRule?.endDate
        self.priorityRaw = priority.rawValue
        self.categoryRaw = category.rawValue
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.needsAIProcessing = needsAIProcessing
        self.sortOrder = sortOrder
        self.systemCalendarEventIdentifier = systemCalendarEventIdentifier
        self.localeIdentifier = localeIdentifier
        // reminderTimes → JSON 字符串存储
        if let reminderTimes, !reminderTimes.isEmpty,
           let data = try? JSONEncoder().encode(reminderTimes),
           let raw = String(data: data, encoding: .utf8) {
            self.reminderTimesRaw = raw
        } else {
            self.reminderTimesRaw = nil
        }
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
            hasDueTime: hasDueTime,
            timeBucket: timeBucket,
            recurrenceRule: recurrenceRule,
            priority: Priority(rawValue: priorityRaw) ?? .normal,
            category: TodoCategory(rawValue: categoryRaw) ?? .other,
            reminderTimes: reminderTimes,
            isCompleted: isCompleted,
            completedAt: completedAt,
            createdAt: createdAt,
            rawTranscript: rawTranscript,
            needsAIProcessing: needsAIProcessing,
            sortOrder: sortOrder,
            systemCalendarEventIdentifier: systemCalendarEventIdentifier,
            localeIdentifier: localeIdentifier
        )
    }

    var recurrenceRule: RecurrenceRule? {
        get {
            guard let raw = recurrenceFrequencyRaw,
                  let frequency = RecurrenceFrequency(rawValue: raw) else {
                return nil
            }
            let rule = RecurrenceRule(
                frequency: frequency,
                interval: recurrenceInterval,
                weekdays: Self.decodeWeekdays(recurrenceWeekdaysRaw),
                dayOfMonth: recurrenceDayOfMonth,
                endDate: recurrenceEndDate
            )
            return rule.isValid ? rule : nil
        }
        set {
            recurrenceFrequencyRaw = newValue?.frequency.rawValue
            recurrenceInterval = newValue?.interval ?? 1
            recurrenceWeekdaysRaw = Self.encodeWeekdays(newValue?.weekdays ?? [])
            recurrenceDayOfMonth = newValue?.dayOfMonth
            recurrenceEndDate = newValue?.endDate
        }
    }

    /// 多个提醒时间点(["15:00","17:00","19:00"])。nil = 无多时间提醒。
    var reminderTimes: [String]? {
        get {
            guard let raw = reminderTimesRaw,
                  let data = raw.data(using: .utf8),
                  let times = try? JSONDecoder().decode([String].self, from: data) else {
                return nil
            }
            return times.isEmpty ? nil : times
        }
        set {
            guard let newValue, !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else {
                reminderTimesRaw = nil
                return
            }
            reminderTimesRaw = raw
        }
    }

    private static func encodeWeekdays(_ weekdays: [Int]) -> String? {
        let encoded = weekdays
            .filter { (1...7).contains($0) }
            .uniqued()
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        return encoded.isEmpty ? nil : encoded
    }

    private static func decodeWeekdays(_ raw: String?) -> [Int] {
        raw?
            .split(separator: ",")
            .compactMap { Int($0) }
            .filter { (1...7).contains($0) }
            .uniqued()
            .sorted() ?? []
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
        // 优先用 AI 算好的绝对日期，其次文本解析兜底
        let resolvedDate = extracted.dueDate ??
            TodoDueDateResolver.resolve(
                dueHint: extracted.dueHint,
                title: extracted.title,
                detail: extracted.detail
            )
        let timed = TodoDueTimeResolver.combine(date: resolvedDate, dueTime: extracted.dueTime)
        // 时段⇒今天：只有模糊时段没日期时补今天，让任务落进「今日/时段」而非 Unscheduled。
        let effectiveDate = TodoScheduleDefaults.effectiveDueDate(
            resolvedDate: timed.date,
            hasDueTime: timed.hasTime,
            timeBucket: extracted.timeBucket
        )
        return TodoItem(
            id: extracted.id,
            title: extracted.title,
            detail: extracted.detail.isEmpty ? nil : extracted.detail,
            dueHint: extracted.dueHint,
            dueDate: effectiveDate,
            hasDueTime: timed.hasTime,
            timeBucket: extracted.timeBucket,
            recurrenceRule: extracted.recurrenceRule,
            priority: extracted.priority,
            category: extracted.categoryHint,
            isCompleted: false,
            createdAt: Date(),
            rawTranscript: rawTranscript,
            needsAIProcessing: false,
            systemCalendarEventIdentifier: nil,
            localeIdentifier: extracted.localeIdentifier,
            reminderTimes: extracted.reminderTimes
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

/// 重复任务某一天的完成记录。
@Model
final class TodoOccurrenceCompletion {
    @Attribute(.unique) var occurrenceKey: String
    var id: UUID
    var todoId: UUID
    var occurrenceDate: Date
    var completedAt: Date

    init(
        id: UUID = UUID(),
        todoId: UUID,
        occurrenceDate: Date,
        completedAt: Date = Date(),
        calendar: Calendar = .current
    ) {
        let normalizedDate = calendar.startOfDay(for: occurrenceDate)
        self.id = id
        self.todoId = todoId
        self.occurrenceDate = normalizedDate
        self.completedAt = completedAt
        self.occurrenceKey = TodoOccurrenceCompletion.key(todoId: todoId, occurrenceDate: normalizedDate, calendar: calendar)
    }

    static func key(todoId: UUID, occurrenceDate: Date, calendar: Calendar = .current) -> String {
        "\(todoId.uuidString)-\(TodoOccurrenceData.dayKey(for: occurrenceDate, calendar: calendar))"
    }
}

/// Legacy voice capture records retained only so stores created by older app
/// versions can still open. New app code does not create or read these records;
/// `TodoStore` purges them during startup migration.
@Model
final class VoiceCaptureRecord {
    @Attribute(.unique) var id: UUID
    var transcript: String
    var createdAt: Date
    var statusRaw: String
    var sourceRaw: String
    var localeIdentifier: String
    var generatedTodoCount: Int
    var generatedTodoIDsRaw: String
    var pendingTodoID: UUID?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        transcript: String,
        createdAt: Date = Date(),
        statusRaw: String = "processing",
        sourceRaw: String = "recordButton",
        localeIdentifier: String,
        generatedTodoCount: Int = 0,
        generatedTodoIDsRaw: String = "",
        pendingTodoID: UUID? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.transcript = transcript
        self.createdAt = createdAt
        self.statusRaw = statusRaw
        self.sourceRaw = sourceRaw
        self.localeIdentifier = localeIdentifier
        self.generatedTodoCount = generatedTodoCount
        self.generatedTodoIDsRaw = generatedTodoIDsRaw
        self.pendingTodoID = pendingTodoID
        self.errorMessage = errorMessage
    }
}

enum WidgetTodoFetch {
    static func recentTodos(
        context: ModelContext,
        today: Date = Date(),
        limit: Int,
        maxCandidateScan: Int? = nil,
        calendar: Calendar = .current,
        recentCompletionCutoff: Date? = nil
    ) throws -> [TodoItemData] {
        guard limit > 0 else { return [] }

        let candidateLimit = max(limit, maxCandidateScan ?? max(limit * 20, 100))
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = candidateLimit
        let items = try context.fetch(descriptor)

        let day = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let completionDescriptor = FetchDescriptor<TodoOccurrenceCompletion>(
            predicate: #Predicate { completion in
                completion.occurrenceDate >= day && completion.occurrenceDate < tomorrow
            }
        )
        let completions = try context.fetch(completionDescriptor)
        let completionKeys = Set(completions.map(\.occurrenceKey))
        let completionDatesByKey = Dictionary(
            uniqueKeysWithValues: completions.map { ($0.occurrenceKey, $0.completedAt) }
        )

        return WidgetTodoFilter.visibleTodos(
            from: items.map { $0.toData() },
            completionKeys: completionKeys,
            today: day,
            limit: limit,
            calendar: calendar,
            recentCompletionCutoff: recentCompletionCutoff,
            completionDatesByKey: completionDatesByKey
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// App 与 Widget / AppIntent 共享的 SwiftData schema。
/// 任何 @Model 类型变更都必须在此处同步注册，避免双处字面量不同步导致
/// `ModelContainer` 初始化时抛 schema mismatch。
enum VoiceTodoSchema {
    /// 当前 App 注册的所有 SwiftData @Model 类型。
    static let schema = Schema([
        TodoItem.self,
        TodoOccurrenceCompletion.self,
        VoiceCaptureRecord.self
    ])
}
