import Foundation

/// 把 AI 结构化返回的钟点（"HH:mm"，24 小时制）合成到已解析出的日期上。
/// 与 `TodoDueDateResolver`（只解析到"天"）配套：日期定"哪天"，本解析器定"几点"。
///
/// - 有日期 + 合法时间 → 返回带时分的 `Date`，`hasTime = true`
/// - 无日期 + 合法时间 → 默认落到"今天"该时刻（口语"8点"多指当天），`hasTime = true`
/// - 时间缺失 / 非法 / 越界 → 原样返回日期，`hasTime = false`
enum TodoDueTimeResolver {
    static func combine(
        date: Date?,
        dueTime: String?,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> (date: Date?, hasTime: Bool) {
        guard let time = parse(dueTime) else {
            return (date, false)
        }
        let baseDay = date ?? calendar.startOfDay(for: referenceDate)
        guard let combined = calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: baseDay
        ) else {
            return (date, false)
        }
        return (combined, true)
    }

    /// 解析 "HH:mm"（24 小时制）。格式非法或时/分越界返回 nil。
    static func parse(_ dueTime: String?) -> (hour: Int, minute: Int)? {
        guard let raw = dueTime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }
}
