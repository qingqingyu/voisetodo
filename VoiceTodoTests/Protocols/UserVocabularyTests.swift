import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class UserVocabularyTests: XCTestCase {
    func testVocabularyExtractorKeepsDomainTermsAndFiltersNoise() {
        let extractor = VocabularyTermExtractor()

        let terms = extractor.extractTerms(
            from: [
                "今天完成 Anki IELTS shadowing SwiftUI 雅思 口语练习",
                "明天提醒我要完成"
            ],
            localeIdentifier: "zh-Hans"
        )

        XCTAssertTrue(terms.contains("Anki"))
        XCTAssertTrue(terms.contains("IELTS"))
        XCTAssertTrue(terms.contains("shadowing"))
        XCTAssertTrue(terms.contains("SwiftUI"))
        XCTAssertTrue(terms.contains("雅思"))
        XCTAssertFalse(terms.contains("今天"))
        XCTAssertFalse(terms.contains("明天"))
        XCTAssertFalse(terms.contains("提醒"))
        XCTAssertFalse(terms.contains("完成"))
        XCTAssertFalse(terms.contains("我要"))
    }

    func testVocabularyStoreReturnsRecentTermsWithinRetention() {
        let defaults = makeDefaults()
        let store = UserVocabularyStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.learn(
            fromTexts: ["复习 Anki IELTS 雅思"],
            localeIdentifier: "zh-Hans",
            source: .confirmedTodo,
            now: now
        )

        let hints = store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10, now: now.addingTimeInterval(30))
        XCTAssertTrue(hints.contains("Anki"))
        XCTAssertTrue(hints.contains("IELTS"))
        XCTAssertTrue(hints.contains("雅思"))
    }

    func testVocabularyStoreDropsTermsAfterRetention() {
        let defaults = makeDefaults()
        let store = UserVocabularyStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.learn(
            fromTexts: ["复习 Anki IELTS"],
            localeIdentifier: "zh-Hans",
            source: .confirmedTodo,
            now: now
        )

        let expiredAt = now.addingTimeInterval(UserVocabularyConfig.retentionInterval + 1)
        XCTAssertEqual(store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10, now: expiredAt), [])
    }

    func testVocabularyStoreHonorsDisabledPersonalization() {
        let defaults = makeDefaults()
        let store = UserVocabularyStore(defaults: defaults)
        store.setEnabled(false)

        store.learn(
            fromTexts: ["复习 Anki IELTS"],
            localeIdentifier: "zh-Hans",
            source: .confirmedTodo,
            now: Date()
        )

        XCTAssertEqual(store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10), [])
        XCTAssertEqual(store.storedTerms(), [])
    }

    func testVocabularyStoreClearRemovesTerms() {
        let defaults = makeDefaults()
        let store = UserVocabularyStore(defaults: defaults)

        store.learn(
            fromTexts: ["复习 Anki IELTS"],
            localeIdentifier: "zh-Hans",
            source: .confirmedTodo,
            now: Date()
        )
        XCTAssertFalse(store.storedTerms().isEmpty)

        store.clear()

        XCTAssertEqual(store.storedTerms(), [])
        XCTAssertEqual(store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10), [])
    }

    func testVocabularyStoreIgnoresCorruptJSON() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: UserVocabularyStore.termsKey)
        let store = UserVocabularyStore(defaults: defaults)

        XCTAssertEqual(store.vocabularyHints(localeIdentifier: "zh-Hans", limit: 10), [])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "VoiceTodoTests.UserVocabulary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
