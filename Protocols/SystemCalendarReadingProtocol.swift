import Foundation

/// 系统日历事件的跨模块 DTO。协议层不依赖 EventKit,跟 `SystemCalendarEventDraft`
/// 用同样的隔离策略——上层(UI / AppCoordinator)只看这个 DTO,不接触 `EKEvent`。
///
/// 第一版本用于:
/// - 场景 3「事件 → todo 转换」:导入列表展示
/// - 场景 1「撞车检测」:ConfirmSheet 警告条展示冲突事件
struct ExternalCalendarEvent: Identifiable, Sendable, Equatable {
    /// `EKEvent.eventIdentifier`,跨进程稳定。空串表示 EKEvent 缺 identifier(理论上罕见),
    /// 调用方应用 `id.isEmpty` 兜底而非直接当唯一键使用。
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// 所属日历标题(如「工作」、「家庭」),用于 UI 显示来源。
    let calendarTitle: String?
}

/// 系统日历读取协议,对称于 `SystemCalendarWritingProtocol`。
/// 实现见 `App/SystemCalendarReader.swift`。
protocol SystemCalendarReadingProtocol {
    /// 拉取指定时间段内的所有系统日历事件。
    /// - Parameters:
    ///   - from: 起始时间(含)
    ///   - to: 结束时间(含)
    /// - Returns: 时间段内的事件列表,按 startDate 升序
    /// - Throws: `VoiceTodoError.storageReadFailed` 包装的权限拒绝 / 读取失败。
    ///   权限拒绝的错误 message 固定为 `SystemCalendarReadPermissionDeniedMessage`,
    ///   调用方可据此精确判定并引导用户去设置(而不是显示通用错误)。
    func fetchEvents(from: Date, to: Date) async throws -> [ExternalCalendarEvent]

    /// 检测单条 ExtractedTodo 是否跟系统日历已有事件撞车。
    /// 用于场景 1「避免重复录入」:用户语音记的待办如果跟日历事件同时段,
    /// 在 ConfirmSheet 给警告(不阻断确认,仅提示)。
    /// - Parameter todo: 待检测的提取结果
    /// - Returns: 撞车的事件列表;空数组表示无冲突
    func findConflicts(for todo: ExtractedTodo) async throws -> [ExternalCalendarEvent]
}

/// 系统日历读取权限拒绝时,Reader 抛 `VoiceTodoError.storageReadFailed(message)` 的固定
/// message 常量。调用方(如 CalendarImportView)通过比较 message 是否等于此值来精确识别
/// 权限拒绝,而不是把它当成普通读失败显示通用错误。
/// 不用 VoiceTodoError 新 case 是为了不扩大 enum 公开 API 的波及面。
let SystemCalendarReadPermissionDeniedMessage = "System calendar permission denied"
