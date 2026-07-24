import Foundation

/// AI 提取结果的来源标签,用于区分「真正解析过」和「原文兜底」两类 todo。
///
/// 这是「没能识别」分组的数据基础——`HomeCalendarState` 用它把
/// `.rawFallback / .unparsed` 的条目从「未安排」里捞出来,单独进「没能识别」组,
/// 让原文片段不再伪装成普通任务混在 Today 列表里(参见 `TodoItem.rawTranscript(_:)`
/// 与 `TodoExtractorService.fallbackExtract(_:)` 两条原文兜底路径)。
///
/// - Note: 仅作分组与 UI 展示用,不参与提取流程的判定。
///         写入新条目时由工厂方法显式 stamp(见 `TodoItem.from(_:rawTranscript:)` 标
///         `.parsed`,`TodoItem.rawTranscript(_:)` 标 `.rawFallback`)。
enum ExtractionOutcome: String, Codable, CaseIterable, Sendable {
    /// AI 正常提取出至少一个结构化字段(date / time / timeBucket / recurrence / 非 `.other` category)。
    case parsed

    /// 网络失败等本地兜底,原文未经 AI。`rawTranscript` 字段是这种条目的真实内容。
    case rawFallback

    /// AI 看过但解析不出结构(本期暂不主动产出,预留给 AIProxy 后续打"低置信"标记)。
    case unparsed
}
