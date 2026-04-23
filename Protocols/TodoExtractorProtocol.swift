import Foundation

/// 待办提取协议
protocol TodoExtractorProtocol {
    /// 从转写文本中提取待办
    /// - Parameters:
    ///   - transcript: 用户语音转写文本
    ///   - locale: 语音识别使用的语言环境，用于选择匹配的 AI prompt
    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult
}
