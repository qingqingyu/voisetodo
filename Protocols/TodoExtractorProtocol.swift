import Foundation

/// 待办提取协议
protocol TodoExtractorProtocol {
    /// 从转写文本中提取待办
    func extract(from transcript: String) async throws -> ExtractionResult
}
