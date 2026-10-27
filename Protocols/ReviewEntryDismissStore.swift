import Foundation

/// 复盘入口卡「手动关闭时刻」存储(2026-10-27 拍板:× 主动收卡,复用 7 天冷却)。
///
/// 设计约束:
/// - **不写 `lastReviewDate`**——那是「上次复盘完成」口径(入口卡范围标 + 流程
///   第 1 步注入数据),把关闭时刻混进去会污染口径:没复盘过的用户会错误显示
///   「自上次复盘以来」。关闭时刻单独存本 store。
/// - 量小(一个 Date),不值得进 SwiftData 动 schema;只有主 App 读它
///   (Widget/Intent 不渲染入口卡),走 UserDefaults.standard(与
///   `ReviewPinningStore` 的 App Group 不同范式,按消费者范围选容器)。
/// - 注入 defaults 便于单测(同 `ReviewPinningStore` 范式)。
final class ReviewEntryDismissStore {
    static let shared = ReviewEntryDismissStore()
    static let dismissedAtKey = "VoiceTodoReviewEntryDismissedAt"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    // MARK: - 读写

    /// 最近一次手动关闭入口卡的时刻;从未关闭过返回 nil。defaults 不可用时
    /// 返回 nil(只读路径降级:卡常驻,展示偏好不阻塞渲染)。
    func dismissedAt() -> Date? {
        guard let defaults else { return nil }
        guard let raw = defaults.object(forKey: Self.dismissedAtKey) else { return nil }
        // 脏数据(该 key 被非 Date 类型占据):显式记日志后按未关闭降级——
        // 方向保守(卡常驻,顶多多显示一次),但留痕可查,不静默吞。
        guard let date = raw as? Date else {
            VoiceTodoLog.app.warning("review_entry_dismiss.load.failed reason=type_mismatch")
            return nil
        }
        return date
    }

    /// 写入手动关闭时刻(覆盖旧值,冷却窗口自此刻重起算)。defaults 不可用时
    /// 打 warning 日志显式记录,不静默假装成功。
    func markDismissed(_ date: Date = Date()) {
        guard let defaults else {
            VoiceTodoLog.app.warning("review_entry_dismiss.set.failed reason=defaults_unavailable")
            return
        }
        defaults.set(date, forKey: Self.dismissedAtKey)
        VoiceTodoLog.app.info("review_entry_dismiss.set.success")
    }
}

// MARK: - 冷却判定(纯函数,单测友好)

/// 入口卡冷却窗口判定。「距上次复盘完成」与「距手动关闭」两个锚点取较近者,
/// 任一仍在窗口内即冷却——手动关闭复用同一 7 天窗口(2026-10-27 拍板,不引入
/// 第二档时长);冷却期内又完成一次复盘,则复盘时刻更新,自复盘时刻重起算。
enum ReviewEntryCooldown {
    static func isCoolingDown(
        lastReviewCompletedAt: Date?,
        manuallyDismissedAt: Date?,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        let anchors = [lastReviewCompletedAt, manuallyDismissedAt].compactMap { $0 }
        // 较近者 = max(距今最短);它仍在窗口内时,更远者必然也超窗,单点判定即全覆盖。
        guard let nearest = anchors.max() else { return false }
        return now.timeIntervalSince(nearest) < window
    }
}
