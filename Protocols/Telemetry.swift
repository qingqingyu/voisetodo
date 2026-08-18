import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 遥测事件入口。本地 OSLog 始终记录，远端批量上报走 `TelemetryUploader`。
///
/// 仅记录脱敏数据，不含 PII。文本参数必须用 `VoiceTodoLog.textSummary(_)` 包裹，
/// 不直接传原文。详见 `TELEMETRY.md`。
enum Telemetry {
    /// 当前会话 ID。App 启动时新建，不持久化。
    static let sessionID: String = UUID().uuidString

    /// 设备 ID，复用 AIProxy 已有的匿名标识（sha256 hash）。
    static let deviceID: String = NetworkConfig.proxyDeviceIdentifier

    /// App 版本（CFBundleShortVersionString）。
    static let appVersion: String = Bundle.main.shortVersion

    /// iOS 系统版本（如 "17.4"）。非 iOS 平台回退 "unknown"。
    static var iOSVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return "unknown"
        #endif
    }

    /// 入队一个事件。仅写入本地队列，远端上报由 `TelemetryUploader` 在 WiFi + 充电时触发。
    static func record(_ event: TelemetryEvent, now: Date = Date()) {
        let payload = TelemetryPayload(
            name: event.name,
            timestamp: now,
            sessionID: sessionID,
            deviceID: deviceID,
            appVersion: appVersion,
            iosVersion: iOSVersion,
            params: event.params,
            // 提取链路内的事件带 extractID，与服务端 X-Extract-ID / 客户端日志可精确关联
            extractID: VoiceTodoLog.extractID ?? "none"
        )
        TelemetryQueue.enqueue(payload, now: now)
        VoiceTodoLog.app.debug("telemetry.enqueue name=\(event.name, privacy: .public) queueSize=\(TelemetryQueue.count())")
    }

    /// 提取错误的稳定 reason 字符串（用 case 名，去掉关联值）。
    /// 例：`VoiceTodoError.microphonePermissionDenied` → "microphonePermissionDenied"
    /// 例：`URLError(_NSURLErrorDomain: ...) → "URLError"
    /// 用于遥测参数，避免暴露具体错误内容（可能含 PII）。
    static func reason(for error: Error) -> String {
        let desc = String(describing: error)
        return desc.split(separator: "(").first.map(String.init) ?? desc
    }
}

/// 遥测事件清单。所有 case 必须给出 `name` 和脱敏后的 `params`。
enum TelemetryEvent {
    /// A1: App 启动
    case appLaunch(coldLaunch: Bool, hasCompletedOnboarding: Bool)
    /// A2: 录音开始
    case recordingStarted(source: RecordingSource)
    /// A3: 录音结果（含成功/中断/超时/失败）
    case recordingOutcome(outcome: RecordingOutcome, durationMS: Int, transcript: String)
    /// A4: AI 抽取结果
    case extractOutcome(outcome: ExtractOutcome, todosCount: Int, durationMS: Int, attempts: Int)
    /// A5: Todo 保存（用户确认或 Siri/Widget）
    case todoSaved(source: SaveSource, count: Int)

    /// B1: 录音失败（权限/中断/识别错）
    case recordingFailed(reason: String, errorCode: Int?)
    /// B2: AI 抽取失败（终态）
    case extractFailed(reason: String, attempt: Int)
    /// B3: Widget 读取失败
    case widgetLoadFailed(reason: String)
    /// B4: AppIntent 失败
    case intentFailed(operation: String, stage: String)
    /// B5: 客户端熔断器状态迁移（opened / closed / reset）。
    /// 「远端 AI 静默失效」的直接观测点：opened 说明后续请求会被短路成本地降级，
    /// closed 说明恢复。没有这条事件时，熔断打开与恢复在遥测里完全不可见。
    case extractorCircuitChanged(state: String, reason: String)

    /// A6: 首次语音试用引导进度。onboarding→激活的转化漏斗，
    /// 也是 PROMOTION_PLAN.md 漏斗里 wow_shown 的数据来源。
    /// stage 取值见 FirstVoiceTrialStage；口径限制见 TELEMETRY.md。
    case firstVoiceTrial(stage: String)
    /// A7: paywall 曝光。四来源可区分（first_wow / recording_count /
    /// quota_exhausted / manual），是「wow 后立即弹 vs 撞墙后弹」
    /// （PROMOTION_PLAN.md :33 偏差决策）的度量基础——没有来源维度，
    /// A/B 弹点效果永远测不出来。
    case paywallShown(source: PaywallSource)

    /// 事件名，对应 D1 `event_name` 列。
    var name: String {
        switch self {
        case .appLaunch: return "app_launch"
        case .recordingStarted: return "recording_started"
        case .recordingOutcome: return "recording_outcome"
        case .extractOutcome: return "extract_outcome"
        case .todoSaved: return "todo_saved"
        case .recordingFailed: return "recording_failed"
        case .extractFailed: return "extract_failed"
        case .widgetLoadFailed: return "widget_load_failed"
        case .intentFailed: return "intent_failed"
        case .extractorCircuitChanged: return "extractor_circuit_changed"
        case .firstVoiceTrial: return "first_voice_trial"
        case .paywallShown: return "paywall_shown"
        }
    }

    /// 事件参数。**所有文本必须脱敏**，不允许出现 transcript/title/detail 原文。
    var params: [String: String] {
        switch self {
        case let .appLaunch(coldLaunch, hasCompletedOnboarding):
            return [
                "coldLaunch": String(coldLaunch),
                "hasCompletedOnboarding": String(hasCompletedOnboarding)
            ]
        case let .recordingStarted(source):
            return ["source": source.rawValue]
        case let .recordingOutcome(outcome, durationMS, transcript):
            // transcript 必须脱敏：只记录字符数和行数
            return [
                "outcome": outcome.rawValue,
                "durationMS": String(durationMS),
                "transcript": VoiceTodoLog.textSummary(transcript)
            ]
        case let .extractOutcome(outcome, todosCount, durationMS, attempts):
            return [
                "outcome": outcome.rawValue,
                "todosCount": String(todosCount),
                "durationMS": String(durationMS),
                "attempts": String(attempts)
            ]
        case let .todoSaved(source, count):
            return [
                "source": source.rawValue,
                "count": String(count)
            ]
        case let .recordingFailed(reason, errorCode):
            var p = ["reason": reason]
            if let errorCode { p["errorCode"] = String(errorCode) }
            return p
        case let .extractFailed(reason, attempt):
            return [
                "reason": reason,
                "attempt": String(attempt)
            ]
        case let .widgetLoadFailed(reason):
            return ["reason": reason]
        case let .intentFailed(operation, stage):
            return [
                "operation": operation,
                "stage": stage
            ]
        case let .extractorCircuitChanged(state, reason):
            return [
                "state": state,
                "reason": reason
            ]
        case let .firstVoiceTrial(stage):
            return ["stage": stage]
        case let .paywallShown(source):
            return ["source": source.rawValue]
        }
    }
}

/// 录音启动来源。
enum RecordingSource: String {
    case button = "button"
    case actionButton = "action_button"
    case manualInput = "manual_input"
}

/// 录音结果状态。
enum RecordingOutcome: String {
    case success = "success"
    case interrupted = "interrupted"
    case userCancelled = "user_cancelled"
    case silenceTimeout = "silence_timeout"
    case maxDurationReached = "max_duration_reached"
    case watchdogExpired = "watchdog_expired"
    case error = "error"
}

/// AI 抽取结果状态。
enum ExtractOutcome: String {
    case success = "success"
    case failed = "failed"
    case offlineFallback = "offline_fallback"
    case streamPartial = "stream_partial"
    /// 用户主动取消（关弹层 / 开始新录音）。**必须与 failed 分开统计**：
    /// 取消不是故障，混进分母会让「静默降级率」这个指标失真。
    case cancelled = "cancelled"
}

/// Todo 保存来源。
enum SaveSource: String {
    case confirm = "confirm"
    case siriAdd = "siri_add"
    case widgetToggle = "widget_toggle"
}

/// Paywall 曝光来源。四个自动/手动入口各记一枚，收口在
/// `AppCoordinator.presentPaywall(source:)`——新增入口时不许直接写
/// `showPaywall = true`，必须走该方法，否则来源维度漏记。
enum PaywallSource: String {
    /// 首次 wow（引导下第一条待办落库）之后——本方案的 day-1 曝光点。
    case firstWow = "first_wow"
    /// 累计 5 次录音成功阈值（`handleRecordingSuccess`）。
    case recordingCount = "recording_count"
    /// 配额耗尽（含离线兜底后的补弹）。
    case quotaExhausted = "quota_exhausted"
    /// 设置页「升级 Pro」手动入口。
    case manual = "manual"
}

/// `firstVoiceTrial` 事件的 stage 取值。集中成常量避免调用方手拼字符串漂移。
enum FirstVoiceTrialStage {
    /// onboarding 完成时 arm。权限未齐直接落 `.dismissed` 的路径也记 armed——
    /// 漏斗分母 = 全部完成 onboarding 的用户;该子集的特征是永不出现 hint_shown。
    static let armed = "armed"
    /// hint 首次展示（会话级去重后；同一会话重复展示不重复记）。
    static let hintShown = "hint_shown"
    /// 用户点「知道了」主动关闭。
    static let dismissed = "dismissed"
    /// 首次语音待办已落库（wow 发生）。
    static let completed = "completed"
}

// MARK: - Bundle 辅助

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }
}
