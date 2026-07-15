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
