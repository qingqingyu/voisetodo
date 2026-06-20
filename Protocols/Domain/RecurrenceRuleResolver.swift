import Foundation

/// 轻量重复规则解析器：只处理 v1 明确表达，模糊表达继续交给 dueHint。
enum RecurrenceRuleResolver {
    static func resolve(
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> RecurrenceRule? {
        let text = normalizedText(dueHint: dueHint, title: title, detail: detail)
        guard !text.isEmpty else { return nil }

        let endDate = inferredEndDate(
            in: text,
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        )

        let lower = text.lowercased()
        if text.contains("每天") || text.contains("每日") ||
            lower.containsEnglishPhrase("every day") ||
            lower.containsEnglishPhrase("daily") {
            return RecurrenceRule(frequency: .daily, endDate: endDate)
        }

        if let monthlyDay = monthlyDay(in: text) {
            return RecurrenceRule(frequency: .monthly, dayOfMonth: monthlyDay, endDate: endDate)
        }

        if isWeeklyExpression(text) {
            let weekdays = weekdayNumbers(in: text)
            if !weekdays.isEmpty {
                return RecurrenceRule(frequency: .weekly, weekdays: weekdays, endDate: endDate)
            }
        }

        return nil
    }

    static func ruleWithInferredEndDate(
        _ rule: RecurrenceRule?,
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> RecurrenceRule? {
        guard var rule else {
            return resolve(
                dueHint: dueHint,
                title: title,
                detail: detail,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
        guard rule.endDate == nil else { return rule }

        let text = normalizedText(dueHint: dueHint, title: title, detail: detail)
        rule.endDate = inferredEndDate(
            in: text,
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return rule
    }

    private static func normalizedText(dueHint: String?, title: String, detail: String) -> String {
        let text = [dueHint, title, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text
    }

    private static func inferredEndDate(
        in text: String,
        dueHint: String?,
        title: String,
        detail: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        guard let dayCount = durationDays(in: text), dayCount > 0 else { return nil }
        let start = TodoDueDateResolver.resolve(
            dueHint: dueHint,
            title: title,
            detail: detail,
            referenceDate: referenceDate,
            calendar: calendar
        ) ?? calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: dayCount - 1, to: calendar.startOfDay(for: start))
    }

    private static func durationDays(in text: String) -> Int? {
        let compactText = text.replacingOccurrences(of: " ", with: "")
        let chinesePatterns = [
            #"(?:(?:未来|接下来|接下来的|连续|连着|往后|之后的|未来的))([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天"#,
            #"([0-9]{1,3}|[一二两三四五六七八九十]{1,3})天(?:内|里|之内)"#
        ]
        for pattern in chinesePatterns {
            if let value = firstRegexCapture(pattern, in: compactText),
               let days = parseDayCount(value),
               (1...366).contains(days) {
                return days
            }
        }

        let lower = text.lowercased()
        let englishPatterns = [
            #"over\s+the\s+next\s+([0-9]{1,3})\s+days"#,
            #"for\s+(?:the\s+)?next\s+([0-9]{1,3})\s+days"#,
            #"next\s+([0-9]{1,3})\s+days"#,
            #"for\s+([0-9]{1,3})\s+days"#
        ]
        for pattern in englishPatterns {
            if let value = firstRegexCapture(pattern, in: lower),
               let days = Int(value),
               (1...366).contains(days) {
                return days
            }
        }

        return nil
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func parseDayCount(_ raw: String) -> Int? {
        if let value = Int(raw) { return value }

        let values: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if raw == "十" { return 10 }
        if raw.contains("十") {
            let parts = raw.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts.first?.first.flatMap { values[$0] } ?? 1
            let ones = parts.dropFirst().first?.first.flatMap { values[$0] } ?? 0
            return tens * 10 + ones
        }
        return raw.first.flatMap { values[$0] }
    }

    private static func isWeeklyExpression(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("每周") ||
            text.contains("每星期") ||
            text.contains("每礼拜") ||
            lower.containsEnglishPhrase("every week") ||
            lower.containsEnglishPhrase("weekly") ||
            TodoDueDateResolver.englishWeekdays.contains { entry in
                entry.tokens.contains { lower.containsEnglishPhrase("every \($0)") }
            }
    }

    private static func weekdayNumbers(in text: String) -> [Int] {
        let chineseWeekdays: [(tokens: [String], value: Int)] = [
            (["周日", "星期日", "礼拜日", "周天", "星期天", "礼拜天", "每周日", "每星期日"], 1),
            (["周一", "星期一", "礼拜一", "每周一", "每星期一"], 2),
            (["周二", "星期二", "礼拜二", "每周二", "每星期二"], 3),
            (["周三", "星期三", "礼拜三", "每周三", "每星期三"], 4),
            (["周四", "星期四", "礼拜四", "每周四", "每星期四"], 5),
            (["周五", "星期五", "礼拜五", "每周五", "每星期五"], 6),
            (["周六", "星期六", "礼拜六", "每周六", "每星期六"], 7)
        ]

        var values: [Int] = chineseWeekdays.compactMap { entry in
            entry.tokens.contains { text.contains($0) } ? entry.value : nil
        }

        let lower = text.lowercased()
        for entry in TodoDueDateResolver.englishWeekdays {
            if entry.tokens.contains(where: { lower.containsEnglishPhrase("every \($0)") || lower.containsEnglishPhrase($0) }) {
                values.append(entry.value)
            }
        }

        return Array(Set(values)).sorted()
    }

    private static func monthlyDay(in text: String) -> Int? {
        let lower = text.lowercased()
        let hasMonthlyCue = text.contains("每月") ||
            text.contains("每个月") ||
            lower.containsEnglishPhrase("every month") ||
            lower.containsEnglishPhrase("monthly")
        guard hasMonthlyCue else { return nil }

        let patterns = [
            #"每(?:个)?月\s*(\d{1,2})\s*[号日]"#,
            #"monthly\s+on\s+the\s+(\d{1,2})"#,
            #"every\s+month\s+on\s+the\s+(\d{1,2})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let dayRange = Range(match.range(at: 1), in: text),
                  let day = Int(text[dayRange]),
                  (1...31).contains(day) else {
                continue
            }
            return day
        }

        return nil
    }
}
