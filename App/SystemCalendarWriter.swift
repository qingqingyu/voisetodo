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
    func removeEvents(identifiers: [String]) async
}

enum SystemCalendarEventMapper {
    static func draft(from todo: TodoItemData, calendar: Calendar = .current) -> SystemCalendarEventDraft? {
        guard todo.dueDate != nil || todo.recurrenceRule != nil else { return nil }

        let startDate = calendar.startOfDay(for: todo.dueDate ?? todo.createdAt)
        let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86_400)
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
            isAllDay: true,
            recurrenceRule: todo.recurrenceRule
        )
    }
}

final class SystemCalendarWriter: SystemCalendarWritingProtocol {
    private let eventStore: EKEventStore
    private let calendar: Calendar

    init(eventStore: EKEventStore = EKEventStore(), calendar: Calendar = .current) {
        self.eventStore = eventStore
        self.calendar = calendar
    }

    func writeEvents(for todos: [TodoItemData]) async throws -> [SystemCalendarWriteResult] {
        let writableTodos = todos.filter {
            $0.systemCalendarEventIdentifier == nil
                && SystemCalendarEventMapper.draft(from: $0, calendar: calendar) != nil
        }
        guard !writableTodos.isEmpty else { return [] }

        guard try await requestWriteAccess() else {
            throw VoiceTodoError.storageWriteFailed("System calendar access denied")
        }

        guard let destinationCalendar = eventStore.defaultCalendarForNewEvents else {
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
            } catch {
                rollbackSavedEvents(results)
                throw SystemCalendarWriteError(results: [], underlyingError: error)
            }
            guard let eventIdentifier = event.eventIdentifier else {
                rollbackSavedEvents(results)
                throw SystemCalendarWriteError(
                    results: [],
                    underlyingError: VoiceTodoError.storageWriteFailed("System calendar event identifier missing")
                )
            }
            results.append(SystemCalendarWriteResult(todoId: draft.todoId, eventIdentifier: eventIdentifier))
        }
        return results
    }

    func removeEvents(identifiers: [String]) async {
        for identifier in identifiers {
            if let event = eventStore.event(withIdentifier: identifier) {
                try? eventStore.remove(event, span: .futureEvents)
            }
        }
    }

    private func rollbackSavedEvents(_ results: [SystemCalendarWriteResult]) {
        for result in results {
            if let event = eventStore.event(withIdentifier: result.eventIdentifier) {
                try? eventStore.remove(event, span: .futureEvents)
            }
        }
    }

    private func requestWriteAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestWriteOnlyAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
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
}
