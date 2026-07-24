import XCTest
@testable import VoiceTodo

/// TodoItem.from 的 due_date_basis 白名单 + rawTranscript 兜底过滤测试。
///
/// 8 个用例 = 4 basis 分支 × rawTranscript 非空/nil。
/// 验证方案 2(AI basis 白名单) + 方案 3(transcript 兜底) 的组合矩阵。
final class TodoItemFromBasisFilterTests: XCTestCase {

    // MARK: - .userExplicit 分支

    /// basis=userExplicit + transcript 有 cue → 保留 AI 给的 dueDate(双重确认)。
    func testUserExplicitWithCueKeepsAIDueDate() throws {
        let aiDueDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "交房租",
            detail: "明天交房租",
            dueDate: aiDueDate,
            dueHint: "明天",
            dueDateBasis: .userExplicit
        )
        let item = TodoItem.from(extracted, rawTranscript: "明天交房租")
        XCTAssertEqual(item.dueDate, aiDueDate)
    }

    /// basis=userExplicit + transcript 无 cue → 清空(AI 错标,方案 3 兜底拦截)。
    /// 关键场景:AI 误把 "prepare for Sunday" 标 user_explicit,客户端兜底清掉。
    func testUserExplicitWithoutCueClearsDueDate() throws {
        let aiDueDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "Prepare for Sunday",
            detail: "Prepare for Sunday",
            dueDate: aiDueDate,
            dueHint: "for Sunday",
            dueDateBasis: .userExplicit
        )
        let item = TodoItem.from(extracted, rawTranscript: "prepare for Sunday")
        XCTAssertNil(item.dueDate)
        // dueHint 应保留,供 ConfirmSheet 用户参考
        XCTAssertEqual(item.dueHint, "for Sunday")
    }

    /// basis=userExplicit + transcript == nil → 保留(没法校验,信 AI)。
    /// 对应 TodoStore.swift:58/95 单条/批量 add 路径(不传 rawTranscript)。
    func testUserExplicitWithNilTranscriptKeepsAIDueDate() throws {
        let aiDueDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "交房租",
            detail: "明天交房租",
            dueDate: aiDueDate,
            dueHint: "明天",
            dueDateBasis: .userExplicit
        )
        let item = TodoItem.from(extracted, rawTranscript: nil)
        XCTAssertEqual(item.dueDate, aiDueDate)
    }

    // MARK: - 非 userExplicit 分支(.titleMention / .inferred / nil)

    /// basis=titleMention + transcript 有 cue → 用 TodoDueDateResolver 扫 transcript 兜底算日期。
    func testTitleMentionWithCueFallsBackToTranscriptResolution() throws {
        let aiGivenDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "交房租",
            detail: "明天交房租",
            dueDate: aiGivenDate,
            dueHint: "明天",
            dueDateBasis: .titleMention
        )
        let item = TodoItem.from(extracted, rawTranscript: "明天交房租")
        // 兜底算出的日期应该是 "明天" = 今天 + 1 天(不是 AI 给的硬编码 2026-07-20)
        let calendar = Calendar.current
        let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        XCTAssertEqual(calendar.startOfDay(for: item.dueDate!), calendar.startOfDay(for: expectedTomorrow))
    }

    /// basis=titleMention + transcript 无 cue → 清空。
    func testTitleMentionWithoutCueClearsDueDate() throws {
        let aiDueDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "Prepare for Sunday",
            detail: "Prepare for Sunday",
            dueDate: aiDueDate,
            dueHint: "for Sunday",
            dueDateBasis: .titleMention
        )
        let item = TodoItem.from(extracted, rawTranscript: "prepare for Sunday")
        XCTAssertNil(item.dueDate)
    }

    /// basis=titleMention + transcript == nil → 清空(保守)。
    func testTitleMentionWithNilTranscriptClearsDueDate() throws {
        let aiDueDate = try makeDate(year: 2026, month: 7, day: 20)
        let extracted = ExtractedTodo(
            title: "Prepare for Sunday",
            dueDate: aiDueDate,
            dueDateBasis: .titleMention
        )
        let item = TodoItem.from(extracted, rawTranscript: nil)
        XCTAssertNil(item.dueDate)
    }

    /// basis=nil(旧 AI 响应兼容) + transcript 有 cue → 兜底算日期。
    /// 关键向后兼容场景:旧 AI 不返回 basis 字段,但有 dueDate + transcript 有时间词。
    func testNilBasisWithCueFallsBackToTranscriptResolution() throws {
        let extracted = ExtractedTodo(
            title: "交房租",
            detail: "明天交房租",
            dueDate: try makeDate(year: 2026, month: 7, day: 20),
            dueHint: "明天",
            dueDateBasis: nil
        )
        let item = TodoItem.from(extracted, rawTranscript: "明天交房租")
        XCTAssertNotNil(item.dueDate)
        let calendar = Calendar.current
        let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        XCTAssertEqual(calendar.startOfDay(for: item.dueDate!), calendar.startOfDay(for: expectedTomorrow))
    }

    /// basis=nil + transcript 无 cue → 清空。
    func testNilBasisWithoutCueClearsDueDate() throws {
        let extracted = ExtractedTodo(
            title: "Prepare for Sunday",
            detail: "Prepare for Sunday",
            dueDate: try makeDate(year: 2026, month: 7, day: 20),
            dueDateBasis: nil
        )
        let item = TodoItem.from(extracted, rawTranscript: "prepare for Sunday")
        XCTAssertNil(item.dueDate)
    }

    // MARK: - 边界

    /// dueDate 已经是 nil → 无需过滤(短路返回)。
    func testNilDueDateSkipsFilter() {
        let extracted = ExtractedTodo(
            title: "买菜",
            detail: "",
            dueDate: nil,
            dueDateBasis: nil
        )
        let item = TodoItem.from(extracted, rawTranscript: "买菜")
        XCTAssertNil(item.dueDate)
    }

    // MARK: - ExtractionOutcome stamping

    /// TodoItem.from 工厂显式标 `.parsed`:AI 正常提取出的条目不进「没能识别」组。
    /// 与 `TodoItem.rawTranscript(_:)` 的 `.rawFallback` 形成对照。
    func testFromExtractedStampsParsedOutcome() {
        let extracted = ExtractedTodo(title: "交房租", detail: "明天交房租", dueHint: "明天")
        let item = TodoItem.from(extracted, rawTranscript: "明天交房租")
        XCTAssertEqual(item.extractionOutcome, .parsed)
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
