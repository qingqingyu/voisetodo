import Foundation

/// 统一的 JSON 编解码配置入口。
///
/// 集中管理 key / date 策略，避免各调用点各自 `JSONDecoder()`/`JSONEncoder()` 产生
/// 不一致或意外的 key 映射。
///
/// 注意：请求与响应是**不同的契约**，因此编/解码策略是「有意不对称」的——
/// - 服务端响应使用 snake_case（如 `due_hint` / `category_hint`），解码时统一转 camelCase；
/// - 发往服务端的请求体约定为 camelCase（如 `vocabularyHints`），编码保持默认 key 不转换。
/// 不要给请求编码器加 `.convertToSnakeCase`，否则会改变线上请求格式、破坏与代理的契约。
enum JSONCoding {
    /// 解码服务端响应：snake_case → camelCase。
    static func makeResponseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// 编码发往服务端的请求 / 遥测上报：保持 camelCase key，日期统一为 epoch 毫秒。
    static func makeRequestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
