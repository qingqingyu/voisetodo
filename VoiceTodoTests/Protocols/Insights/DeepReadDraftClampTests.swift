import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `DeepReadConfig.clampedDraft`(v6 §3.1)的验收:超长草稿按词/句边界截断,
/// 无断点丢弃,未超长原样。英文提示词允许 ≤15 词,常超 60 字符,旧 `prefix`
/// 硬截出过「the weig」这类半截词——本组是回归护栏。
final class DeepReadDraftClampTests: XCTestCase {

    // MARK: 未超长 → 原样

    func testShortDraftReturnedVerbatim() {
        XCTAssertEqual(DeepReadConfig.clampedDraft("工作占了 12 件,下周先放下。"), "工作占了 12 件,下周先放下。")
        XCTAssertEqual(DeepReadConfig.clampedDraft(""), "")
        XCTAssertEqual(DeepReadConfig.clampedDraft(String(repeating: "短", count: DeepReadConfig.draftMaxLength)),
                       String(repeating: "短", count: DeepReadConfig.draftMaxLength))
    }

    // MARK: 英文超长 → 截在词边界(空格)

    func testOverlongEnglishTruncatesAtWordBoundary() {
        // 65 字符(>60),上限内最后一个断点是空格——旧行为会出「the weig」。
        let draft = "Work is heavy next week and I want to drop the weight soon enough"
        XCTAssertEqual(draft.count, 65)
        XCTAssertGreaterThan(draft.count, DeepReadConfig.draftMaxLength)
        let clamped = DeepReadConfig.clampedDraft(draft)
        XCTAssertLessThanOrEqual(clamped.count, DeepReadConfig.draftMaxLength)
        // 截断点必须是完整词尾(空格截断后无残词):结果要么为空,要么是
        // 完整词序列,且是原串的前缀。
        if !clamped.isEmpty {
            XCTAssertTrue(draft.hasPrefix(clamped))
            XCTAssertFalse(clamped.last!.isLetter == true && draft.dropFirst(clamped.count).first?.isLetter == true,
                           "截断处劈开了单词: …\"\(clamped.suffix(4))|\(draft.dropFirst(clamped.count).prefix(4))\"")
        }
    }

    // MARK: 中文超长 → 截在标点

    func testOverlongChineseTruncatesAtPunctuation() {
        let long = String(repeating: "下周想把工作放一放", count: 8) + "。结尾"
        XCTAssertGreaterThan(long.count, DeepReadConfig.draftMaxLength)
        let clamped = DeepReadConfig.clampedDraft(long)
        XCTAssertLessThanOrEqual(clamped.count, DeepReadConfig.draftMaxLength)
        // 本夹具上限内没有标点,补一个带句号的:句号恰在 60 字符内时被保留。
        let punct = String(repeating: "这周事太多想先收尾", count: 5) + "。然后继续写别的把句子拉得很长很长很长"
        let clampedPunct = DeepReadConfig.clampedDraft(punct)
        XCTAssertTrue(clampedPunct.hasSuffix("。"), "上限内最后一个断点应是句号并保留: \(clampedPunct)")
        XCTAssertLessThanOrEqual(clampedPunct.count, DeepReadConfig.draftMaxLength)
    }

    // MARK: 无断点 → 丢弃(空串)

    func testOverlongWithoutBreakPointIsDiscarded() {
        let noBreak = String(repeating: "无", count: DeepReadConfig.draftMaxLength + 10)
        XCTAssertEqual(DeepReadConfig.clampedDraft(noBreak), "")
        // 纯长英文单词无空格:同样丢弃。
        let longWord = String(repeating: "a", count: DeepReadConfig.draftMaxLength + 5)
        XCTAssertEqual(DeepReadConfig.clampedDraft(longWord), "")
    }

    // MARK: 断点是空格 → 尾部空白清干净

    func testTrailingWhitespaceAfterBreakIsTrimmed() {
        // 最后一个断点(第 57 位的空格)之后到上限内全是字母,截断后不应挂空白。
        let draft = "one two three four five six seven eight nine ten eleven tw"
        let clamped = DeepReadConfig.clampedDraft(draft)
        XCTAssertFalse(clamped.last?.isWhitespace == true)
        XCTAssertTrue(draft.hasPrefix(clamped))
    }
}
