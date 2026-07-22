import AppIntents
import Foundation

/// Siri / Apple Intelligence 可识别的待办实体。
///
/// 将跨模块 DTO `TodoItemData` 映射为 AppEntity,让 Siri 能通过自然语言引用具体某条待办
/// (如"完成 [买菜]"、"删除 [健身]"里的"买菜"/"健身"通过 `TodoEntityQuery.entities(matching:)` 解析)。
/// 不依赖 SwiftData 类型,保持与既有 DTO 边界一致。
struct TodoEntity: AppEntity {
    /// 实体稳定标识,复用 `TodoItem.id` (UUID)。AppEntity 要求 Hashable,UUID 满足。
    let id: UUID

    /// 实体显示标题 (todo 标题原文)。用于 Siri 朗读与 snippet 列表。
    let title: String
    /// 截止时间提示文本 (如"明天 15:00");nil 表示无明确时间。
    let dueHint: String?
    /// 当前完成状态。重复任务的"今日 occurrence"完成态由 `TodoEntityQuery` 计算后写入此字段。
    let isCompleted: Bool
    /// 优先级,驱动 Siri snippet 中的红圈角标显示。
    let priority: Priority
    /// 分类,驱动 Siri snippet 中的 SF Symbol 图标。
    let category: TodoCategory

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "siri.entity.todo.title"
    static var defaultQuery = TodoEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        // `subtitle` 期望 LocalizedStringResource?,需要把 String?
        // 通过 map + 字符串插值字面量转换 —— LocalizedStringResource
        // 是 ExpressibleByStringInterpolation,在 map 返回类型推断为
        // LocalizedStringResource? 的上下文里 "\($0)" 会自动变成那个类型。
        let subtitleResource: LocalizedStringResource? = dueHint.map { "\($0)" }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitleResource ?? "",
            image: .init(systemName: category.sfSymbolName)
        )
    }

    /// 从跨模块 DTO 构造。唯一的构造入口 —— AppEntity 永远不直接接受 SwiftData `TodoItem`。
    init(from data: TodoItemData) {
        self.id = data.id
        self.title = data.title
        self.dueHint = data.dueHint
        self.isCompleted = data.isCompleted
        self.priority = data.priority
        self.category = data.category
    }
}
