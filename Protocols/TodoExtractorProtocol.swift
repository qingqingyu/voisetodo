import Foundation

/// 待办提取协议
protocol TodoExtractorProtocol {
    /// 从转写文本中提取待办
    func extract(from transcript: String) async throws -> ExtractionResult

    /// 离线降级：直接截取前 20 字作为标题
    func fallbackExtract(from transcript: String) -> ExtractionResult
}
