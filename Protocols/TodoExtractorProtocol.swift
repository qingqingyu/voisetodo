import Foundation

/// 待办提取协议
protocol TodoExtractorProtocol {
    /// 从转写文本中提取待办
    /// - Parameters:
    ///   - transcript: 用户语音转写文本
    ///   - locale: 语音识别使用的语言环境，用于选择匹配的 AI prompt
    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult

    /// 流式提取待办，每次 yield 累积的 ExtractionResult
    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error>

    /// 离线降级提取
    func fallbackExtract(from transcript: String) -> ExtractionResult
}

extension TodoExtractorProtocol {
    /// 默认流式实现：退化为单次 extract 调用后 yield 一次
    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await extract(from: transcript, locale: locale)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 默认离线降级：截取标题
    func fallbackExtract(from transcript: String) -> ExtractionResult {
        let title = TextUtils.truncateTitle(from: transcript)
        let todo = ExtractedTodo(
            id: UUID(),
            title: title,
            detail: transcript,
            dueHint: nil,
            priority: .normal,
            categoryHint: .other
        )
        return ExtractionResult(todos: [todo], ignored: "")
    }
}
