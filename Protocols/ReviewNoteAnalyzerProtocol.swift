import Foundation

/// 笔记语义对照协议(2026-08-23 拍板,复盘差异化)。
///
/// 复盘收尾存笔记时做**一次** AI 调用(代理 `mode=reflect`,不计费、不缓存),
/// 提取「关注点」并映射到分类/时段;客户端算好当期计数后连同关注点存进
/// `ReviewSession`。下次复盘**纯本地**拼「本期 N 件(上期 M 件)」对照——
/// 展示零 AI、离线退化为纯文本笔记。
protocol ReviewNoteAnalyzerProtocol {
    /// - Parameters:
    ///   - note: 第 3 步「问问自己」的回答原文
    ///   - locale: 笔记语言(选择 prompt)
    /// - Returns: 提取出的关注点(≤3 条,两个映射维度都为空的已被服务端 prompt
    ///     过滤)。空数组 = 没提取出可统计的东西,调用方按无 topics 处理。
    func analyzeNoteTopics(note: String, locale: Locale) async throws -> [ReviewTopicDraft]
}

/// 深读观察协议(v5 T5 批 3):把本期已核实事实发给代理 deep-read 模式,
/// 返回经 E5 接地校验的观察(任何失败返回 nil,D4:整卡不显示)。
/// 与 `ReviewNoteAnalyzerProtocol` 分开——深读的输入是结构化事实而非用户
/// 笔记,失败语义也不同(增强降级 vs 抛错)。
protocol DeepReadObservationProtocol {
    func deepReadObservation(facts: DeepReadFactsPayload, locale: Locale) async -> DeepReadObservationData?
}

/// 深读产出(E5 校验通过后的可显示形态)。
struct DeepReadObservationData: Sendable, Equatable {
    /// 2-3 句接地观察(只含已核实事实的数字)。
    let observation: String
    /// 笔记草稿引导(第 5 步预填,prompt 约束 ≤20 字,客户端按
    /// `DeepReadConfig.draftMaxLength` 硬顶;空串=无草稿)。
    let draft: String
}

/// 深读配置常量(v5 T5)。
enum DeepReadConfig {
    /// AI 草稿入笔记的长度上限(E11:「AI 草稿入 voiceNote 设长度上限,
    /// 与手打输入同尺」——手打路径无硬限,此值是防模型违约超长输出的
    /// 客户端硬顶,宽松于 prompt 的 ≤20 字,覆盖三语最长的日文约束)。
    static let draftMaxLength = 60

    /// 超长草稿的合法截断点(v6 §3.1):句末标点 / 空白 / 中日文标点。
    /// 英文提示词允许 ≤15 词,常超 60 字符,`prefix` 硬截会出「the weig」
    /// 这类半截词——截断必须落在词/句边界上。
    private static let draftBreakCharacters: Set<Character> = [
        // 句末标点
        "。", ".", "!", "！", "?", "？", "…",
        // 中日文标点(逗号、顿号、分号、冒号、右括号引号)
        "，", ",", "、", "；", ";", "：", ":",
        "）", ")", "」", "』", "》", "】",
        // 空白(半角/全角空格、换行)
        " ", "　", "\n", "\t",
    ]

    /// 草稿长度硬顶(v6 §3.1):未超长原样返回;超长时在**上限内**最后一个
    /// 断点字符(含该字符)截断并去尾部空白;上限内找不到断点 → 空串
    /// (丢弃整条,不显示半截词)。不改提示词、不改上限数值(E11 与手打同尺)。
    static func clampedDraft(_ draft: String) -> String {
        guard draft.count > draftMaxLength else { return draft }
        let head = draft.prefix(draftMaxLength)
        guard let breakIndex = head.lastIndex(where: { draftBreakCharacters.contains($0) }) else {
            return ""
        }
        let truncated = head[...breakIndex]
        return trimmedTrailingWhitespace(truncated)
    }

    /// 去尾部空白(断点是空格/换行时,截完后尾巴上不该再挂着空白)。
    private static func trimmedTrailingWhitespace(_ text: Substring) -> String {
        var result = text
        while let last = result.last, last.isWhitespace {
            result = result.dropLast()
        }
        return String(result)
    }
}

/// AI 提取的一条关注点草稿:text 保留用户原话关键短语;category/timeBucket 是
/// AI 的语义映射(nil = 该话题没有可统计维度)。
struct ReviewTopicDraft: Sendable, Equatable {
    let text: String
    let category: TodoCategory?
    let timeBucket: TimeBucket?
}

/// 关注点 ↔ 本期完成事件的计数匹配(纯函数)。收尾存 `periodCount`(上期数)
/// 与下次展示算本期数**共用同一口径**,保证「上期 M / 本期 N」可比。
enum ReviewTopicMatching {
    /// 该关注点在完成事件里的计数:有分类按分类匹配;只有时段按时段
    /// (完成钟点落在时段内,钟点→时段边界与 `TimeBucketResolver` 同款:
    /// 5–11 morning / 12–17 afternoon / 其余 evening);两个维度都没有 → nil
    /// (不可统计,不显示对照)。
    static func periodCount(
        category: TodoCategory?,
        timeBucket: TimeBucket?,
        in events: [InsightCompletedEvent],
        calendar: Calendar
    ) -> Int? {
        if let category {
            return events.filter { $0.category == category }.count
        }
        // 防御纵深:.anytime 无钟点统计意义(解析侧已过滤),视同不可统计。
        if let timeBucket, timeBucket != .anytime {
            return events.filter { event in
                Self.bucket(ofHour: calendar.component(.hour, from: event.completedAt)) == timeBucket
            }.count
        }
        return nil
    }

    /// 小时 → 时段。与 `TimeBucketResolver` 的钟点边界保持一致
    /// (该文件注释:5:00–11:59 morning / 12:00–17:59 afternoon / 其余 evening)。
    static func bucket(ofHour hour: Int) -> TimeBucket {
        switch hour {
        case 5...11: return .morning
        case 12...17: return .afternoon
        default: return .evening
        }
    }
}
