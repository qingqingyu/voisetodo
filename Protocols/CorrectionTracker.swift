import Foundation

/// 标题修正频次记录——追踪"用户反复把同一原始标题改成同一结果"。
/// 达到阈值后触发建议("记住吗?"),用户确认才写入 PersonalGlossary。
struct TitleCorrection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var originalTitle: String
    var confirmedTitle: String
    var localeIdentifier: String
    var count: Int
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
