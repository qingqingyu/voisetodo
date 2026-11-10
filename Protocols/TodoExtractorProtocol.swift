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

    /// 连接预热：开始录音时提前与代理建连（TLS 握手），解析请求省掉冷连接往返。
    /// 尽力而为——失败只记日志不抛（预热失败不代表解析会失败）。
    func warmUpConnection() async
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

    /// 默认连接预热：空实现——mock / UI 测试实现无需感知网络预热。
    func warmUpConnection() async {}
}
