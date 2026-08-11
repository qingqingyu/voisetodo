import Foundation
import UIKit

/// 反馈类型,与 feedback-relay worker.js 的 VALID_TYPES 对齐。
/// rawValue 即 Worker 端接收的 type 字段值,改动任一边都要同步。
enum FeedbackType: String, CaseIterable, Sendable, Hashable {
    case translation
    case aiOutput = "ai_output"
    case bug
    case suggestion

    var displayText: String {
        switch self {
        case .translation:  return String(localized: "feedback.type.translation")
        case .aiOutput:     return String(localized: "feedback.type.ai_output")
        case .bug:          return String(localized: "feedback.type.bug")
        case .suggestion:   return String(localized: "feedback.type.suggestion")
        }
    }
}

/// 一次反馈的完整 payload。截图用 JPEG Data(已在客户端压过)。
struct FeedbackPayload: Sendable {
    let type: FeedbackType
    let description: String
    let screenshot: Data?
    let screenshotMime: String
    /// 仅 ConfirmSheet 入口预填:用户原话(帮助理解上下文)。
    let transcript: String?
    /// 仅 ConfirmSheet 入口预填:撞到烂 AI 输出的那条待办。
    let extractedTodoTitle: String?
}

/// 反馈提交器。简单 POST 到 feedback-relay Worker,带 X-App-Token。
///
/// 不复用 `NetworkClient` —— 后者为 AIProxy SSE 流式 + 熔断 + 重试设计,
/// 反馈是简单一次性 POST,套上去反而要绕开 retry/circuit/budget 逻辑。
/// 客户端身份校验靠 `X-App-Token`,沿用 NetworkConfig.proxyAppToken(同一个 App)。
struct FeedbackSubmitter {
    let endpoint: String
    let appToken: String?
    /// 独立 session:带 `FeedbackConfig.requestTimeout` 超时,不复用 URLSession.shared
    /// (shared 的 60s 默认超时对带 3MB 截图的反馈太长,用户会卡 ProgressView)。
    private let session: URLSession

    init(endpoint: String = FeedbackConfig.endpoint, appToken: String? = FeedbackConfig.appToken) {
        self.endpoint = endpoint
        self.appToken = appToken
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = FeedbackConfig.requestTimeout
        config.timeoutIntervalForResource = FeedbackConfig.requestTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// 提交反馈。成功返回 void;失败 throw VoiceTodoError.feedbackSubmitFailed。
    ///
    /// 成功语义:Worker 返 2xx **且**反馈已落 D1 归档(`archived == true`)。
    /// 如果 Worker 同时 D1 写失败 + Telegram 推失败(返 200 但 `archived == false` +
    /// `warning == "delivery_delayed"`),这是全丢路径,客户端视为失败让用户可重试。
    /// 单独 Telegram 推失败但 D1 成功(`archived == true`)仍视为成功 —— D1 是持久记录。
    func submit(_ payload: FeedbackPayload) async throws {
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            // endpoint 未配:不阻断用户,但不应该发生(构建配置漏)
            throw VoiceTodoError.feedbackSubmitFailed("feedback endpoint not configured")
        }
        // appToken 缺失:比 endpoint 缺失更不该发生(同一个 build config 漏),
        // 但显式报错优于"发出去 → 401 → 用户看到通用失败"这一跳。
        guard let appToken else {
            throw VoiceTodoError.feedbackSubmitFailed("feedback app token not configured")
        }

        if let data = payload.screenshot, data.count > FeedbackConfig.maxScreenshotBytes {
            throw VoiceTodoError.feedbackSubmitFailed("screenshot too large")
        }

        var request = URLRequest(url: url.appendingPathComponent("v1/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appToken, forHTTPHeaderField: "X-App-Token")

        let bodyObject: [String: Any] = makeBody(payload)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject)
        } catch {
            // 附 body 顶层 keys 帮助排查是哪个字段触发的序列化失败
            throw VoiceTodoError.feedbackSubmitFailed(
                "json serialization failed: \(error.localizedDescription), keys=\(bodyObject.keys.sorted())"
            )
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VoiceTodoError.feedbackSubmitFailed("non-http response")
            }
            data = responseData
            http = httpResponse
        } catch let error as VoiceTodoError {
            throw error
        } catch {
            // URLError(网络断/超时/DNS)—— 归一化到 feedbackSubmitFailed
            throw VoiceTodoError.feedbackSubmitFailed(error.localizedDescription)
        }

        guard (200...299).contains(http.statusCode) else {
            throw VoiceTodoError.feedbackSubmitFailed("status \(http.statusCode)")
        }

        // 检查 Worker 是否走到"全丢"分支(D1 失败 + Telegram 失败)。
        // 单独 Telegram 失败但 D1 成功,Worker 返 { ok:false, archived:true, warning:"delivery_delayed" },
        // 客户端视为成功(D1 是持久记录,Worker 端会补推)。
        if !isDurablyArchived(data) {
            throw VoiceTodoError.feedbackSubmitFailed("worker did not archive (d1 and telegram both failed)")
        }
    }

    /// 判 Worker 返回是否反馈已进持久归档(D1)。
    /// Worker happy path 返 `{ ok: true, archiveId: <number> }`;
    /// 单独 Telegram 失败返 `{ ok: false, archived: true, warning: "delivery_delayed" }`;
    /// 全丢返 `{ ok: false, archived: false, warning: "delivery_delayed" }`。
    /// 旧版/异常 Worker 可能返无 body 的 200 —— 保守视为未归档,让用户重试。
    private func isDurablyArchived(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // archiveId 存在(数字或非 null)→ D1 写成功
        if json["archiveId"] != nil {
            return true
        }
        // 否则看 archived 字段(单独 Telegram 失败时 Worker 返 archived:true)
        if let archived = json["archived"] as? Bool {
            return archived
        }
        return false
    }

    private func makeBody(_ payload: FeedbackPayload) -> [String: Any] {
        var body: [String: Any] = [
            "type": payload.type.rawValue,
            "description": payload.description,
            "locale": Locale.current.identifier,
            "appVersion": appVersion(),
            "osVersion": osVersion(),
            "deviceModel": deviceModel()
        ]
        if let transcript = payload.transcript, !transcript.isEmpty {
            // 截断到 worker 端 MAX_TRANSCRIPT_CHARS,避免 base64 后 body 超限
            body["transcript"] = String(transcript.prefix(FeedbackConfig.maxTranscriptChars))
        }
        if let title = payload.extractedTodoTitle, !title.isEmpty {
            body["extractedTodoTitle"] = String(title.prefix(FeedbackConfig.maxTitleChars))
        }
        if let screenshot = payload.screenshot {
            body["screenshotBase64"] = screenshot.base64EncodedString()
            body["screenshotMime"] = payload.screenshotMime
        }
        return body
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func deviceModel() -> String {
        // UIDevice.current.model 只给 "iPhone"/"iPad",不够具体,
        // 但更细的 identifier（"iPhone15,3"）需要 uname/sysctl,且 iOS 16+ Apple
        // 已把 machine 字符串脱敏。客户端上报 "iPhone" + iOS 版本对定位反馈已足够。
        UIDevice.current.model
    }
}
