import Foundation

/// 适合语音待办的模糊时段。
///
/// `.anytime` 仅用于展示和选择；持久化的显式时段使用 optional，避免遮住已有精确钟点。
enum TimeBucket: String, CaseIterable, Codable, Hashable, Sendable {
    case anytime
    case morning
    case afternoon
    case evening

    static let chronologicalOrder: [TimeBucket] = [.anytime, .morning, .afternoon, .evening]

    static func explicit(from rawValue: String?) -> TimeBucket? {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let bucket = TimeBucket(rawValue: normalized),
              bucket != .anytime else {
            return nil
        }
        return bucket
    }
}

/// 统一解析任务在首页展示时应归属的时段。
enum TimeBucketResolver {
    /// 明确钟点优先；否则使用显式模糊时段；最后回退为随时。
    ///
    /// 钟点→时段的边界是全 app 的**唯一定义处**（prompt 只做"上午/下午/晚上"这类
    /// 模糊词的语义分类、不定义小时，因此不存在 LLM 与客户端的边界冲突）：
    /// 5:00–11:59 morning / 12:00–17:59 afternoon / 其余 evening。
    /// noon（12:00）归 afternoon 是既定选择——改边界务必同步 DomainModuleTests 的边界单测。
    static func effective(
        explicitBucket: TimeBucket?,
        dueDate: Date?,
        hasDueTime: Bool,
        calendar: Calendar = .current
    ) -> TimeBucket {
        if hasDueTime, let dueDate {
            switch calendar.component(.hour, from: dueDate) {
            case 5..<12:
                return .morning
            case 12..<18:
                return .afternoon
            default:
                return .evening
            }
        }

        if let explicitBucket, explicitBucket != .anytime {
            return explicitBucket
        }

        return .anytime
    }
}

/// 任务入库时的日程默认规则（确定性、客户端算，不依赖大模型）。
enum TodoScheduleDefaults {
    /// 时段⇒今天：AI 只解析出模糊时段（time_bucket）但没有日期时，把 dueDate 补成今天。
    ///
    /// 背景："早上做作业"这类只有时段、没有日期的语音，prompt 会返回 `time_bucket=morning`、
    /// `due_date=null`。若不补日期，任务会落进 Unscheduled，卡片却仍显示"Morning" → 自相矛盾。
    /// 补成今天后，任务归入「今日/早上」分区，时段有了意义，矛盾消失。
    ///
    /// 仅在"有模糊时段且无任何日期/钟点"时生效；已有具体日期或钟点的任务原样返回。
    static func effectiveDueDate(
        resolvedDate: Date?,
        hasDueTime: Bool,
        timeBucket: TimeBucket?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard resolvedDate == nil, !hasDueTime,
              let bucket = timeBucket, bucket != .anytime else {
            return resolvedDate
        }
        return calendar.startOfDay(for: now)
    }
}
