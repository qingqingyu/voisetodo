import EventKit
import Foundation

/// 系统日历读取实现,对称于 `SystemCalendarWriter`。
///
/// 第一版本支持两条路径:
/// - `fetchEvents(from:to:)` 场景 3「事件 → todo 转换」的导入列表
/// - `findConflicts(for:)` 场景 1「撞车检测」——只对有 dueDate 的 ExtractedTodo 做检测,
///   无 dueDate 的直接返回空(无时间锚点无从撞车)。
///
/// 撞车窗口策略:
/// - todo 有明确钟点(`dueTime` 合成成功)→ ±1 小时窗口,覆盖典型会议时长
/// - todo 仅有日期(无钟点)→ 整天窗口(00:00 - 次日 00:00),覆盖全天事件
/// - todo 无 dueDate → 跳过检测
final class SystemCalendarReader: SystemCalendarReadingProtocol {
    private let eventStore: EKEventStore
    private let calendar: Calendar

    init(eventStore: EKEventStore = EKEventStore(), calendar: Calendar = .current) {
        self.eventStore = eventStore
        self.calendar = calendar
    }

    func fetchEvents(from: Date, to: Date) async throws -> [ExternalCalendarEvent] {
        let readID = VoiceTodoLog.makeID("syscal-read")
        let startedAt = Date()
        VoiceTodoLog.calendar.info("system_calendar.read.start id=\(readID, privacy: .public) from=\(from.timeIntervalSince1970) to=\(to.timeIntervalSince1970)")

        guard try await requestCalendarAccess() else {
            VoiceTodoLog.calendar.warning("system_calendar.read.denied id=\(readID, privacy: .public)")
            throw VoiceTodoError.storageReadFailed("System calendar read access denied")
        }

        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = eventStore.events(matching: predicate)
        let result = events
            .filter { !$0.isDetached }
            .map(Self.toExternal)
            .sorted { $0.startDate < $1.startDate }

        VoiceTodoLog.calendar.info("system_calendar.read.success id=\(readID, privacy: .public) count=\(result.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return result
    }

    func findConflicts(for todo: ExtractedTodo) async throws -> [ExternalCalendarEvent] {
        let conflictID = VoiceTodoLog.makeID("syscal-conflict")
        let startedAt = Date()
        VoiceTodoLog.calendar.info("system_calendar.conflict.start id=\(conflictID, privacy: .public) todoTitle=\(VoiceTodoLog.textSummary(todo.title), privacy: .public) hasDueDate=\(todo.dueDate != nil) hasDueTime=\(todo.dueTime != nil)")

        // 无 dueDate 的 todo 无时间锚点,不做撞车检测。
        guard let dueDate = todo.dueDate else {
            VoiceTodoLog.calendar.debug("system_calendar.conflict.skipped id=\(conflictID, privacy: .public) reason=no_due_date")
            return []
        }

        guard try await requestCalendarAccess() else {
            VoiceTodoLog.calendar.warning("system_calendar.conflict.denied id=\(conflictID, privacy: .public)")
            throw VoiceTodoError.storageReadFailed("System calendar read access denied")
        }

        // 用 combine 把 dueDate + dueTime 合成精确时间。
        // hasTime=true → ±1 小时窗口(典型会议);false → 当天全天窗口(覆盖全天事件)。
        let combined = TodoDueTimeResolver.combine(date: dueDate, dueTime: todo.dueTime, calendar: calendar)
        let windowStart: Date
        let windowEnd: Date
        if combined.hasTime, let anchor = combined.date {
            windowStart = anchor.addingTimeInterval(-Self.timedConflictWindow)
            windowEnd = anchor.addingTimeInterval(Self.timedConflictWindow)
        } else {
            let dayStart = calendar.startOfDay(for: dueDate)
            windowStart = dayStart
            windowEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        }

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)
        let conflicts = events
            .filter { !$0.isDetached }
            .map(Self.toExternal)

        VoiceTodoLog.calendar.info("system_calendar.conflict.result id=\(conflictID, privacy: .public) conflictCount=\(conflicts.count) windowStart=\(windowStart.timeIntervalSince1970) windowEnd=\(windowEnd.timeIntervalSince1970) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return conflicts
    }

    /// 定时事件的撞车窗口(单侧):1 小时,覆盖典型会议时长。
    /// 用户可见的「同时段」通常指 ±1 小时内,过宽会让全天事件被误报为撞车。
    private static let timedConflictWindow: TimeInterval = 3600

    private func requestCalendarAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    VoiceTodoLog.calendar.error("system_calendar.permission.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    continuation.resume(throwing: Self.storageReadFailure(error))
                } else {
                    VoiceTodoLog.calendar.info("system_calendar.permission.result granted=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func toExternal(_ event: EKEvent) -> ExternalCalendarEvent {
        ExternalCalendarEvent(
            id: event.eventIdentifier ?? "",
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title
        )
    }

    /// 把任意错误归一化为 VoiceTodoError.storageReadFailed,与 `SystemCalendarWriter`
    /// 的 `storageWriteFailure` 对称。
    private static func storageReadFailure(_ error: Error) -> VoiceTodoError {
        if let voiceError = error as? VoiceTodoError {
            return voiceError
        }
        return VoiceTodoError.storageReadFailed(error.localizedDescription)
    }
}
