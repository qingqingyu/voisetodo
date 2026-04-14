import Foundation
import Combine

/// 待办存储协议
/// 注意：返回类型使用 TodoItemData 而非 SwiftData 的 TodoItem
protocol TodoStoreProtocol: ObservableObject {
    /// 所有待办（按创建时间倒序）
    var todos: [TodoItemData] { get }

    /// 添加单条待办
    func add(_ item: ExtractedTodo) throws

    /// 批量添加（确认界面用）
    func addBatch(_ items: [ExtractedTodo]) throws

    /// 添加原始转写文本（离线降级用）[v2]
    func addRawTranscript(_ transcript: String) throws

    /// 切换完成状态
    func toggleComplete(_ id: UUID) throws

    /// 删除待办
    func delete(_ id: UUID) throws

    /// 更新待办（支持标题、分类、优先级、时间提示）
    func update(_ id: UUID, title: String, category: TodoCategory?, priority: Priority?, dueHint: String?) throws

    /// 获取需要 AI 补处理的条目（needsAIProcessing == true）
    func pendingItems() -> [TodoItemData]

    /// 获取最近 N 条未完成待办（Widget 用）
    func recentUncompleted(limit: Int) -> [TodoItemData]

    /// 替换待处理条目为提取结果（网络恢复后用）[v2]
    func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo], rawTranscript: String?) throws
}
