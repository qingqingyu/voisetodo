import Foundation
import Combine

/// Mock Store（Agent D 使用）
/// 用于 UI 开发和预览，不依赖 SwiftData
class MockStore: TodoStoreProtocol {
    @Published var todos: [TodoItemData]

    init(todos: [TodoItemData] = []) {
        self.todos = todos
    }

    // MARK: - TodoStoreProtocol

    func add(_ item: ExtractedTodo) throws {
        let todo = TodoItemData(from: item)
        todos.insert(todo, at: 0)
    }

    func addBatch(_ items: [ExtractedTodo]) throws {
        let newTodos = items.map { TodoItemData(from: $0) }
        todos.insert(contentsOf: newTodos, at: 0)
    }

    func addRawTranscript(_ transcript: String) throws {
        let title = String(transcript.prefix(20))
        let todo = TodoItemData(
            title: title,
            detail: transcript,
            rawTranscript: transcript,
            needsAIProcessing: true
        )
        todos.insert(todo, at: 0)
    }

    func toggleComplete(_ id: UUID) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].isCompleted.toggle()
        }
    }

    func delete(_ id: UUID) throws {
        todos.removeAll { $0.id == id }
    }

    func update(_ id: UUID, title: String) throws {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].title = title
        }
    }

    func pendingItems() -> [TodoItemData] {
        return todos.filter { $0.needsAIProcessing }
    }

    func recentUncompleted(limit: Int) -> [TodoItemData] {
        return todos
            .filter { !$0.isCompleted }
            .prefix(limit)
            .map { $0 }
    }

    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo]) throws {
        // 删除待处理条目
        todos.removeAll { $0.id == pendingId }

        // 插入提取结果
        let newTodos = items.map { TodoItemData(from: $0) }
        todos.insert(contentsOf: newTodos, at: 0)
    }
}

// MARK: - Preview Helpers

extension MockStore {
    /// 包含示例数据的 Mock Store
    static var preview: MockStore {
        MockStore(todos: [
            TodoItemData(title: "完成周报", detail: "需要整理本周的工作内容", dueHint: "今天", priority: .normal, category: .work),
            TodoItemData(title: "准备面试", detail: "复习算法和系统设计", dueHint: "周三前", priority: .high, category: .work),
            TodoItemData(title: "去健身房", detail: nil, dueHint: nil, priority: .normal, category: .health, isCompleted: false),
            TodoItemData(title: "买菜", detail: "西红柿、鸡蛋、牛奶", dueHint: "今晚", priority: .normal, category: .life, isCompleted: true),
            TodoItemData(title: "给老妈打电话", detail: nil, dueHint: "周末", priority: .normal, category: .social, isCompleted: false),
            TodoItemData(title: "学习 SwiftUI", detail: "Widget 和 Live Activity", dueHint: nil, priority: .normal, category: .study, isCompleted: false),
            TodoItemData(title: "还信用卡", detail: "本月账单", dueHint: "月底前", priority: .high, category: .finance, isCompleted: false)
        ])
    }

    /// 空数据的 Mock Store
    static var empty: MockStore {
        MockStore(todos: [])
    }

    /// 包含待处理项的 Mock Store
    static var withPendingItems: MockStore {
        MockStore(todos: [
            TodoItemData(
                title: "原始转写文本...",
                detail: "这是一段完整的语音转写文本，等待 AI 提取",
                rawTranscript: "这是一段完整的语音转写文本，等待 AI 提取",
                needsAIProcessing: true
            ),
            TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
        ])
    }
}

// MARK: - Mock Services (for Preview)

/// Mock 语音输入（Preview 用）
final class MockVoiceInput: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }

    func startRecording() async throws {}
    func stopRecording() {}
}

/// Mock 待办提取器（Preview 用）
struct MockExtractor: TodoExtractorProtocol {
    func extract(from transcript: String) async throws -> ExtractionResult {
        ExtractionResult(todos: [], ignored: "")
    }

    func fallbackExtract(from transcript: String) -> ExtractionResult {
        ExtractionResult(todos: [], ignored: "")
    }
}

/// 便捷方法：创建用于 Preview 的 Mock AppCoordinator
extension AppCoordinator {
    static var preview: AppCoordinator {
        AppCoordinator(
            voiceInput: MockVoiceInput(),
            extractor: MockExtractor(),
            store: MockStore.preview
        )
    }
}
