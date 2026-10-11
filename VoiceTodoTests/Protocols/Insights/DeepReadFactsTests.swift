import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// v5 T5 批 1:深读事实层(AF1)与 E5 接地校验(D4)纯函数验收。
final class DeepReadFactsTests: XCTestCase {
    // MARK: - GroundingValidator(E5)

    /// E5 正路:每个 numbers 条目同 id 同值 → 接地通过。
    func testGrounded_whenAllNumbersMatchExactly() {
        let facts = ["backlog_now": "5", "completed_count": "12", "backlog_delta": "-3"]
        let numbers = ["backlog_now": "5", "completed_count": "12"]
        XCTAssertTrue(GroundingValidator.isGrounded(numbers: numbers, facts: facts))
    }

    /// D4 核心:值对不上(哪怕差 1)→ 整卡不显示——深读不得引入任何
    /// 与事实层矛盾的数字,一票否决。
    func testNotGrounded_whenAnyValueDiffers() {
        let facts = ["backlog_now": "5"]
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: ["backlog_now": "6"], facts: facts))
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: ["backlog_now": "5.0"], facts: facts))
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: ["backlog_now": " 5"], facts: facts),
                       "精确比对:空格也判不等")
    }

    /// id 不存在于本地事实(模型编造了 id)→ 不接地。
    func testNotGrounded_whenFabricatedID() {
        let facts = ["backlog_now": "5"]
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: ["hallucinated": "1"], facts: facts))
        // 混合:一个真一个假 → 任一不满足即失败
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: ["backlog_now": "5", "fake": "0"], facts: facts))
    }

    /// numbers 为空(模型没有回引任何事实 = 输出没有接地)→ 不接地——
    /// 深读的观察必须至少引用一条已核实事实。
    func testNotGrounded_whenNumbersEmpty() {
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: [:], facts: ["backlog_now": "5"]))
        XCTAssertFalse(GroundingValidator.isGrounded(numbers: [:], facts: [:]))
    }

    // MARK: - DeepReadFactsPayload

    func testByIDDedupesKeepingFirst() {
        let payload = DeepReadFactsPayload(facts: [
            DeepReadFact(id: "a", value: "1"),
            DeepReadFact(id: "a", value: "2"),
            DeepReadFact(id: "b", value: "3"),
        ])
        XCTAssertEqual(payload.byID, ["a": "1", "b": "3"])
    }

    func testCodableRoundTrip() throws {
        let payload = DeepReadFactsPayload(facts: [DeepReadFact(id: "trend_0", value: "7")])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DeepReadFactsPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }
}
