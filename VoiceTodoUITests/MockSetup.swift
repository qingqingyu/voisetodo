import Foundation

/// Mock 场景定义
/// 用于 E2E 测试时注入不同的 Mock 数据
enum MockScenarios {
    /// 正常多条: "明天去银行，顺便买菜，晚上给老妈打电话"
    static let multiTodo = ExtractionResult(
        todos: [
            ExtractedTodo(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                title: "去银行办卡",
                detail: "明天去银行办卡",
                dueHint: "明天",
                priority: .normal,
                categoryHint: .finance
            ),
            ExtractedTodo(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                title: "买菜",
                detail: "顺便买菜",
                dueHint: nil,
                priority: .normal,
                categoryHint: .life
            ),
            ExtractedTodo(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                title: "给老妈打电话",
                detail: "晚上给老妈打电话",
                dueHint: "晚上",
                priority: .normal,
                categoryHint: .social
            )
        ],
        ignored: ""
    )

    /// 纯感受: "最近好累，什么都不想干"
    static let noTodo = ExtractionResult(
        todos: [],
        ignored: "最近好累，什么都不想干（纯感受，无行动意图）"
    )

    /// 紧急单条: "必须今天交报告"
    static let urgentSingle = ExtractionResult(
        todos: [
            ExtractedTodo(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                title: "交报告",
                detail: "必须今天交报告",
                dueHint: "今天",
                priority: .high,
                categoryHint: .work
            )
        ],
        ignored: ""
    )

    /// 网络失败场景
    static let networkError = VoiceTodoError.networkUnavailable

    /// API 超时场景
    static let timeoutError = VoiceTodoError.apiTimeout
}

/// Mock 语音输入管理器
@MainActor
class MockVoiceInputManager: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?

    private var mockTranscript: String = ""
    private var shouldFail: Bool = false
    private var mockError: VoiceTodoError?

    /// 配置 Mock 场景
    func configure(transcript: String, shouldFail: Bool = false, error: VoiceTodoError? = nil) {
        self.mockTranscript = transcript
        self.shouldFail = shouldFail
        self.mockError = error
    }

    func startRecording() async throws {
        if shouldFail {
            throw mockError ?? .microphonePermissionDenied
        }

        isRecording = true
        // 模拟语音识别过程
        transcript = mockTranscript
    }

    func stopRecording() {
        isRecording = false
    }
}

/// Mock 待办提取器
class MockTodoExtractor: TodoExtractorProtocol {
    private var mockResult: ExtractionResult?
    private var shouldFail: Bool = false
    private var mockError: VoiceTodoError?

    /// 配置 Mock 场景
    func configure(result: ExtractionResult) {
        self.mockResult = result
        self.shouldFail = false
        self.mockError = nil
    }

    func configure(error: VoiceTodoError) {
        self.shouldFail = true
        self.mockError = error
    }

    func extract(from transcript: String) async throws -> ExtractionResult {
        if shouldFail {
            throw mockError ?? .networkUnavailable
        }

        return mockResult ?? ExtractionResult(todos: [], ignored: "")
    }
}

/// Mock 待办存储
class MockTodoStore: TodoStoreProtocol {
    @Published var todos: [TodoItemData] = []

    private var storage: [UUID: TodoItemData] = [:]

    func add(_ item: ExtractedTodo) throws {
        let data = TodoItemData(from: item)
        storage[data.id] = data
        refreshTodos()
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        for item in items {
            let data = TodoItemData(from: item)
            storage[data.id] = data
        }
        refreshTodos()
    }

    func addRawTranscript(_ transcript: String) throws {
        let title = TextUtils.truncateTitle(from: transcript)
        let data = TodoItemData(
            title: title,
            detail: transcript,
            category: .other,
            rawTranscript: transcript,
            needsAIProcessing: true
        )
        storage[data.id] = data
        refreshTodos()
    }

    func toggleComplete(_ id: UUID) throws {
        guard var todo = storage[id] else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }
        todo.isCompleted.toggle()
        storage[id] = todo
        refreshTodos()
    }

    func delete(_ id: UUID) throws {
        guard storage[id] != nil else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }
        storage.removeValue(forKey: id)
        refreshTodos()
    }

    func update(_ id: UUID, title: String, category: TodoCategory? = nil, priority: Priority? = nil, dueHint: String? = nil) throws {
        guard var todo = storage[id] else {
            throw VoiceTodoError.storageReadFailed("未找到 ID: \(id)")
        }
        var updated = todo
        updated = TodoItemData(
            id: updated.id,
            title: title,
            detail: updated.detail,
            dueHint: dueHint ?? updated.dueHint,
            dueDate: updated.dueDate,
            priority: priority ?? updated.priority,
            category: category ?? updated.category,
            isCompleted: updated.isCompleted,
            createdAt: updated.createdAt,
            rawTranscript: updated.rawTranscript,
            needsAIProcessing: updated.needsAIProcessing
        )
        storage[id] = updated
        refreshTodos()
    }

    func pendingItems() -> [TodoItemData] {
        todos.filter { $0.needsAIProcessing }
    }

    func recentUncompleted(limit: Int) -> [TodoItemData] {
        Array(todos.filter { !$0.isCompleted }.prefix(limit))
    }

    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String? = nil) throws {
        storage.removeValue(forKey: pendingId)
        try addBatch(items)
    }

    /// 重置存储（用于测试之间隔离）
    func reset() {
        storage.removeAll()
        refreshTodos()
    }

    private func refreshTodos() {
        todos = Array(storage.values)
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// Mock 依赖容器
class MockServiceContainer {
    let voiceInput: MockVoiceInputManager
    let extractor: MockTodoExtractor
    let store: MockTodoStore

    init() {
        voiceInput = MockVoiceInputManager()
        extractor = MockTodoExtractor()
        store = MockTodoStore()
    }

    /// 重置所有 Mock
    func reset() {
        store.reset()
        voiceInput.error = nil
        voiceInput.transcript = ""
        extractor.configure(result: ExtractionResult(todos: [], ignored: ""))
    }
}
