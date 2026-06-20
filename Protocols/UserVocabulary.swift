import Foundation
import NaturalLanguage

enum UserVocabularyConfig {
    static let retentionDays = 60
    static let maxStoredTerms = 200
    static let speechContextualStringsLimit = 100
    static let aiHintsLimit = 30
    static let maxTermCharacters = 32
    static let maxChineseTermCharacters = 8

    static var retentionInterval: TimeInterval {
        TimeInterval(retentionDays * 24 * 60 * 60)
    }
}

enum UserVocabularySource: String, Codable, Equatable {
    case confirmedTodo
    case editedTodo
}

struct UserVocabularyTerm: Codable, Equatable, Identifiable {
    var id: String { "\(localeIdentifier):\(term.lowercased())" }
    var term: String
    var localeIdentifier: String
    var frequency: Int
    var lastSeenAt: Date
    var source: UserVocabularySource
}

protocol UserVocabularyProviding {
    func vocabularyHints(localeIdentifier: String, limit: Int, now: Date) -> [String]
}

extension UserVocabularyProviding {
    func vocabularyHints(localeIdentifier: String, limit: Int) -> [String] {
        vocabularyHints(localeIdentifier: localeIdentifier, limit: limit, now: Date())
    }
}

final class UserVocabularyStore: UserVocabularyProviding {
    static let shared = UserVocabularyStore()
    static let isEnabledKey = "VoiceTodoUserVocabularyEnabled"
    static let termsKey = "VoiceTodoUserVocabularyTerms"

    private let defaults: UserDefaults?
    private let extractor: VocabularyTermExtractor
    private let lock = NSLock()

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier),
        extractor: VocabularyTermExtractor = VocabularyTermExtractor()
    ) {
        self.defaults = defaults
        self.extractor = extractor
    }

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)
    }

    func isEnabled() -> Bool {
        guard let defaults else {
            VoiceTodoLog.app.warning("vocabulary.enabled.defaults_unavailable")
            return true
        }
        guard defaults.object(forKey: Self.isEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.isEnabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard let defaults else {
            VoiceTodoLog.app.warning("vocabulary.enabled.set_failed reason=defaults_unavailable enabled=\(enabled)")
            return
        }
        defaults.set(enabled, forKey: Self.isEnabledKey)
    }

    func clear() {
        guard let defaults else {
            VoiceTodoLog.app.warning("vocabulary.clear_failed reason=defaults_unavailable")
            return
        }
        lock.withLock {
            defaults.removeObject(forKey: Self.termsKey)
        }
        VoiceTodoLog.app.info("vocabulary.clear.success")
    }

    func learn(
        from todos: [ExtractedTodo],
        localeIdentifier: String,
        source: UserVocabularySource,
        now: Date = Date()
    ) {
        let texts = todos.flatMap { todo in
            [todo.title, todo.detail]
        }
        learn(fromTexts: texts, localeIdentifier: localeIdentifier, source: source, now: now)
    }

    func learn(
        from todo: TodoItemData,
        title: String,
        detail: String?,
        localeIdentifier: String,
        source: UserVocabularySource,
        now: Date = Date()
    ) {
        learn(fromTexts: [title, detail, todo.dueHint].compactMap { $0 }, localeIdentifier: localeIdentifier, source: source, now: now)
    }

    func learn(
        fromTexts texts: [String],
        localeIdentifier: String,
        source: UserVocabularySource,
        now: Date = Date()
    ) {
        let startedAt = Date()
        guard isEnabled() else {
            VoiceTodoLog.app.info("vocabulary.learn.skipped reason=disabled textCount=\(texts.count)")
            return
        }
        guard let defaults else {
            VoiceTodoLog.app.warning("vocabulary.learn.skipped reason=defaults_unavailable textCount=\(texts.count)")
            return
        }

        let extractedTerms = extractor.extractTerms(from: texts, localeIdentifier: localeIdentifier)
        guard !extractedTerms.isEmpty else {
            VoiceTodoLog.app.info("vocabulary.learn.no_terms source=\(source.rawValue, privacy: .public) textCount=\(texts.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }

        lock.withLock {
            var terms = activeTerms(loadTerms(from: defaults), now: now)
            var indexByKey = Dictionary(uniqueKeysWithValues: terms.enumerated().map { offset, term in
                (Self.storageKey(term.term, localeIdentifier: term.localeIdentifier), offset)
            })

            for extractedTerm in extractedTerms {
                let key = Self.storageKey(extractedTerm, localeIdentifier: localeIdentifier)
                if let index = indexByKey[key] {
                    terms[index].frequency += 1
                    terms[index].lastSeenAt = now
                    terms[index].source = source
                } else {
                    let term = UserVocabularyTerm(
                        term: extractedTerm,
                        localeIdentifier: localeIdentifier,
                        frequency: 1,
                        lastSeenAt: now,
                        source: source
                    )
                    indexByKey[key] = terms.count
                    terms.append(term)
                }
            }

            terms = Array(sortedTerms(terms).prefix(UserVocabularyConfig.maxStoredTerms))
            saveTerms(terms, defaults: defaults)
        }

        VoiceTodoLog.app.info("vocabulary.learn.success source=\(source.rawValue, privacy: .public) textCount=\(texts.count) extractedCount=\(extractedTerms.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    func vocabularyHints(localeIdentifier: String, limit: Int, now: Date = Date()) -> [String] {
        let startedAt = Date()
        guard limit > 0 else { return [] }
        guard isEnabled() else {
            VoiceTodoLog.app.debug("vocabulary.hints.disabled locale=\(localeIdentifier, privacy: .public)")
            return []
        }
        guard let defaults else {
            VoiceTodoLog.app.warning("vocabulary.hints.defaults_unavailable locale=\(localeIdentifier, privacy: .public)")
            return []
        }

        let hints = lock.withLock {
            sortedTerms(activeTerms(loadTerms(from: defaults), now: now))
                .filter { Self.localeMatches($0.localeIdentifier, localeIdentifier) }
                .prefix(limit)
                .map(\.term)
        }

        VoiceTodoLog.app.debug("vocabulary.hints.ready locale=\(localeIdentifier, privacy: .public) count=\(hints.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return hints
    }

    func storedTerms(now: Date = Date()) -> [UserVocabularyTerm] {
        guard let defaults else { return [] }
        return lock.withLock {
            sortedTerms(activeTerms(loadTerms(from: defaults), now: now))
        }
    }

    private func loadTerms(from defaults: UserDefaults) -> [UserVocabularyTerm] {
        guard let data = defaults.data(forKey: Self.termsKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([UserVocabularyTerm].self, from: data)
        } catch {
            VoiceTodoLog.app.error("vocabulary.load.failed dataBytes=\(data.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }

    private func saveTerms(_ terms: [UserVocabularyTerm], defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(terms)
            defaults.set(data, forKey: Self.termsKey)
        } catch {
            VoiceTodoLog.app.error("vocabulary.save.failed count=\(terms.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    private func activeTerms(_ terms: [UserVocabularyTerm], now: Date) -> [UserVocabularyTerm] {
        let cutoff = now.addingTimeInterval(-UserVocabularyConfig.retentionInterval)
        return terms.filter { $0.lastSeenAt >= cutoff }
    }

    private func sortedTerms(_ terms: [UserVocabularyTerm]) -> [UserVocabularyTerm] {
        terms.sorted { lhs, rhs in
            if lhs.frequency != rhs.frequency {
                return lhs.frequency > rhs.frequency
            }
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            return lhs.term.localizedStandardCompare(rhs.term) == .orderedAscending
        }
    }

    private static func storageKey(_ term: String, localeIdentifier: String) -> String {
        "\(normalizedLocaleLanguage(localeIdentifier)):\(term.lowercased())"
    }

    private static func localeMatches(_ stored: String, _ requested: String) -> Bool {
        normalizedLocaleLanguage(stored) == normalizedLocaleLanguage(requested)
    }

    private static func normalizedLocaleLanguage(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh") { return "zh" }
        if lowercased.hasPrefix("en") { return "en" }
        return lowercased.split(separator: "-").first.map(String.init) ?? lowercased
    }
}

struct VocabularyTermExtractor {
    private static let chineseStopWords: Set<String> = [
        "今天", "明天", "后天", "昨天", "今晚", "上午", "下午", "晚上", "下周", "这周", "本周", "月底",
        "提醒", "完成", "我要", "我想", "需要", "记得", "帮我", "然后", "还有", "顺便", "那个", "这个",
        "待办", "任务", "事情", "安排", "处理", "准备", "整理", "学习", "练习", "复习", "背诵", "背单词",
        "买", "去", "做", "写", "看", "开会", "提交", "跟进"
    ]

    private static let englishStopWords: Set<String> = [
        "the", "and", "for", "with", "today", "tomorrow", "tonight", "todo", "task", "remind",
        "finish", "complete", "need", "needs", "want", "buy", "call", "write", "read", "review",
        "study", "practice", "prepare", "meeting", "email", "this", "that", "next", "week"
    ]

    func extractTerms(from texts: [String], localeIdentifier: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()

        for text in texts {
            for candidate in candidates(from: text) {
                guard let normalized = normalize(candidate), !normalized.isEmpty else {
                    continue
                }
                let key = normalized.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                terms.append(normalized)
            }
        }

        return terms
    }

    private func candidates(from text: String) -> [String] {
        var results: [String] = []
        results.append(contentsOf: latinCandidates(from: text))
        results.append(contentsOf: tokenizerCandidates(from: text))
        results.append(contentsOf: focusedChineseCandidates(from: text))
        return results
    }

    private func latinCandidates(from text: String) -> [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9+#._-]{1,31}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private func tokenizerCandidates(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var results: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            results.append(String(text[range]))
            return true
        }
        return results
    }

    private func focusedChineseCandidates(from text: String) -> [String] {
        let pattern = #"\p{Han}{2,12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let textRange = Range(match.range, in: text) else { return nil }
            let raw = String(text[textRange])
            let trimmed = stripChineseNoise(from: raw)
            guard trimmed.count >= 2 else { return nil }
            return trimmed
        }
    }

    private func stripChineseNoise(from raw: String) -> String {
        var text = raw
        var changed = true
        while changed {
            changed = false
            for word in Self.chineseStopWords.sorted(by: { $0.count > $1.count }) {
                if text.hasPrefix(word) {
                    text.removeFirst(word.count)
                    changed = true
                }
                if text.hasSuffix(word) {
                    text.removeLast(word.count)
                    changed = true
                }
            }
        }
        return text
    }

    private func normalize(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、,.!?;；:：()（）[]【】{}<>《》\"'“”‘’`~"))

        guard !trimmed.isEmpty,
              trimmed.count >= 2,
              trimmed.count <= UserVocabularyConfig.maxTermCharacters,
              !trimmed.allSatisfy(\.isNumber),
              !trimmed.contains(where: \.isNewline) else {
            return nil
        }

        let compacted = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compacted.split(separator: " ").count <= 2 else {
            return nil
        }
        if containsHan(compacted), compacted.count > UserVocabularyConfig.maxChineseTermCharacters {
            return nil
        }
        if isStopWord(compacted) {
            return nil
        }
        return compacted
    }

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func isStopWord(_ term: String) -> Bool {
        let lowercased = term.lowercased()
        if Self.englishStopWords.contains(lowercased) {
            return true
        }
        return Self.chineseStopWords.contains(term)
    }
}

private extension NSLock {
    /// 与 GCD 的 `sync` 概念不同（这是 NSLock 显式 lock/unlock），改名 withLock 避免混淆。
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
