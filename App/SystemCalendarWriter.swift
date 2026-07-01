import EventKit
import Foundation

struct SystemCalendarWriteResult: Equatable {
    let todoId: UUID
    let eventIdentifier: String
}

struct SystemCalendarWriteError: Error {
    let results: [SystemCalendarWriteResult]
    let underlyingError: Error
}

struct SystemCalendarEventDraft: Equatable {
    let todoId: UUID
    let title: String
    let notes: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let recurrenceRule: RecurrenceRule?
}

protocol SystemCalendarWritingProtocol {
    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult]
    func removeEvents(identifiers: [String]) async throws
}

enum SystemCalendarEventMapper {
    static func draft(from todo: TodoItemData, calendar: Calendar = .current) -> SystemCalendarEventDraft? {
        guard todo.dueDate != nil || todo.recurrenceRule != nil else { return nil }

        // 带明确钟点 → 定时事件（默认 1 小时时长）；否则全天事件。
        let isTimed = todo.hasDueTime && todo.dueDate != nil
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        if isTimed, let due = todo.dueDate {
            startDate = due
            endDate = due.addingTimeInterval(Self.defaultTimedDuration)
            isAllDay = false
        } else {
            startDate = calendar.startOfDay(for: todo.dueDate ?? todo.createdAt)
            endDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86_400)
            isAllDay = true
        }
        let notes = [
            todo.detail,
            todo.dueHint.map { String(localized: "system_calendar.notes_due_hint \($0)") },
            String(localized: "system_calendar.notes_source")
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return SystemCalendarEventDraft(
            todoId: todo.id,
            title: todo.title,
            notes: notes.isEmpty ? nil : notes,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            recurrenceRule: todo.recurrenceRule
        )
    }

    /// 定时事件的默认时长（无结束时间线索时）：1 小时。
    static let defaultTimedDuration: TimeInterval = 3600
}

final class SystemCalendarWriter: SystemCalendarWritingProtocol {
    private let eventStore: EKEventStore
    private let calendar: Calendar

    init(eventStore: EKEventStore = EKEventStore(), calendar: Calendar = .current) {
        self.eventStore = eventStore
        self.calendar = calendar
    }

    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult] {
        let writeID = VoiceTodoLog.makeID("syscal-write")
        let startedAt = Date()
        let writableTodos = todos.filter {
            $0.systemCalendarEventIdentifier == nil
                && SystemCalendarEventMapper.draft(from: $0, calendar: calendar) != nil
        }
        VoiceTodoLog.calendar.info("system_calendar.write.start id=\(writeID, privacy: .public) inputCount=\(todos.count) writableCount=\(writableTodos.count) ids=\(VoiceTodoLog.idsSummary(writableTodos.map(\.id)), privacy: .public)")
        guard !writableTodos.isEmpty else {
            VoiceTodoLog.calendar.info("system_calendar.write.skipped id=\(writeID, privacy: .public) reason=no_writable_todos durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return []
        }

        guard try await requestWriteAccess() else {
            VoiceTodoLog.calendar.warning("system_calendar.write.denied id=\(writeID, privacy: .public)")
            throw VoiceTodoError.storageWriteFailed("System calendar access denied")
        }

        guard let destinationCalendar = eventStore.defaultCalendarForNewEvents else {
            VoiceTodoLog.calendar.error("system_calendar.write.no_default_calendar id=\(writeID, privacy: .public)")
            throw VoiceTodoError.storageWriteFailed("No writable system calendar")
        }

        var results: [SystemCalendarWriteResult] = []
        for todo in writableTodos {
            guard let draft = SystemCalendarEventMapper.draft(from: todo, calendar: calendar) else { continue }
            let event = EKEvent(eventStore: eventStore)
            event.calendar = destinationCalendar
            event.title = draft.title
            event.notes = draft.notes
            event.startDate = draft.startDate
            event.endDate = draft.endDate
            event.isAllDay = draft.isAllDay

            if let recurrenceRule = draft.recurrenceRule {
                event.addRecurrenceRule(ekRecurrenceRule(from: recurrenceRule))
            }

            do {
                try eventStore.save(event, span: .futureEvents)
                VoiceTodoLog.calendar.info("system_calendar.event.save_success id=\(writeID, privacy: .public) todoID=\(draft.todoId.uuidString, privacy: .public) hasRecurrence=\(draft.recurrenceRule != nil)")
            } catch {
                VoiceTodoLog.calendar.error("system_calendar.event.save_failed id=\(writeID, privacy: .public) todoID=\(draft.todoId.uuidString, privacy: .public) partialResults=\(results.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                throw SystemCalendarWriteError(results: results, underlyingError: storageWriteFailure(error))
            }
            guard let eventIdentifier = event.eventIdentifier else {
                VoiceTodoLog.calendar.error("system_calendar.event.missing_identifier id=\(writeID, privacy: .public) todoID=\(draft.todoId.uuidString, privacy: .public) partialResults=\(results.count)")
                throw SystemCalendarWriteError(
                    results: results,
                    underlyingError: VoiceTodoError.storageWriteFailed("System calendar event identifier missing")
                )
            }
            results.append(SystemCalendarWriteResult(todoId: draft.todoId, eventIdentifier: eventIdentifier))
        }
        VoiceTodoLog.calendar.info("system_calendar.write.success id=\(writeID, privacy: .public) resultCount=\(results.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return results
    }

    func removeEvents(identifiers: [String]) async throws {
        let removeID = VoiceTodoLog.makeID("syscal-remove")
        let startedAt = Date()
        VoiceTodoLog.calendar.info("system_calendar.remove.start id=\(removeID, privacy: .public) count=\(identifiers.count)")
        var firstError: Error?
        var removedCount = 0
        var missingCount = 0

        for identifier in identifiers {
            if let event = eventStore.event(withIdentifier: identifier) {
                do {
                    try eventStore.remove(event, span: .futureEvents)
                    removedCount += 1
                    VoiceTodoLog.calendar.info("system_calendar.remove.event_success id=\(removeID, privacy: .public) eventID=\(identifier, privacy: .public)")
                } catch {
                    VoiceTodoLog.calendar.error("system_calendar.remove.event_failed id=\(removeID, privacy: .public) eventID=\(identifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    firstError = firstError ?? error
                }
            } else {
                missingCount += 1
                VoiceTodoLog.calendar.warning("system_calendar.remove.event_missing id=\(removeID, privacy: .public) eventID=\(identifier, privacy: .public)")
            }
        }

        if let firstError {
            VoiceTodoLog.calendar.error("system_calendar.remove.failed id=\(removeID, privacy: .public) removed=\(removedCount) missing=\(missingCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(firstError), privacy: .public)")
            throw storageWriteFailure(firstError)
        }
        VoiceTodoLog.calendar.info("system_calendar.remove.success id=\(removeID, privacy: .public) removed=\(removedCount) missing=\(missingCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    private func requestWriteAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestWriteOnlyAccessToEvents { granted, error in
                if let error {
                    VoiceTodoLog.calendar.error("system_calendar.permission.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    continuation.resume(throwing: self.storageWriteFailure(error))
                } else {
                    VoiceTodoLog.calendar.info("system_calendar.permission.result granted=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func ekRecurrenceRule(from rule: RecurrenceRule) -> EKRecurrenceRule {
        let recurrenceEnd = rule.endDate.map { EKRecurrenceEnd(end: calendar.startOfDay(for: $0)) }

        switch rule.frequency {
        case .daily:
            return EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 1,
                end: recurrenceEnd
            )
        case .weekly:
            let daysOfWeek = rule.weekdays.compactMap { weekday -> EKRecurrenceDayOfWeek? in
                guard let ekWeekday = EKWeekday(rawValue: weekday) else { return nil }
                return EKRecurrenceDayOfWeek(ekWeekday)
            }
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: daysOfWeek,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: recurrenceEnd
            )
        case .monthly:
            let daysOfMonth = rule.dayOfMonth.map { [NSNumber(value: $0)] }
            return EKRecurrenceRule(
                recurrenceWith: .monthly,
                interval: 1,
                daysOfTheWeek: nil,
                daysOfTheMonth: daysOfMonth,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: recurrenceEnd
            )
        }
    }

    private func storageWriteFailure(_ error: Error) -> VoiceTodoError {
        if let voiceError = error as? VoiceTodoError {
            return voiceError
        }
        return VoiceTodoError.storageWriteFailed(error.localizedDescription)
    }
}
