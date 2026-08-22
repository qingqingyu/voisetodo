import Foundation
import SwiftData

/// 复盘埋点事件(拍板 3:只记 `deferred | abandoned | split`,推导得出的
/// created/completed/reopened 不记)。
///
/// 为什么用事件表而不是 `TodoItem` 上放一个 deferCount 计数器:计数器在编辑、
/// 撤销、跨设备同步时会失真,且无法回答「这次推迟发生在什么时候、从哪天推到哪天」。
///
/// - Migration: 纯 additive,走 SwiftData 轻量迁移;字段全 optional 或带默认值。
///   在 `VoiceTodoSchema.schema` 注册——Widget 的 `readOnly()` 容器打开同一个库,
///   schema 必须一致(`VoiceTodoSchema` 是单一来源)。
@Model
final class TaskEvent {
    @Attribute(.unique) var id: UUID
    var todoId: UUID
    /// `TaskEventType` 原始字符串:deferred | abandoned | split(拍板 3)。
    /// 通过 computed `type` 类型安全访问。
    var typeRaw: String
    /// deferred 时的原 dueDate。
    var fromDate: Date?
    /// deferred 时的新 dueDate。
    var toDate: Date?
    var at: Date
    /// `TaskEventOrigin` 原始字符串:app | review | detail(拍板 5:无 widget)。
    /// 通过 computed `origin` 类型安全访问。
    var originRaw: String

    /// 热查询索引(todoId 反查 / 区间扫描 / 类型过滤)。纯 additive,轻量迁移。
    #Index<TaskEvent>([\.todoId], [\.at], [\.typeRaw])

    init(
        id: UUID = UUID(),
        todoId: UUID,
        type: TaskEventType,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        at: Date = Date(),
        origin: TaskEventOrigin
    ) {
        self.id = id
        self.todoId = todoId
        self.typeRaw = type.rawValue
        self.fromDate = fromDate
        self.toDate = toDate
        self.at = at
        self.originRaw = origin.rawValue
    }

    /// 事件类型(类型安全,只读)。Raw 解析失败返回 nil 而非猜测默认值——
    /// 脏数据(如手动改库)由查询方显式跳过,不静默归到某个事件类型。
    /// 类型化写入只经 `init(type:)`,不提供 setter,杜绝「写 nil 落成 deferred」的伪造路径。
    var type: TaskEventType? {
        TaskEventType.tolerant(typeRaw)
    }

    /// 事件来源(类型安全,只读)。容错构造与 `type` 同策略。
    var origin: TaskEventOrigin? {
        TaskEventOrigin.tolerant(originRaw)
    }
}
