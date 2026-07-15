import Foundation

/// 个人词库条目类型。
enum PersonalGlossaryEntryType: String, Codable, CaseIterable, Sendable {
    /// 别名映射:"老地方"→"星光健身房"
    case alias
    /// 时间约定:"交作业"→每周五
    case convention
}

/// 个人词库条目——用户手动教的"说法→含义"映射,注入 prompt 让 AI 理解个人表达习惯。
/// 本地存储(App Group UserDefaults),不上云,零 ML 风险,教一次就懂。
struct PersonalGlossaryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var type: PersonalGlossaryEntryType
    /// 用户实际说的词:"老地方"、"交作业"、"回头"
    var phrase: String
    /// 别名展开目标:"星光健身房"(type=.alias 时必填)
    var expansion: String?
    /// 默认时间线索:"每周五"、"3天内"(type=.convention 时必填)
    var defaultTimeHint: String?
    /// 创建时语言标识,用于按 locale 过滤。
    var localeIdentifier: String

    init(
        id: UUID = UUID(),
        type: PersonalGlossaryEntryType,
        phrase: String,
        expansion: String? = nil,
        defaultTimeHint: String? = nil,
        localeIdentifier: String
    ) {
        self.id = id
        self.type = type
        self.phrase = phrase
        self.expansion = expansion
        self.defaultTimeHint = defaultTimeHint
        self.localeIdentifier = localeIdentifier
    }
}

/// 个人词库查询协议(DI 用)。
protocol PersonalGlossaryProviding {
    /// 返回格式化的个人约定文本,直接拼入 system prompt。nil = 无约定。
    func personalHints(localeIdentifier: String) -> String?
}

/// 个人词库存储(App Group UserDefaults),仿 UserVocabularyStore 范式。
/// 线程安全(NSLock),可手动增删,可清空。
final class PersonalGlossaryStore: PersonalGlossaryProviding {
    static let shared = PersonalGlossaryStore()
    static let entriesKey = "VoiceTodoPersonalGlossaryEntries"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)) {
        self.defaults = defaults
    }

    // MARK: - CRUD

    func add(_ entry: PersonalGlossaryEntry) {
        guard let defaults else {
            VoiceTodoLog.app.warning("glossary.add.failed reason=defaults_unavailable")
            return
        }
        lock.withLock {
            var entries = loadEntries(from: defaults)
            entries.removeAll { $0.id == entry.id || $0.phrase == entry.phrase }
            entries.append(entry)
            saveEntries(entries, to: defaults)
        }
        VoiceTodoLog.app.info("glossary.add.success phrase=\(entry.phrase, privacy: .public) type=\(entry.type.rawValue, privacy: .public)")
    }

    func remove(id: UUID) {
        guard let defaults else { return }
        lock.withLock {
            var entries = loadEntries(from: defaults)
            entries.removeAll { $0.id == id }
            saveEntries(entries, to: defaults)
        }
    }

    func allEntries() -> [PersonalGlossaryEntry] {
        guard let defaults else { return [] }
        return lock.withLock { loadEntries(from: defaults) }
    }

    func clear() {
        guard let defaults else { return }
        lock.withLock {
            defaults.removeObject(forKey: Self.entriesKey)
        }
        VoiceTodoLog.app.info("glossary.clear.success")
    }

    // MARK: - PersonalGlossaryProviding

    func personalHints(localeIdentifier: String) -> String? {
        let entries = allEntries().filter { entry in
            Self.localeMatches(entry.localeIdentifier, localeIdentifier)
        }
        guard !entries.isEmpty else { return nil }

        let lines = entries.map { entry -> String in
            switch entry.type {
            case .alias:
                let exp = entry.expansion ?? ""
                return localeIdentifier.hasPrefix("zh")
                    ? "• \"\(entry.phrase)\" 指 \"\(exp)\""
                    : "• \"\(entry.phrase)\" means \"\(exp)\""
            case .convention:
                let hint = entry.defaultTimeHint ?? ""
                return localeIdentifier.hasPrefix("zh")
                    ? "• \"\(entry.phrase)\" 通常安排在 \(hint)"
                    : "• \"\(entry.phrase)\" is usually scheduled \(hint)"
            }
        }

        let header = localeIdentifier.hasPrefix("zh")
            ? "用户个人约定(请展开别名并套用默认时间):"
            : "User personal conventions (expand aliases and apply default times):"
        return "\(header)\n\(lines.joined(separator: "\n"))"
    }

    // MARK: - Private

    private func loadEntries(from defaults: UserDefaults) -> [PersonalGlossaryEntry] {
        guard let data = defaults.data(forKey: Self.entriesKey) else { return [] }
        return (try? JSONDecoder().decode([PersonalGlossaryEntry].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [PersonalGlossaryEntry], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }

    private static func localeMatches(_ stored: String, _ requested: String) -> Bool {
        normalizedLocaleLanguage(stored) == normalizedLocaleLanguage(requested)
    }

    private static func normalizedLocaleLanguage(_ identifier: String) -> String {
        String(identifier.prefix(2).lowercased())
    }
}
