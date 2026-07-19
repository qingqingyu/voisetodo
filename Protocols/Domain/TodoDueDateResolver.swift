import Foundation

/// 待办日期解析工具：把 AI 返回的自然语言时间提示转换成自然日
enum TodoDueDateResolver {
    static func resolve(
        dueHint: String?,
        title: String = "",
        detail: String = "",
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let text = [dueHint, title, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !text.isEmpty else { return nil }

        let today = DayClock.startOfUserDay(for: referenceDate, calendar: calendar)
        let lowercasedText = text.lowercased()

        if text.contains("今天") || text.contains("今晚") ||
            lowercasedText.containsEnglishPhrase("today") ||
            lowercasedText.containsEnglishPhrase("tonight") {
            return today
        }
        if text.contains("后天") ||
            lowercasedText.containsEnglishPhrase("day after tomorrow") {
            return calendar.date(byAdding: .day, value: 2, to: today)
        }
        if text.contains("明天") || text.contains("明晚") ||
            lowercasedText.containsEnglishPhrase("tomorrow") ||
            lowercasedText.containsEnglishPhrase("tmr") {
            return calendar.date(byAdding: .day, value: 1, to: today)
        }

        if let weekday = weekdayNumber(in: text) {
            if text.contains("下周") || text.contains("下星期") || text.contains("下礼拜") ||
                lowercasedText.containsEnglishPhrase("next week") ||
                lowercasedText.containsNextEnglishWeekday(weekday) {
                return dateInWeek(offset: 1, matchingWeekday: weekday, from: today, calendar: calendar)
            }
            return nextDate(matchingWeekday: weekday, from: today, calendar: calendar)
        }

        // N days from now / in N days / N天后
        if let offset = daysOffset(in: lowercasedText, original: text) {
            return calendar.date(byAdding: .day, value: offset, to: today)
        }

        return nil
    }

    // MARK: - Explicit Time Cue Detection (方案 3 兜底)

    /// 扫原始 transcript,判断用户是否**明确表达**了时间意图(用于反校验 AI basis)。
    ///
    /// 设计原则:
    /// - **直接时间词**(今天/明天/后天/N天后/下周X/这周末/月底)命中即 `true`
    /// - **weekday 词**默认 `true`(用户说"周日去健身"通常是 user_explicit),
    ///   但若周围有"prepare for / 为...准备"等**目标语义**(把 weekday 当作动作目标
    ///   而非时间状语),返回 `false`。
    ///
    /// 关键用例:
    /// - `"prepare for Sunday"` → false(Sunday 是"准备"的目标,不是截止日)
    /// - `"周日去健身"` → true(weekday + 动作)
    /// - `"周五前交报告"` → true(weekday + 截止"前")
    /// - `"明天交房租"` → true(直接时间词)
    /// - `nil` / `""` → false
    static func hasExplicitTimeCue(in text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        let lowercased = trimmed.lowercased()

        // 1. 直接时间词命中 → true
        if hasDirectTimeWord(trimmed, lowercased: lowercased) {
            return true
        }

        // 2. weekday 出现:默认 true,但有"目标语义"时 false
        if weekdayNumber(in: trimmed) != nil {
            return !hasTargetSemantics(lowercased: lowercased, original: trimmed)
        }

        return false
    }

    /// 直接时间词检测(高置信度):今天/明天/后天/N天后/下周X/这周末/月底等。
    /// 注意:`下周X` 在 resolve() 里走 weekday 路径,这里也复用 weekdayNumber,
    /// 但带"下周/下星期"前缀的不算"目标语义"——直接在 hasDirectTimeWord 提前返回 true。
    private static func hasDirectTimeWord(_ text: String, lowercased: String) -> Bool {
        // 相对今天/明天/后天
        if text.contains("今天") || text.contains("今晚") ||
            lowercased.containsEnglishPhrase("today") ||
            lowercased.containsEnglishPhrase("tonight") {
            return true
        }
        if text.contains("明天") || text.contains("明晚") ||
            lowercased.containsEnglishPhrase("tomorrow") ||
            lowercased.containsEnglishPhrase("tmr") {
            return true
        }
        if text.contains("后天") ||
            lowercased.containsEnglishPhrase("day after tomorrow") {
            return true
        }
        // N 天后 / in N days / N days from now(复用 daysOffset)
        if daysOffset(in: lowercased, original: text) != nil {
            return true
        }
        // 下周/下星期/下礼拜 + weekday(这种结构意图明确,weekday 不可能是"目标")
        if text.contains("下周") || text.contains("下星期") || text.contains("下礼拜") ||
            lowercased.containsEnglishPhrase("next week") {
            return true
        }
        // 这周末/本周末/下周末/this weekend/next weekend
        if text.contains("这周末") || text.contains("本周末") || text.contains("下周末") ||
            lowercased.containsEnglishPhrase("this weekend") ||
            lowercased.containsEnglishPhrase("next weekend") {
            return true
        }
        // 月底/月初/月中/end of month
        if text.contains("月底") || text.contains("月初") || text.contains("月中") ||
            lowercased.containsEnglishPhrase("end of month") ||
            lowercased.containsEnglishPhrase("end of this month") {
            return true
        }
        return false
    }

    /// "目标语义"检测:把 weekday 当作动作目标而非时间状语。
    /// 命中即返回 true(在 hasExplicitTimeCue 中取反)。
    ///
    /// 已知覆盖模式(保守起步,边界用测试用例固化):
    /// - 英文:`prepare for X` / `get ready for X` / `prep for X` / `ready for X`
    /// - 中文:`为 X 准备` / `为 X 做` / `为 X 打算`(必须在同一文本中出现"为"+ 动词)
    ///
    /// 不覆盖:`on Sunday` / `by Friday` / `周日去健身` / `周五前交报告`——这些是合法
    /// 时间状语,不应被识别为目标语义。
    private static func hasTargetSemantics(lowercased: String, original: String) -> Bool {
        // 英文目标介词短语
        let targetPhrases = ["prepare for", "get ready for", "prep for", "ready for"]
        if targetPhrases.contains(where: { lowercased.contains($0) }) {
            return true
        }
        // 中文"为...准备/做/打算"——必须同时出现"为"+ 目标动词
        if original.contains("为") {
            let targetVerbs: [String] = ["准备", "做", "打算", "筹办", "筹划"]
            if targetVerbs.contains(where: { original.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Relative Days Offset

    /// 英文数字词映射（"three" → 3），用于解析 "three days from now"
    private static let englishNumberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30
    ]

    /// 中文数字单字映射（"三" → 3），用于解析 "三天后"
    private static let chineseNumerals: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "两": 2
    ]

    /// 从文本中提取 "N days from now" / "in N days" / "N天后" 的天数偏移。
    /// 支持阿拉伯数字和英文/中文拼写数字。
    private static func daysOffset(in lowercased: String, original: String) -> Int? {
        // 英文数字词："three days from now", "in five days"
        for (word, value) in englishNumberWords {
            if lowercased.contains("\(word) days") || lowercased.contains("\(word) day ") {
                return value
            }
        }

        // 英文阿拉伯数字："3 days from now", "in 3 days", "3 days later"
        if let regex = try? NSRegularExpression(pattern: #"(?:in\s+|)(\d+)\s+days?\b"#, options: []) {
            let nsRange = NSRange(location: 0, length: lowercased.utf16.count)
            if let match = regex.firstMatch(in: lowercased, options: [], range: nsRange), match.numberOfRanges > 1,
               let captureRange = Range(match.range(at: 1), in: lowercased) {
                return Int(lowercased[captureRange])
            }
        }

        // 中文数字："三天后", "五天之后"
        if let idx = original.range(of: "天") {
            let before = original[..<idx.lowerBound]
            if let lastChar = before.last, let value = chineseNumerals[lastChar] {
                let after = original[idx.upperBound...]
                if after.hasPrefix("后") || after.hasPrefix("後") ||
                   after.hasPrefix("之后") || after.hasPrefix("之後") ||
                   after.hasPrefix("以后") || after.hasPrefix("以後") {
                    return value
                }
            }
        }

        // 中文阿拉伯数字："3天后", "5天之后"
        if let regex = try? NSRegularExpression(pattern: #"(\d+)天"#, options: []) {
            let nsRange = NSRange(location: 0, length: original.utf16.count)
            if let match = regex.firstMatch(in: original, options: [], range: nsRange), match.numberOfRanges > 1,
               let captureRange = Range(match.range(at: 1), in: original),
               let n = Int(original[captureRange]) {
                // 确认后面跟着 后/之后/以后
                let after = original[Range(match.range, in: original)!.upperBound...]
                if after.hasPrefix("后") || after.hasPrefix("後") ||
                   after.hasPrefix("之后") || after.hasPrefix("之後") ||
                   after.hasPrefix("以后") || after.hasPrefix("以後") {
                    return n
                }
            }
        }

        return nil
    }

    private static func weekdayNumber(in text: String) -> Int? {
        let weekdays: [(tokens: [String], value: Int)] = [
            (["周日", "星期日", "礼拜日", "周天", "星期天", "礼拜天"], 1),
            (["周一", "星期一", "礼拜一"], 2),
            (["周二", "星期二", "礼拜二"], 3),
            (["周三", "星期三", "礼拜三"], 4),
            (["周四", "星期四", "礼拜四"], 5),
            (["周五", "星期五", "礼拜五"], 6),
            (["周六", "星期六", "礼拜六"], 7)
        ]

        if let chineseWeekday = weekdays.first(where: { entry in
            entry.tokens.contains { text.contains($0) }
        })?.value {
            return chineseWeekday
        }

        let lowercasedText = text.lowercased()
        return englishWeekdays.first { entry in
            entry.tokens.contains { lowercasedText.containsEnglishPhrase($0) }
        }?.value
    }

    static let englishWeekdays: [(tokens: [String], value: Int)] = [
        (["sunday", "sun"], 1),
        (["monday", "mon"], 2),
        (["tuesday", "tue", "tues"], 3),
        (["wednesday", "wed"], 4),
        (["thursday", "thu", "thur", "thurs"], 5),
        (["friday", "fri"], 6),
        (["saturday", "sat"], 7)
    ]

    private static func nextDate(matchingWeekday weekday: Int, from today: Date, calendar: Calendar) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysAhead = (weekday - currentWeekday + 7) % 7
        let offset = daysAhead == 0 ? 7 : daysAhead
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    private static func dateInWeek(offset: Int, matchingWeekday weekday: Int, from today: Date, calendar: Calendar) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (currentWeekday + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysFromMonday + offset * 7, to: today) else {
            return nil
        }
        let mondayBasedOffset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: mondayBasedOffset, to: weekStart)
    }
}

extension String {
    func containsEnglishPhrase(_ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        return range(
            of: "(?<![A-Za-z])\(escaped)(?![A-Za-z])",
            options: .regularExpression
        ) != nil
    }

    func containsNextEnglishWeekday(_ weekday: Int) -> Bool {
        guard let tokens = TodoDueDateResolver.englishWeekdays.first(where: { $0.value == weekday })?.tokens else {
            return false
        }
        return tokens.contains { containsEnglishPhrase("next \($0)") }
    }
}
