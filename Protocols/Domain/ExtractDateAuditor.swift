import Foundation

// MARK: - 配置

/// 解析日期审计(纠错器 Phase 2)的配置。
///
/// 2026-11-04 拍板保守起步:默认纯观察——审计器只比对、只记遥测,不改任何结果。
/// 零歧义闭集的覆盖逻辑已实现并有测试钉住,开关拨 true 即在下一版生效
/// (App 无远程配置基建,翻开关 = 改这里 + 发版)。
enum ExtractDateAuditorConfig {
    /// false(默认):所有分歧只记 `parse_date_audit`,结果原样。
    /// true:零歧义闭集内的分歧以复算值覆盖 `dueDate`(`dueHint` 保留供用户参考)。
    static let overrideEnabled = false
}

// MARK: - 审计结论

/// 一条待办的日期审计结论(rawValue 直接进遥测 params,命名稳定勿改)。
enum ExtractDateAuditOutcome: String, CaseIterable, Sendable {
    /// 闭集内,复算与模型一致。
    case agree = "agree"
    /// 闭集内,复算与模型不一致(开关开启时本条会被覆盖)。
    case mismatch = "mismatch"
    /// 有日期表达但只观察:不在零歧义闭集(裸周X/月底/N天后…),
    /// 或 hint 表达在转写原文中找不到(模型改写过 hint,不可信)。
    case observed = "observed"
    /// hint 属闭集但模型 dueDate 为空(日期被丢的信号)——只观察,v1 不补造日期。
    case missing = "missing"
    /// hint 无日期表达(或 hint 为空),无从比对。
    case noDateExpression = "none"
}

/// 审计判定(纯数据;`dayDelta` 截断 ±60,口径同 `FieldCorrection.dayDelta`)。
struct ExtractDateAuditVerdict: Equatable, Sendable {
    let outcome: ExtractDateAuditOutcome
    /// 复算值 − 模型值的用户日差(仅 mismatch 携带)。
    let dayDelta: Int?
    /// 开关开启时本条会被覆盖。
    let wouldOverride: Bool
    /// 复算出的绝对日期(仅 mismatch 携带)。
    let correctedDate: Date?

    static let noOp = ExtractDateAuditVerdict(outcome: .noDateExpression, dayDelta: nil, wouldOverride: false, correctedDate: nil)
}

// MARK: - 审计器

/// AI 返回的 `due_hint`(用户原话的日期表述)vs `due_date`(模型换算的绝对日期)的
/// 客户端复算审计器。纯函数,单测友好。
///
/// 产品口径(与 prompt 规则 4 / PR#6 机械算法同源):
/// - 周日起始;"下周X" = **严格晚于今天的下一个周日** + 偏移(周日=0、周一=1、…、周六=6)。
///   ⚠️ `TodoDueDateResolver.dateInWeek` 是 ISO 周一起始口径,与产品口径不一致
///   (今天处于周首/周日目标时差 7 天),本审计器不复用它,口径在此独立实现。
///
/// 零歧义闭集(v1):今天/明天/后天/大后天、下周X、X月X日/11月5号、英文月份名+日。
/// 观察类(只记录不纠):裸周X(本周还是下周是语义歧义)、月初/月底、N天后、带
/// "之后/以后"后缀、来周无星期、"next week"无星期。
///
/// 隐私红线(同 `ParseCorrectionTelemetry`):`dueHint` 原文只在本模块消费,
/// 绝不进遥测参数、绝不进日志。
enum ExtractDateAuditor {

    // MARK: 入口

    /// 对一次解析的最终结果逐条审计:记 `parse_date_audit` 遥测,返回
    /// (覆盖开关开启时)零歧义闭集分歧已被修正的待办数组。纯函数。
    /// - Parameters:
    ///   - todos: 最终解析出的待办。
    ///   - transcript: 本次口述原文(hint 表达的可信度校验:闭集 token 在原文中
    ///     找得到才允许 mismatch 判定,防模型改写 hint 导致改错)。
    ///   - locale: 内容语言(遥测 locale 参数与说法分类用)。
    ///   - anchor: 锚点时刻——**取请求发出时的本地时间**,与发给代理的
    ///     `X-Local-Date`(prompt 参考日期)同源,避免午夜穿越导致模型/代码不同锚。
    ///   - calendar / overrideEnabled / sink: 日历、开关(默认读 Config)、遥测出口(测试注入)。
    /// - Returns: 观察模式原样返回;覆盖模式返回修正后的新数组(`ExtractionResult.todos`
    ///   是 let,调用方用返回值重建 result)。
    static func audited(
        _ todos: [ExtractedTodo],
        transcript: String?,
        locale: Locale,
        anchor: Date,
        calendar: Calendar = .current,
        overrideEnabled: Bool = ExtractDateAuditorConfig.overrideEnabled,
        sink: (TelemetryEvent) -> Void = { Telemetry.record($0) }
    ) -> [ExtractedTodo] {
        guard !todos.isEmpty else { return todos }
        let localeCode = ParseCorrectionTelemetry.localeCode(from: locale.identifier)

        var result = todos
        var counts: [ExtractDateAuditOutcome: Int] = [:]
        for index in result.indices {
            let verdict = audit(
                hint: result[index].dueHint,
                modelDate: result[index].dueDate,
                transcript: transcript,
                anchor: anchor,
                calendar: calendar
            )
            counts[verdict.outcome, default: 0] += 1

            if overrideEnabled, verdict.outcome == .mismatch, let corrected = verdict.correctedDate {
                result[index].dueDate = corrected
            }

            let kind = ParseExpressionClassifier.classify(
                dueHint: result[index].dueHint,
                hasDate: result[index].dueDate != nil,
                hasTime: result[index].dueTime != nil,
                locale: locale
            )
            sink(.parseDateAudit(
                locale: localeCode,
                outcome: verdict.outcome.rawValue,
                kind: kind.rawValue,
                basis: result[index].dueDateBasis,
                dayDelta: verdict.dayDelta,
                overrideApplied: overrideEnabled && verdict.outcome == .mismatch
            ))
        }

        // 汇总一行(纯计数,无 PII):agree=1 mismatch=0 observed=2 missing=0 none=0 override=false
        let summary = ExtractDateAuditOutcome.allCases
            .compactMap { outcome -> String? in
                guard let count = counts[outcome], count > 0 else { return nil }
                return "\(outcome.rawValue)=\(count)"
            }
            .joined(separator: " ")
        VoiceTodoLog.extractor.debug("extract.date_audit \(summary, privacy: .public) override=\(overrideEnabled, privacy: .public)")
        return result
    }

    /// 单条审计(纯函数)。
    static func audit(
        hint: String?,
        modelDate: Date?,
        transcript: String?,
        anchor: Date,
        calendar: Calendar = .current
    ) -> ExtractDateAuditVerdict {
        guard let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedHint.isEmpty else {
            return .noOp
        }
        guard let match = parse(trimmedHint) else {
            // hint 有内容但没有任何日期性表达(如纯钟点"下午三点")——日期轴无可比对。
            return .noOp
        }
        let observed = ExtractDateAuditVerdict(outcome: .observed, dayDelta: nil, wouldOverride: false, correctedDate: nil)

        switch match.semantics {
        case .ambiguous:
            return observed
        case .dayOffset, .nextWeekWeekday, .explicitDate:
            // 可信度闸门:闭集表达必须在转写原文中找得到(任一同义 token 命中即可,
            // 兼容 hint 写"下周三"而原文说"下礼拜三")。transcript 为 nil 时同样不放行。
            guard let transcript, containsAnyAlias(of: match, in: transcript) else {
                return observed
            }
            guard let modelDate else {
                return ExtractDateAuditVerdict(outcome: .missing, dayDelta: nil, wouldOverride: false, correctedDate: nil)
            }
            let anchorDay = DayClock.startOfUserDay(for: anchor, calendar: calendar)
            guard let codeDate = resolve(match.semantics, anchorDay: anchorDay, calendar: calendar),
                  let delta = userDayDelta(from: modelDate, to: codeDate, calendar: calendar) else {
                // 复算失败仅显式日期非法一种可能,解析层已挡——防御性回落。
                return observed
            }
            guard delta != 0 else {
                return ExtractDateAuditVerdict(outcome: .agree, dayDelta: nil, wouldOverride: false, correctedDate: nil)
            }
            return ExtractDateAuditVerdict(
                outcome: .mismatch,
                dayDelta: min(60, max(-60, delta)),
                wouldOverride: true,
                correctedDate: codeDate
            )
        }
    }

    // MARK: - 闭集解析

    /// 闭集语义(零歧义的才进 .dayOffset/.nextWeekWeekday/.explicitDate,其余一律 .ambiguous)。
    private enum Semantics {
        /// 今天=0、明天=1、后天=2、大后天=3。
        case dayOffset(Int)
        /// 下周X(周日起始),weekday 取 Apple 约定 1(周日)…7(周六)。
        case nextWeekWeekday(Int)
        /// 具体日期(年按"已过则顺延到明年"推导)。
        case explicitDate(month: Int, day: Int)
        /// 有日期性表达但闭集外。
        case ambiguous
    }

    private struct Match {
        let semantics: Semantics
        /// 命中 token 的同义别名集(可信度校验用:原文含任一别名即通过)。
        let aliases: [String]
    }

    /// zh 星期 token → Apple weekday(1=周日…7=周六)。声明顺序即优先级,
    /// 多字 token 在前防单字误吞。
    private static let zhWeekdayTokens: [(tokens: [String], weekday: Int)] = [
        (["周日", "星期日", "礼拜日", "周天", "星期天", "礼拜天"], 1),
        (["周一", "星期一", "礼拜一"], 2),
        (["周二", "星期二", "礼拜二"], 3),
        (["周三", "星期三", "礼拜三"], 4),
        (["周四", "星期四", "礼拜四"], 5),
        (["周五", "星期五", "礼拜五"], 6),
        (["周六", "星期六", "礼拜六"], 7)
    ]

    /// ja 曜日 token → Apple weekday。
    private static let jaWeekdayTokens: [(tokens: [String], weekday: Int)] = [
        (["日曜"], 1), (["月曜"], 2), (["火曜"], 3), (["水曜"], 4),
        (["木曜"], 5), (["金曜"], 6), (["土曜"], 7)
    ]

    /// en 星期 token(小写,词边界匹配)→ Apple weekday。
    private static let enWeekdayTokens: [(tokens: [String], weekday: Int)] = [
        (["sunday", "sun"], 1), (["monday", "mon"], 2), (["tuesday", "tues", "tue"], 3),
        (["wednesday", "wed"], 4), (["thursday", "thurs", "thur", "thu"], 5),
        (["friday", "fri"], 6), (["saturday", "sat"], 7)
    ]

    /// en 月份名(小写)→ 月号。
    private static let enMonthTokens: [(tokens: [String], month: Int)] = [
        (["january", "jan"], 1), (["february", "feb"], 2), (["march", "mar"], 3),
        (["april", "apr"], 4), (["may"], 5), (["june", "jun"], 6),
        (["july", "jul"], 7), (["august", "aug"], 8), (["september", "sep", "sept"], 9),
        (["october", "oct"], 10), (["november", "nov"], 11), (["december", "dec"], 12)
    ]

    /// 解析 hint 的日期语义。返回 nil = 无任何日期性表达。
    /// 顺序敏感:最长 token 先查(大后天→后天、day after tomorrow→tomorrow、明後日→明日)。
    private static func parse(_ hint: String) -> Match? {
        let lowercased = hint.lowercased()

        // 1) 相对日(零歧义)
        if hint.contains("大后天") { return .init(semantics: .dayOffset(3), aliases: ["大后天"]) }
        if lowercased.containsEnglishPhrase("day after tomorrow") {
            return .init(semantics: .dayOffset(2), aliases: ["day after tomorrow"])
        }
        if hint.contains("明後日") || hint.contains("あさって") {
            return .init(semantics: .dayOffset(2), aliases: ["明後日", "明后日", "あさって"])
        }
        if hint.contains("后天") { return .init(semantics: .dayOffset(2), aliases: ["后天", "後天"]) }
        if hint.contains("明天") || hint.contains("明晚") || hint.contains("明日") {
            return .init(semantics: .dayOffset(1), aliases: ["明天", "明晚", "明日", "tomorrow"])
        }
        if lowercased.containsEnglishPhrase("tomorrow") || lowercased.containsEnglishPhrase("tmr") {
            return .init(semantics: .dayOffset(1), aliases: ["tomorrow", "tmr", "明天"])
        }
        if hint.contains("今天") || hint.contains("今晚") || hint.contains("今日") {
            return .init(semantics: .dayOffset(0), aliases: ["今天", "今晚", "今日"])
        }
        if lowercased.containsEnglishPhrase("today") || lowercased.containsEnglishPhrase("tonight") {
            return .init(semantics: .dayOffset(0), aliases: ["today", "tonight", "今天"])
        }

        // 2) "之后/以后"后缀:目标日本身歧义(当天?次日起?),只观察
        if hint.contains("之后") || hint.contains("以后") || hint.contains("以後")
            || hint.contains("过后") || hint.contains("過後") || lowercased.contains(" after ") {
            return .init(semantics: .ambiguous, aliases: [])
        }

        // 3) 下周X(周日起始,产品口径)
        if hint.contains("下周") || hint.contains("下星期") || hint.contains("下礼拜") {
            if let entry = zhWeekdayTokens.first(where: { entry in entry.tokens.contains { hint.contains($0) } }) {
                return .init(semantics: .nextWeekWeekday(entry.weekday), aliases: entry.tokens)
            }
            return .init(semantics: .ambiguous, aliases: []) // "下周"无星期
        }
        if hint.contains("来週") || hint.contains("来周") {
            if let entry = jaWeekdayTokens.first(where: { entry in entry.tokens.contains { hint.contains($0) } }) {
                return .init(semantics: .nextWeekWeekday(entry.weekday), aliases: entry.tokens)
            }
            return .init(semantics: .ambiguous, aliases: [])
        }
        for entry in enWeekdayTokens {
            if entry.tokens.contains(where: { lowercased.containsEnglishPhrase("next \($0)") }) {
                return .init(semantics: .nextWeekWeekday(entry.weekday), aliases: entry.tokens)
            }
        }

        // 4) 具体日期
        if let match = cjkExplicitDate(hint) { return match }
        if let match = enExplicitDate(lowercased) { return match }

        // 5) 其余日期性表达(裸周X/月底/月初/N天后/X号/周末/节日…)→ 只观察
        if hasDateMarker(hint, lowercased: lowercased) {
            return .init(semantics: .ambiguous, aliases: [])
        }
        return nil
    }

    /// X月X日 / X月X号(阿拉伯数字)。年份取锚点年,已过则顺延明年;
    /// 日期非法(2月30日)按 ambiguous 处理。
    private static func cjkExplicitDate(_ hint: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})[日号]"#),
              let match = regex.firstMatch(in: hint, range: NSRange(location: 0, length: hint.utf16.count)),
              let whole = Range(match.range, in: hint),
              let monthRange = Range(match.range(at: 1), in: hint),
              let dayRange = Range(match.range(at: 2), in: hint),
              let month = Int(hint[monthRange]),
              let day = Int(hint[dayRange]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        return .init(semantics: .explicitDate(month: month, day: day), aliases: [String(hint[whole])])
    }

    /// 英文 "July 5" / "Jul 5th"(月份名在前)。
    private static func enExplicitDate(_ lowercased: String) -> Match? {
        for entry in enMonthTokens {
            for token in entry.tokens {
                guard let regex = try? NSRegularExpression(
                    pattern: #"\b\#(NSRegularExpression.escapedPattern(for: token))\s+(\d{1,2})(st|nd|rd|th)?\b"#
                ) else { continue }
                if let match = regex.firstMatch(in: lowercased, range: NSRange(location: 0, length: lowercased.utf16.count)),
                   let dayRange = Range(match.range(at: 1), in: lowercased),
                   let day = Int(lowercased[dayRange]), (1...31).contains(day) {
                    return .init(semantics: .explicitDate(month: entry.month, day: day), aliases: entry.tokens)
                }
            }
        }
        return nil
    }

    /// 宽松的"有日期性表达"标记(仅用于 ambiguous vs none 的分类,不影响行为)。
    /// zh/ja 的星期词已被"周/星期/礼拜/曜"单字覆盖,英文裸星期单独查。
    private static func hasDateMarker(_ hint: String, lowercased: String) -> Bool {
        let markers = ["周", "星期", "礼拜", "曜", "月底", "月初", "月中", "月末", "周末",
                       "天后", "天後", "号", "节日", "下周", "本周"]
        if markers.contains(where: { hint.contains($0) }) { return true }
        let enMarkers = ["week", "weekend", "month", "days from now", "days later", "in a few days"]
        return enMarkers.contains { lowercased.containsEnglishPhrase($0) }
            || enWeekdayTokens.contains { entry in entry.tokens.contains { lowercased.containsEnglishPhrase($0) } }
    }

    // MARK: - 语义 → 日期(产品口径)

    private static func resolve(_ semantics: Semantics, anchorDay: Date, calendar: Calendar) -> Date? {
        switch semantics {
        case .ambiguous:
            // 调用方(audit)已在闭集分支前拦截 ambiguous,此处不可达——显式返回
            // 而非 default,保证 Semantics 新增 case 时编译器强制覆盖。
            return nil
        case let .dayOffset(offset):
            return calendar.date(byAdding: .day, value: offset, to: anchorDay)
        case let .nextWeekWeekday(weekday):
            // 产品口径(prompt 规则 4 / PR#6):下周X = 严格晚于今天的下一个周日 + 偏移,
            // 周日=0。今天周日 → 下周第一天的那个周日是 +7(绝不"再跳一周"也不落在本周)。
            let anchorWeekday = calendar.component(.weekday, from: anchorDay) // 1(周日)…7(周六)
            let daysToNextSunday = 8 - anchorWeekday
            guard let nextSunday = calendar.date(byAdding: .day, value: daysToNextSunday, to: anchorDay) else {
                return nil
            }
            return calendar.date(byAdding: .day, value: weekday - 1, to: nextSunday)
        case let .explicitDate(month, day):
            let anchorYear = calendar.component(.year, from: anchorDay)
            for year in [anchorYear, anchorYear + 1] {
                var comps = DateComponents(year: year, month: month, day: day)
                comps.hour = 12
                guard let candidate = calendar.date(from: comps) else { continue }
                // 回读校验:2月30日 会被 Calendar 归一化成 3月2日,视为非法。
                let roundtrip = calendar.dateComponents([.year, .month, .day], from: candidate)
                guard roundtrip.month == month, roundtrip.day == day else { continue }
                if candidate >= anchorDay { return candidate }
            }
            return nil
        }
    }

    // MARK: - 私有工具

    /// hint 命中 token 的可信度校验:转写原文含任一同义别名(不区分大小写)即通过。
    private static func containsAnyAlias(of match: Match, in transcript: String) -> Bool {
        let lowercasedTranscript = transcript.lowercased()
        return match.aliases.contains { alias in
            lowercasedTranscript.contains(alias.lowercased())
        }
    }

    /// 用户日差(复算值 − 模型值),按 `DayClock.startOfUserDay` 取两端日界,
    /// DST 安全(与 `ParseCorrectionDiff.userDayDelta` 同法)。
    private static func userDayDelta(from old: Date, to new: Date, calendar: Calendar) -> Int? {
        calendar.dateComponents(
            [.day],
            from: DayClock.startOfUserDay(for: old, calendar: calendar),
            to: DayClock.startOfUserDay(for: new, calendar: calendar)
        ).day
    }
}
