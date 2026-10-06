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

    /// 从 `due_hint` 自由文本推断时段（模型漏给 `time_bucket` 时的客户端兜底）。
    ///
    /// 背景：模型（尤其轻量档）对"明天下午去公园"这类输入偶尔只返回
    /// `due_hint="明天下午"`、漏掉结构化 `time_bucket`。确认页时间 chip 走 dueHint
    /// 原文兜底显示，"看着是对的"；但落库的 time_bucket 是 null → 首页 tier /
    /// Calendar 的时段分块全部收不到，"下午"语义在入库瞬间丢失。
    /// `ExtractedTodo` 构造时调本方法反哺，保证"原文里说了时段"与
    /// "结构化字段里有时段"不再两脱节。
    ///
    /// - 词典覆盖 MVP 三语（zh / en / ja），时段口径与 `TimeBucketResolver`
    ///   的钟点边界一致：中午 / noon（12:00）归 afternoon，深夜 / 夜类归 evening。
    /// - 多个时段词命中时取文本中**最先出现**者（区间表达"上午10点到下午2点"取起点）。
    /// - 不收歧义单字（中文"早"——"早点睡"是晚上；日文"朝"会误匹配中文"朝向"）。
    ///   已知取舍：日文单字"夜"保留（"明日の夜"依赖它），极罕见的"夜明け"（=清晨）
    ///   会被误归 evening——due_hint 里几乎不出现，接受该误差。
    static func inferred(fromHint hint: String?) -> TimeBucket? {
        guard let normalized = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        var bestOffset = Int.max
        var bestBucket: TimeBucket?
        for (bucket, keywords) in Self.timeOfDayKeywords {
            for keyword in keywords {
                guard let range = normalized.range(of: keyword) else { continue }
                let offset = range.lowerBound.utf16Offset(in: normalized)
                if offset < bestOffset {
                    bestOffset = offset
                    bestBucket = bucket
                }
            }
        }
        return bestBucket
    }

    /// 出生点时段归一化（memberwise init 与 `init(from:)` 共用的唯一口径，防两处漂移）：
    /// 1. 有明确钟点 → 恒 nil（钟点优先，时段由 `TimeBucketResolver` 按钟点推导）；
    /// 2. 显式 bucket 优先（`.anytime` 视为未指定）；
    /// 3. 模型漏给时从 `due_hint` 原文反哺（"明天下午"→afternoon）。
    static func resolved(explicit: TimeBucket?, hint: String?, hasDueTime: Bool) -> TimeBucket? {
        guard !hasDueTime else { return nil }
        if let explicit, explicit != .anytime {
            return explicit
        }
        return inferred(fromHint: hint)
    }

    /// 时段词词典（MVP 三语）。英文在 `inferred(fromHint:)` 里已 lowercased。
    private static let timeOfDayKeywords: [TimeBucket: [String]] = [
        .morning: ["上午", "早上", "早晨", "清晨", "morning", "午前", "今朝"],
        .afternoon: ["下午", "午后", "中午", "正午", "afternoon", "noon", "午後", "昼"],
        .evening: ["晚上", "今晚", "傍晚", "夜里", "夜晚", "深夜", "tonight", "evening", "night", "今夜", "今晩", "今夕", "夕方", "夜"]
    ]
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
