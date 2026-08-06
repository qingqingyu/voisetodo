import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

final class CorrectionTrackerTests: XCTestCase {

    // MARK: - TitleCorrection.extractPhraseDiff

    func testDiffReturnsNilForIdenticalStrings() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "去老地方", confirmed: "去老地方"))
    }

    func testDiffReturnsNilForPureAddition() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "买牛奶", confirmed: "买牛奶和面包"))
    }

    func testDiffReturnsNilForPureDeletion() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "买牛奶和面包", confirmed: "买牛奶"))
    }

    func testDiffReturnsNilForSingleCharacterReplacement() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "开门", confirmed: "关门"))
    }

    func testDiffReturnsNilWhenOnlySingleCharMiddleChanged() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "买红苹果", confirmed: "买青苹果"))
    }

    func testDiffReturnsDiffForSharedPrefixMultiCharReplacement() {
        let result = TitleCorrection.extractPhraseDiff(original: "去老地方", confirmed: "去星光健身房")
        XCTAssertEqual(result?.phrase, "老地方")
        XCTAssertEqual(result?.expansion, "星光健身房")
    }

    func testDiffReturnsDiffForSharedSuffixMultiCharReplacement() {
        let result = TitleCorrection.extractPhraseDiff(original: "明天老地方", confirmed: "明天新天地")
        XCTAssertEqual(result?.phrase, "老地方")
        XCTAssertEqual(result?.expansion, "新天地")
    }

    func testDiffReturnsDiffForSharedPrefixAndSuffixMultiCharMiddle() {
        let result = TitleCorrection.extractPhraseDiff(
            original: "明天去老地方开会",
            confirmed: "明天去星光健身房开会"
        )
        XCTAssertEqual(result?.phrase, "老地方")
        XCTAssertEqual(result?.expansion, "星光健身房")
    }

    func testDiffAcceptsAsymmetricLengthsWhenEitherSideAtLeastTwo() {
        let result = TitleCorrection.extractPhraseDiff(original: "axd", confirmed: "abcd")
        XCTAssertEqual(result?.phrase, "x")
        XCTAssertEqual(result?.expansion, "bc")
    }

    func testDiffAcceptsMultiCharPhraseWithSingleCharExpansion() {
        let result = TitleCorrection.extractPhraseDiff(original: "abcd", confirmed: "axd")
        XCTAssertEqual(result?.phrase, "bc")
        XCTAssertEqual(result?.expansion, "x")
    }

    func testDiffReturnsNilForEmptyOriginal() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "", confirmed: "abc"))
    }

    func testDiffReturnsNilForEmptyConfirmed() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "abc", confirmed: ""))
    }

    func testDiffHandlesMixedLatinAndHan() {
        let result = TitleCorrection.extractPhraseDiff(original: "Anki 复习", confirmed: "Anki 背单词")
        XCTAssertEqual(result?.phrase, "复习")
        XCTAssertEqual(result?.expansion, "背单词")
    }

    func testDiffTreatsEmojiAsSingleCharacter() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "😂你好", confirmed: "😭你好"))
    }

    func testDiffDoesNotOverlapPrefixAndSuffix() {
        XCTAssertNil(TitleCorrection.extractPhraseDiff(original: "abc", confirmed: "abcbc"))
    }

    // MARK: - CorrectionTracker.record

    func testRecordFirstCallCreatesEntryWithCountOne() {
        let tracker = makeTracker()
        tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")

        XCTAssertEqual(tracker.suggestions(), [])
    }

    func testRecordSameKeyIncrementsCount() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        let suggestions = tracker.suggestions()
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.originalTitle, "老地方")
        XCTAssertEqual(suggestions.first?.confirmedTitle, "星光健身房")
        XCTAssertEqual(suggestions.first?.localeIdentifier, "zh-Hans")
        XCTAssertEqual(suggestions.first?.count, CorrectionTracker.threshold)
    }

    func testRecordDifferentLocaleCreatesSeparateEntry() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "old place", confirmed: "Star Gym", localeIdentifier: "en-US")
        }

        let suggestions = tracker.suggestions()
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.contains { $0.localeIdentifier == "zh-Hans" })
        XCTAssertTrue(suggestions.contains { $0.localeIdentifier == "en-US" })
    }

    func testRecordReversedDirectionCreatesSeparateEntry() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "星光健身房", confirmed: "老地方", localeIdentifier: "zh-Hans")
        }

        let suggestions = tracker.suggestions()
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.contains { $0.originalTitle == "老地方" })
        XCTAssertTrue(suggestions.contains { $0.originalTitle == "星光健身房" })
    }

    func testRecordDifferentOriginalCreatesSeparateEntry() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "老地坊", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions().count, 2)
    }

    func testRecordDifferentConfirmedCreatesSeparateEntry() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "老地方", confirmed: "星光健身馆", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions().count, 2)
    }

    func testRecordOriginalEqualsConfirmedIgnored() {
        let tracker = makeTracker()
        for _ in 0..<5 {
            tracker.record(original: "老地方", confirmed: "老地方", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions(), [])
    }

    func testRecordEmptyStringsIgnored() {
        let tracker = makeTracker()
        for _ in 0..<5 {
            tracker.record(original: "", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "老地方", confirmed: "", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions(), [])
    }

    func testRecordWhitespaceOnlyStringsIgnored() {
        let tracker = makeTracker()
        for _ in 0..<5 {
            tracker.record(original: "   ", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "老地方", confirmed: "\t\n", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions(), [])
    }

    // MARK: - CorrectionTracker.suggestions

    func testSuggestionsEmptyStoreReturnsEmpty() {
        XCTAssertEqual(makeTracker().suggestions(), [])
    }

    func testSuggestionsBelowThresholdExcluded() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold - 1 {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions(), [])
    }

    func testSuggestionsAtThresholdIncluded() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions().count, 1)
    }

    func testSuggestionsAboveThresholdIncluded() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold + 5 {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        XCTAssertEqual(tracker.suggestions().count, 1)
        XCTAssertEqual(tracker.suggestions().first?.count, CorrectionTracker.threshold + 5)
    }

    func testSuggestionsSortedByCountDescending() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "低频", confirmed: "LowFreq", localeIdentifier: "zh-Hans")
        }
        for _ in 0..<CorrectionTracker.threshold + 4 {
            tracker.record(original: "高频", confirmed: "HighFreq", localeIdentifier: "zh-Hans")
        }

        let suggestions = tracker.suggestions()
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.originalTitle, "高频")
        XCTAssertEqual(suggestions.first?.count, CorrectionTracker.threshold + 4)
        XCTAssertEqual(suggestions.last?.originalTitle, "低频")
        XCTAssertEqual(suggestions.last?.count, CorrectionTracker.threshold)
    }

    // MARK: - CorrectionTracker.remove

    func testRemoveExistingIdRemovesEntry() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }
        guard let id = tracker.suggestions().first?.id else {
            XCTFail("应该有一条建议")
            return
        }

        tracker.remove(id: id)

        XCTAssertEqual(tracker.suggestions(), [])
    }

    func testRemoveUnknownIdIsNoOp() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }
        let before = tracker.suggestions()

        tracker.remove(id: UUID())

        XCTAssertEqual(tracker.suggestions(), before)
    }

    // MARK: - CorrectionTracker.clear

    func testClearRemovesAllEntries() {
        let tracker = makeTracker()
        for _ in 0..<CorrectionTracker.threshold {
            tracker.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
            tracker.record(original: "old place", confirmed: "Star Gym", localeIdentifier: "en-US")
        }
        XCTAssertEqual(tracker.suggestions().count, 2)

        tracker.clear()

        XCTAssertEqual(tracker.suggestions(), [])
    }

    // MARK: - 持久化 + 损坏数据

    func testPersistenceNewInstanceWithSameDefaultsSeesData() {
        let defaults = makeDefaults()
        let writer = CorrectionTracker(defaults: defaults)
        for _ in 0..<CorrectionTracker.threshold {
            writer.record(original: "老地方", confirmed: "星光健身房", localeIdentifier: "zh-Hans")
        }

        let reader = CorrectionTracker(defaults: defaults)
        XCTAssertEqual(reader.suggestions().count, 1)
        XCTAssertEqual(reader.suggestions().first?.originalTitle, "老地方")
    }

    func testCorruptJSONReturnsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: CorrectionTracker.correctionsKey)

        let tracker = CorrectionTracker(defaults: defaults)
        XCTAssertEqual(tracker.suggestions(), [])
    }

    // MARK: - 辅助

    private func makeTracker() -> CorrectionTracker {
        CorrectionTracker(defaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "VoiceTodoTests.CorrectionTracker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
