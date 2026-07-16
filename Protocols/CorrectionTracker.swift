import Foundation

/// 标题修正频次记录——追踪"用户反复把同一说法改成同一结果"。
/// 用词级 diff 提取变化部分(如"老地方"→"星光健身房"),而非整条 title。
/// 达到阈值后触发建议("记住吗?"),用户确认才写入 PersonalGlossary。
struct TitleCorrection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var originalTitle: String
    var confirmedTitle: String
    var localeIdentifier: String
    var count: Int

    /// 从两个 title 提取词级 diff:找公共前后缀,中间变化部分即为 phrase→expansion。
    /// 例:"去老地方" vs "去星光健身房" → ("老地方", "星光健身房")
    /// 返回 nil 如果变化太小(单字)或不是替换(纯添加/纯删除)。
    static func extractPhraseDiff(original: String, confirmed: String) -> (phrase: String, expansion: String)? {
        let orig = Array(original)
        let conf = Array(confirmed)

        // 公共前缀
        var prefixLen = 0
        while prefixLen < orig.count && prefixLen < conf.count && orig[prefixLen] == conf[prefixLen] {
            prefixLen += 1
        }
        // 公共后缀(不与前缀重叠)
        var suffixLen = 0
        while suffixLen < orig.count - prefixLen && suffixLen < conf.count - prefixLen
              && orig[orig.count - 1 - suffixLen] == conf[conf.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let phrase = String(orig[prefixLen..<(orig.count - suffixLen)])
        let expansion = String(conf[prefixLen..<(conf.count - suffixLen)])

        // 两端都非空才是替换(纯添加 expansion 非空但 phrase 空;纯删除反之)
        guard !phrase.isEmpty, !expansion.isEmpty else { return nil }
        // 跳过单字变化(太短,可能是打字错误而非语义修正)
        guard phrase.count >= 2 || expansion.count >= 2 else { return nil }

        return (phrase, expansion)
    }
}

/// 修正追踪器(App Group UserDefaults),线程安全。
/// A2 自动学习的数据层:record() 积累频次,suggestions() 返回达阈值的候选。
final class CorrectionTracker {
    static let shared = CorrectionTracker()
    static let correctionsKey = "VoiceTodoTitleCorrections"
    static let threshold = 3

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)) {
        self.defaults = defaults
    }

    /// 记录一次标题修正。同一(original→confirmed+locale)累计 count。
    func record(original: String, confirmed: String, localeIdentifier: String) {
        guard original != confirmed,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !confirmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let defaults else { return }
        lock.withLock {
            var corrections = loadCorrections(from: defaults)
            if let idx = corrections.firstIndex(where: {
                $0.originalTitle == original && $0.confirmedTitle == confirmed && $0.localeIdentifier == localeIdentifier
            }) {
                corrections[idx].count += 1
            } else {
                corrections.append(TitleCorrection(
                    id: UUID(),
                    originalTitle: original,
                    confirmedTitle: confirmed,
                    localeIdentifier: localeIdentifier,
                    count: 1
                ))
            }
            saveCorrections(corrections, to: defaults)
        }
        VoiceTodoLog.app.info("correction.record original=\(original, privacy: .public) confirmed=\(confirmed, privacy: .public) locale=\(localeIdentifier, privacy: .public)")
    }

    /// 返回达到阈值(count ≥ threshold)的修正,按 count 降序。
    func suggestions() -> [TitleCorrection] {
        guard let defaults else { return [] }
        return lock.withLock { loadCorrections(from: defaults) }
            .filter { $0.count >= Self.threshold }
            .sorted { $0.count > $1.count }
    }

    /// 移除指定修正(建议被接受或拒绝后调用)。
    func remove(id: UUID) {
        guard let defaults else { return }
        lock.withLock {
            var corrections = loadCorrections(from: defaults)
            corrections.removeAll { $0.id == id }
            saveCorrections(corrections, to: defaults)
        }
    }

    func clear() {
        guard let defaults else { return }
        lock.withLock {
            defaults.removeObject(forKey: Self.correctionsKey)
        }
    }

    private func loadCorrections(from defaults: UserDefaults) -> [TitleCorrection] {
        guard let data = defaults.data(forKey: Self.correctionsKey) else { return [] }
        return (try? JSONDecoder().decode([TitleCorrection].self, from: data)) ?? []
    }

    private func saveCorrections(_ corrections: [TitleCorrection], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: Self.correctionsKey)
        }
    }
}

/// 建议写入 glossary 的候选(传给 UI 展示)。
struct GlossarySuggestion: Identifiable, Equatable {
    let id: UUID
    let correction: TitleCorrection

    init(correction: TitleCorrection) {
        self.id = correction.id
        self.correction = correction
    }
}
