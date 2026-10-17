import XCTest
import Foundation
#if canImport(UIKit)
import UIKit
#endif
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

    // MARK: 英文超长 → 截在词边界(空格),结果精确

    func testOverlongEnglishTruncatesAtWordBoundary() {
        // 65 字符(>60):上限内最后一个断点是 "soon" 后的空格(第 58 位),
        // 截断保留到该空格并去尾部空白——旧行为会出「the weig」半截词。
        let draft = "Work is heavy next week and I want to drop the weight soon enough"
        XCTAssertEqual(draft.count, 65)
        XCTAssertEqual(
            DeepReadConfig.clampedDraft(draft),
            "Work is heavy next week and I want to drop the weight soon"
        )
    }

    // MARK: 中文超长

    /// 无标点(上限内无断点)→ 丢弃整条,空串。
    func testOverlongChineseWithoutBreakPointIsDiscarded() {
        let noBreak = String(repeating: "下周想把工作放一放", count: 8) + "。结尾"
        XCTAssertGreaterThan(noBreak.count, DeepReadConfig.draftMaxLength)
        XCTAssertEqual(DeepReadConfig.clampedDraft(noBreak), "", "上限内无断点 → 空串,不显示半截")
    }

    /// 有标点(句号落在上限内)→ 保留到句号,结果精确。
    func testOverlongChineseTruncatesAtPunctuation() {
        let punct = String(repeating: "这周事太多想先收尾", count: 5) + "。然后继续写别的把句子拉得很长很长很长"
        XCTAssertEqual(
            DeepReadConfig.clampedDraft(punct),
            String(repeating: "这周事太多想先收尾", count: 5) + "。",
            "上限内最后一个断点是句号(第 54 位),截断保留句号"
        )
    }

    // MARK: 断点是空格 → 尾部空白清干净(夹具 > 60 字符)

    func testTrailingWhitespaceAfterBreakIsTrimmed() {
        // 71 字符:上限(60)内最后一个空格在 "eleven" 后(第 56 位),
        // 截断到词尾且不挂尾部空白。
        let draft = "one two three four five six seven eight nine ten eleven twelve thirteen"
        XCTAssertEqual(draft.count, 71)
        let clamped = DeepReadConfig.clampedDraft(draft)
        XCTAssertEqual(clamped, "one two three four five six seven eight nine ten eleven")
        XCTAssertNotEqual(clamped.last, " ")
        XCTAssertTrue(draft.hasPrefix(clamped))
    }

    // MARK: 断点字符集健全性

    /// 信号图标符号可用性(review 修订 4):InsightCardView 底部的强度图标
    /// 用 `cellularbars`——`cellbars` 实测不存在(本护栏首跑即红),符号
    /// 缺失时视图渲染空白;若再换符号,同步改这里的断言与视图。
    /// UIKit 在 macOS 协议测试目标不可用,整测例按项目惯例编译剔除。
    #if canImport(UIKit)
    func testSignalStrengthSFSymbolExists() {
        XCTAssertNotNil(UIImage(systemName: "cellularbars"), "SF Symbol cellularbars 应存在;缺失则视图与这里同步换")
    }
    #endif
}
