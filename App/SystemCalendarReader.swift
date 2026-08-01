import EventKit
import Foundation

/// 系统日历读取实现,对称于 `SystemCalendarWriter`。
///
/// 第一版本支持两条路径:
/// - `fetchEvents(from:to:)` 场景 3「事件 → todo 转换」的导入列表
/// - `findConflicts(for:)` 场景 1「撞车检测」——只对有 dueDate 的 ExtractedTodo 做检测,
///   无 dueDate 的直接返回空(无时间锚点无从撞车)。
///
/// 撞车判定策略(只在时间区间真正 overlap 时报告冲突,避免误报):
/// - todo 有明确钟点(`dueTime` 合成成功)→ 视为 [anchor, anchor + 默认时长],
///   与日历事件做区间 overlap 判定。查询窗口适当放宽(±2 小时)以覆盖跨边界事件,
///   再客户端精确过滤。
/// - todo 仅有日期(无钟点)→ 视为当天全天区间,与日历事件 overlap。
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
            throw VoiceTodoError.storageReadFailed(SystemCalendarReadPermissionDeniedMessage)
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
            throw VoiceTodoError.storageReadFailed(SystemCalendarReadPermissionDeniedMessage)
        }

        // 用 combine 把 dueDate + dueTime 合成精确时间。
        let combined = TodoDueTimeResolver.combine(date: dueDate, dueTime: todo.dueTime, calendar: calendar)

        // 计算 todo 区间 [todoStart, todoEnd) 和查询窗口 [windowStart, windowEnd]。
        // 查询窗口比 todo 区间稍宽以覆盖边界事件,后续客户端 overlap 精确过滤。
        let todoStart: Date
        let todoEnd: Date
        let windowStart: Date
        let windowEnd: Date
        if combined.hasTime, let anchor = combined.date {
            todoStart = anchor
            todoEnd = anchor.addingTimeInterval(Self.defaultTimedDuration)
            windowStart = anchor.addingTimeInterval(-Self.timedWindowMargin)
            windowEnd = anchor.addingTimeInterval(Self.defaultTimedDuration + Self.timedWindowMargin)
        } else {
            // 无钟点:todo 视为当天全天;window 等于 todo 区间即可。
            let dayStart = calendar.startOfDay(for: dueDate)
            todoStart = dayStart
            todoEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            windowStart = todoStart
            windowEnd = todoEnd
        }

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        // 客户端精确 overlap 过滤:
        // - 区间相交:max(start1, start2) < min(end1, end2)
        // - 排除订阅/生日等只读日历(isImmutable),这类事件用户改不了,报告它们只是噪音。
        //   `event.calendar` 可能为 nil(事件所属日历被删),nil 视为「不可变」过滤掉,
        //   避免对孤儿事件做 force-unwrap 崩溃。
        let conflicts = events
            .filter { !$0.isDetached && !($0.calendar?.isImmutable ?? true) }
            .filter { event in
                // 全天事件 EKEvent 的 endDate 通常是「次日 00:00」(exclusive),与 todo 区间
                // overlap 判定:max(todoStart, event.startDate) < min(todoEnd, event.endDate)
                let overlapStart = max(todoStart, event.startDate)
                let overlapEnd = min(todoEnd, event.endDate)
                return overlapStart < overlapEnd
            }
            .map(Self.toExternal)

        VoiceTodoLog.calendar.info("system_calendar.conflict.result id=\(conflictID, privacy: .public) conflictCount=\(conflicts.count) windowStart=\(windowStart.timeIntervalSince1970) windowEnd=\(windowEnd.timeIntervalSince1970) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return conflicts
    }

    /// 定时 todo 的默认持续时长(无明确结束时间时假设):1 小时。
    /// 用于与日历事件做 overlap 判定——todo 本身没「时长」概念,需要给一个合理假设。
    private static let defaultTimedDuration: TimeInterval = 3600

    /// 定时 todo 的查询窗口余量(单侧):2 小时。
    /// 比 defaultTimedDuration 稍大,确保查询边界附近的事件也能被读到再客户端精确过滤。
    private static let timedWindowMargin: TimeInterval = 7200

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
