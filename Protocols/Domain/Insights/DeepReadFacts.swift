import Foundation

// MARK: - 深读事实层(v5 T5 / AF1+E5,docs/todo-review-flow-v5.md)

/// 深读的接地事实(v5 AF1):**纯 id+字符串值**,零本地化文案——深读提示词
/// 与 E5 接地校验都以它为单一来源。值一律字符串(数字的十进制表示/枚举
/// rawValue),比对是**逐 id 精确相等**(E5:不做自由文本数字抽取,不做
/// 容差)——深读输出里引用的每个数字必须能在下表找到同 id 同值。
struct DeepReadFact: Codable, Sendable, Equatable {
    let id: String
    let value: String
}

/// 客户端侧已核实的事实集合。构造口在 `ReviewFlowState.refreshDeepReadFacts()`
/// (深读拉取前收集,时点见其注释);发给代理的 prompt 与本地校验器共用
/// 同一份——代理被要求在输出里原样回引它用到的 `id: value`(`numbers` 块),
/// `GroundingValidator` 逐条对回。
struct DeepReadFactsPayload: Codable, Sendable, Equatable {
    let facts: [DeepReadFact]

    var byID: [String: String] {
        Dictionary(facts.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - E5 接地校验(D4:对不上→整卡不显示)

/// 深读输出的接地校验(v5 E5):模型被要求输出 `numbers` 块(它引用的
/// id→值),客户端逐 id 与本地事实**精确比对**。任一 id 不存在或值不等、
/// 或 `numbers` 为空(模型没有回引任何事实 = 输出没有接地) → 判失败,
/// 深读卡整卡不显示(D4:绝不空话兜底)。
enum GroundingValidator {
    /// - Returns: true = 每个 numbers 条目都能在 facts 里找到同 id 同值,
    ///   且至少回引了一条。false = 整卡不显示。
    static func isGrounded(numbers: [String: String], facts: [String: String]) -> Bool {
        guard !numbers.isEmpty else { return false }
        return numbers.allSatisfy { id, value in
            facts[id] == value
        }
    }
}
