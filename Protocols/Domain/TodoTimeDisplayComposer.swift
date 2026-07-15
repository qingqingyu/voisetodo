import Foundation

/// 把待办的"时间相关结构化字段"合成成一行用户可读的时间串。
///
/// 解决的问题：HomeView 与 ConfirmSheet 各自实现了一份 `composedTimeText`，
/// 因数据源不同（`ExtractedTodo.dueTime: String?` vs `TodoItemData.dueDate+hasDueTime`）
/// 而出现行为偏差。这里抽出"给定 recurrence + 相对日期 + 钟点/模糊时段 + 自由文本兜底，怎么拼"
/// 的纯展示逻辑，让两个调用方各自负责"怎么把模型字段转成钟点串 / 相对日期串"，
/// 拼装规则只此一处。
///
/// 规则：
/// 1. 优先用结构化字段（recurrence.displayTextWithEndDate + 相对日期 + 钟点/模糊时段）拼成
///    "每天 · 至 8月5日 · 15:00" 或 "明天 · 15:00"。
/// 2. 结构化字段全空时退回 `dueHint` 原文（AI 自由文本，例如"明天下午3点"）。
///    调用方可以把日期单独显示并传入 nil；当前 HomeView 就采用这种方式，
///    ConfirmSheet 则在缺少结构化时间字段时使用 dueHint 兜底。
/// 3. 再空则返回 nil（调用方不渲染）。
///
/// 冗余权衡：当结构化字段存在时丢弃 dueHint 原文，
/// 避免出现 "每天 · 至 8月5日 · 15:00 · 每天下午3点至8月5日" 这样的冗余串。
enum TodoTimeDisplayComposer {
    /// 把结构化时间字段拼成单行展示串。
    ///
    /// - Parameters:
    ///   - recurrenceRule: 重复规则；非 nil 时贡献 `displayTextWithEndDate`（已含结束日期）。
    ///   - relativeDateText: 从 dueDate 实时算出的相对日期串（"今天"/"明天"/"周三"/"7月15日"）。
    ///     仅在无 recurrenceRule 时使用（recurrenceRule 自带日期范围展示）。nil 表示无 dueDate。
    ///   - timeText: 已格式化好的钟点串（"HH:mm"），传 nil 表示无明确钟点。
    ///   - timeBucketText: 已本地化的模糊时段文本；只有没有明确钟点时传入。
    ///   - dueHint: AI 自由文本兜底；仅在前三者全空时使用。
    /// - Returns: 拼好的展示串；输入全空时返回 nil。
    static func compose(
        recurrenceRule: RecurrenceRule?,
        relativeDateText: String?,
        timeText: String?,
        dueHint: String?,
        timeBucketText: String? = nil
    ) -> String? {
        var parts: [String] = []
        if let rule = recurrenceRule {
            parts.append(rule.displayTextWithEndDate)
        }
        // recurrenceRule 自带日期范围展示，不重复加 relativeDateText
        if recurrenceRule == nil, let date = relativeDateText?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty {
            parts.append(date)
        }
        if let time = timeText?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty {
            parts.append(time)
        } else if let bucket = timeBucketText?.trimmingCharacters(in: .whitespacesAndNewlines), !bucket.isEmpty {
            parts.append(bucket)
        }
        if parts.isEmpty {
            if let hint = dueHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                return hint
            }
            return nil
        }
        return parts.joined(separator: " · ")
    }
}

/// 从 Date 实时算出相对日期文案（"今天"/"明天"/"周三"/"7月15日"）。
///
/// 解决的问题：AI 提取的 dueHint（如 "next Wednesday"）是静态文本，
/// 存进 TodoItemData 后不会随时间变化——下周再看 "next Wednesday" 含义已变，
/// 但任务日期没变，显示和数据互相矛盾。
///
/// 此 formatter 从 TodoItemData.dueDate（绝对日期）实时算展示文案，
/// 保证显示永远新鲜、格式永远统一。
///
/// 规则：
/// - 0 天 → "今天" / "Today"
/// - +1 天 → "明天" / "Tomorrow"
/// - -1 天 → "昨天" / "Yesterday"
/// - 2~6 天 → 星期几（locale 感知的 shortWeekdaySymbols）
/// - 超过一周 → "M月d日" / "MMM d"（locale 感知的 date template）
enum TodoRelativeDateFormatter {
    static func format(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startOfNow = cal.startOfDay(for: now)
        let startOfDate = cal.startOfDay(for: date)
        let dayDiff = cal.dateComponents([.day], from: startOfNow, to: startOfDate).day ?? 0

        switch dayDiff {
        case 0:
            return String(localized: "date.relative.today")
        case 1:
            return String(localized: "date.relative.tomorrow")
        case -1:
            return String(localized: "date.relative.yesterday")
        case 2...6:
            let weekdayIndex = cal.component(.weekday, from: date) - 1
            let symbols = cal.shortWeekdaySymbols
            guard symbols.indices.contains(weekdayIndex) else {
                return absoluteFormat(date)
            }
            return symbols[weekdayIndex]
        default:
            return absoluteFormat(date)
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static func absoluteFormat(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }
}
