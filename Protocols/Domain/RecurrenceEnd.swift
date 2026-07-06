import Foundation

/// AI 归一化后的"重复截止边界"结构（模型只分类、不算日期；具体日期由客户端 `RecurrenceEndResolver` 确定性算出）。
/// 仅解码用途，不持久化——解析后写入 `RecurrenceRule.endDate` 这一单一真相。
enum RecurrenceEnd: Equatable, Sendable {
    /// 从起始日起 count×(day|week|month)（未来7天 / 未来一周 / 接下来两周 / 未来一个月）。
    case afterCount(count: Int, unit: Unit)
    /// 本/下周的某个 weekday（Calendar 语义 1=周日…7=周六）。到本周五 / 下周三。
    case weekday(weekday: Int, scope: Scope)
    /// 本/下月最后一天。月底前 / 下月底。
    case monthEnd(scope: Scope)
    /// 本/下月的第 day 天（按当月天数 clamp）。这个月15号 / 下个月10号截止。
    case dayOfMonth(day: Int, scope: Scope)
    /// 用户明确给出的绝对日期 "YYYY-MM-DD"（模型照抄，不做运算）。
    case date(String)

    enum Unit: String, Sendable { case day, week, month }
    enum Scope: String, Sendable { case this, next }
}

extension RecurrenceEnd: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, count, unit, weekday, scope, day, value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch kind {
        case "after_count":
            let count = try c.decode(Int.self, forKey: .count)
            guard count > 0 else { throw Self.corrupted("after_count.count must be > 0") }
            let unitRaw = (try c.decodeIfPresent(String.self, forKey: .unit))?.lowercased() ?? "day"
            self = .afterCount(count: count, unit: Unit(rawValue: unitRaw) ?? .day)

        case "weekday":
            let name = try c.decode(String.self, forKey: .weekday).lowercased()
            guard let wd = Self.weekdayNumber(from: name) else {
                throw Self.corrupted("weekday.weekday unrecognized: \(name)")
            }
            self = .weekday(weekday: wd, scope: Self.decodeScope(c))

        case "month_end":
            self = .monthEnd(scope: Self.decodeScope(c))

        case "day_of_month":
            let day = try c.decode(Int.self, forKey: .day)
            guard (1...31).contains(day) else { throw Self.corrupted("day_of_month.day out of range") }
            self = .dayOfMonth(day: day, scope: Self.decodeScope(c))

        case "date":
            let value = try c.decode(String.self, forKey: .value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw Self.corrupted("date.value empty") }
            self = .date(value)

        default:
            throw Self.corrupted("unknown kind: \(kind)")
        }
    }

    private static func decodeScope(_ c: KeyedDecodingContainer<CodingKeys>) -> Scope {
        let raw = ((try? c.decodeIfPresent(String.self, forKey: .scope)) ?? nil)?.lowercased()
        return Scope(rawValue: raw ?? "this") ?? .this
    }

    /// weekday 名（含缩写）→ Calendar weekday（1=周日…7=周六）。复用 TodoDueDateResolver 的映射。
    static func weekdayNumber(from name: String) -> Int? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TodoDueDateResolver.englishWeekdays.first { $0.tokens.contains(n) }?.value
    }

    private static func corrupted(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}
