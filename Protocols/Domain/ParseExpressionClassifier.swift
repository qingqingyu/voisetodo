import Foundation

/// 原始时间说法的类型(`parse_field_corrected.expressionKind` / `parse_confirmed.kinds` 的取值)。
///
/// 输入是 AI 给出的时间短语(`dueHint`)与有无日期/钟点,在**手机本地**按关键词归类,
/// **只上传类型名——`dueHint` 原文绝不上传、也不写日志**(PII 红线,见 TELEMETRY.md)。
///
/// 规则覆盖常见说法即可,不追求完美;认不出归 `other`(`other` 占比高本身也是信号)。
/// 多个类型同时命中时按 case 声明顺序(即任务书 §3 表格从上到下)取第一个:
/// 「下周五下午三点」→ `weekday`。
enum ParseExpressionKind: String, CaseIterable, Sendable {
    /// 原始解析没有日期(也没有时间短语)。
    case none
    /// 今天 / 明天 / 后天 / 大后天。
    case relativeDay = "relative_day"
    /// 星期几(含本周 / 下周 / 下下周 / 上周 / 周末)。
    case weekday
    /// 月初 / 月中 / 月底 / 月末。
    case monthPart = "month_part"
    /// N 天 / 周 / 月 / 年后。
    case relativeOffset = "relative_offset"
    /// 具体日期(11 月 5 号 / Nov 5 / 11月5日)。
    case absoluteDate = "absolute_date"
    /// 节日(国庆 / 春节 / Christmas / 正月)。
    case holiday
    /// 只有时间没有日期(下午三点 / at 3pm / 午後3時)。
    case timeOnly = "time_only"
    /// 有 `dueHint` 但规则认不出。
    case other
}

/// 时间说法分类器(纯函数,任务书 docs/task-parse-correction-telemetry.md §3)。
///
/// 规则按 `ParseExpressionKind` 的声明顺序依次匹配,先命中先返回。三种语言的关键词
/// **并集**匹配、不按 locale 挑选——内容语言跟随用户输入而非系统语言(中英日混说
/// 在任何系统 locale 下都该分对),`locale` 参数保留给未来的语言特化规则。
///
/// 隐私红线:本类型只消费 `dueHint`,只产出枚举;调用方不得把 `dueHint` 写进
/// 任何日志或遥测参数。
enum ParseExpressionClassifier {

    // MARK: - 入口

    /// 归类一条原始解析的时间说法。
    /// - Parameters:
    ///   - dueHint: 模型给出的时间短语原文(只在本地消费)。
    ///   - hasDate: 原始解析有无 `dueDate`。
    ///   - hasTime: 原始解析有无明确钟点(`dueTime`)。
    ///   - locale: 内容语言提示(当前规则三语并集,不按它挑选)。
    /// - Returns: 说法类型;无短语且无日期为 `.none`。
    static func classify(
        dueHint: String?,
        hasDate: Bool,
        hasTime: Bool,
        locale: Locale = .current
    ) -> ParseExpressionKind {
        let hint = dueHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hint.isEmpty else {
            // 无短语:只有钟点没日期 → time_only;有日期没短语(AI 直接给了 ISO 日期)→
            // 没有说法可归类,记 other;两者皆无 → none。
            if hasTime && !hasDate { return .timeOnly }
            return hasDate ? .other : .none
        }
        let text = hint.lowercased()

        if containsAny(text, relativeDayKeywords) { return .relativeDay }
        if isWeekday(text) { return .weekday }
        if containsAny(text, monthPartKeywords) { return .monthPart }
        if isRelativeOffset(text) { return .relativeOffset }
        if isAbsoluteDate(text) { return .absoluteDate }
        if containsAny(text, holidayKeywords) { return .holiday }
        if isTimeOnly(text) || (!hasDate && hasTime) { return .timeOnly }
        return .other
    }

    // MARK: - 匹配辅助

    /// 正则字面量在编译期已校验合法性,匹配不会失败;`try?` 只为满足 throwing 签名
    /// (不会静默吞错——模式本身不可能在运行期变非法)。
    private static func matches(_ regex: Regex<Substring>, _ text: String) -> Bool {
        ((try? regex.firstMatch(in: text)) ?? nil) != nil
    }

    private static func containsAny(_ text: String, _ keywords: Set<String>) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - 星期(需要负向约束:「两周后」「三周内」的周不是星期)

    private static func isWeekday(_ text: String) -> Bool {
        matches(weekdayCharPrefixed, text)
            || matches(bareWeekPrefix, text)
            || matches(jaWeekday, text)
            || matches(enWeekday, text)
    }

    /// 「周 / 星期 / 礼拜」后必须紧跟星期字;「周末」的「末」也在字表里。
    private static let weekdayCharPrefixed = #/(?:本|这|這|下下|下|上|来|來|先)?(?:周|週|星期|礼拜|禮拜)[一二三四五六日天末]/#
    /// 裸周前缀(下周/本周/…)。后接星期字/数字/后/内的形态被负向排除——那些要么已
    /// 被上一条命中,要么是「下周三以外」的偏移说法;「两」不在前缀表内,「两周后」
    /// 不会在这里误命中。
    private static let bareWeekPrefix = #/(?:本|这|這|下下|下|上|来|來)周(?![一二三四五六日天0-9后後内內])/#
    private static let jaWeekday = #/(?:今|来|再来|先)週|[月火水木金土日]曜/#
    private static let enWeekday = #/(?:next|last|this|coming)\s+(?:mon|tues?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri|sat|sun)(?:day)?\b|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|(?:next|this|last)\s+week\b|weekend/#

    // MARK: - 相对偏移(N 天/周/月/年后)

    private static func isRelativeOffset(_ text: String) -> Bool {
        matches(zhRelativeOffset, text)
            || matches(enRelativeOffsetIn, text)
            || matches(enRelativeOffsetLater, text)
            || matches(jaRelativeOffset, text)
    }

    /// 必须带 后/内 后缀——裸「三天」更可能是重复节奏(每三天),不算到期偏移。
    private static let zhRelativeOffset = #/[0-9０-９一二两兩三四五六七八九十百半数數]+\s*(?:个|個)?(?:天|日|周|週|星期|礼拜|禮拜|月|年|小时|小時|時間|时间)(?:之?后|後|以[后後]|[内內])/#
    private static let enRelativeOffsetIn = #/in\s+\d+\s+(?:day|week|month|year)s?\b/#
    private static let enRelativeOffsetLater = #/\d+\s+(?:days?|weeks?|months?|years?)\s+(?:later|from\s+(?:now|today))\b/#
    private static let jaRelativeOffset = #/[0-9０-９一二三四五六七八九十百半数數]+\s*(?:日|週間?|ヶ?月|か月|年)(?:後|あと)/#

    // MARK: - 具体日期

    private static func isAbsoluteDate(_ text: String) -> Bool {
        matches(zhAbsoluteDate, text)
            || matches(zhYearDate, text)
            || matches(enMonthDay, text)
            || matches(enDayMonthName, text)
            || matches(enSlashDate, text)
    }

    private static let zhAbsoluteDate = #/[0-9０-９一二三四五六七八九十]+\s*月\s*[0-9０-９一二三四五六七八九十]+\s*[日号號]/#
    private static let zhYearDate = #/\d{4}\s*年/#
    private static let enMonthDay = #/(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}\b/#
    private static let enDayMonthName = #/\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/#
    private static let enSlashDate = #/\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/#

    // MARK: - 钟点(时段词 + N点/N时 + am/pm + 英文整点 + 日文)

    private static func isTimeOnly(_ text: String) -> Bool {
        matches(zhDayPart, text)
            || matches(zhHourOclock, text)
            || matches(zhHourShi, text)
            || matches(enAmPm, text)
            || matches(enAtHour, text)
            || matches(jaDayPart, text)
    }

    private static let zhDayPart = #/上午|中午|下午|傍晚|晚上|夜里|夜裡|凌晨|早上|早晨|清晨|午夜|半夜|深夜/#
    private static let zhHourOclock = #/\d{1,2}\s*[点點](?:半)?/#
    private static let zhHourShi = #/\d{1,2}\s*[时時][半]?/#
    private static let enAmPm = #/\d{1,2}\s*(?:am|pm)\b/#
    private static let enAtHour = #/at\s+\d{1,2}\b|o'clock|noon|midnight/#
    private static let jaDayPart = #/午前|午後|正午|朝|夕方|\d{1,2}時/#

    // MARK: - 关键词表(包含式匹配)

    private static let relativeDayKeywords: Set<String> = [
        // 中文
        "今天", "今日", "今晚", "今夜", "明天", "明日", "明晚", "后天", "後天", "大后天", "大後天", "当天", "当日", "當日",
        // 英文
        "today", "tonight", "tomorrow", "day after tomorrow",
        // 日文
        "今日", "明日", "明後日", "一昨日", "今夜", "今晩",
    ]

    private static let monthPartKeywords: Set<String> = [
        // 中文
        "月初", "月中", "月底", "月末",
        // 英文
        "mid-month", "midmonth",
        // 日文
        "月初", "月中", "月末", "月半ば", "月初め",
    ]

    private static let holidayKeywords: Set<String> = [
        // 中文
        "春节", "春節", "除夕", "元旦", "元宵", "清明", "端午", "中秋", "重阳", "重陽",
        "国庆", "國慶", "五一", "六一", "劳动节", "勞動節", "情人节", "情人節", "圣诞", "聖誕",
        "万圣", "萬聖", "感恩节", "感恩節", "复活节", "復活節", "腊八", "臘八",
        // 英文
        "christmas", "xmas", "new year", "easter", "halloween", "thanksgiving",
        "valentine", "independence day",
        // 日文
        "正月", "お盆", "彼岸", "節分", "七夕", "大晦日", "クリスマス", "ハロウィン",
        "勤労感謝", "建国記念", "天皇誕生", "みどりの日", "こどもの日", "海の日", "山の日", "文化の日",
    ]

}
