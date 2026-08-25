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
