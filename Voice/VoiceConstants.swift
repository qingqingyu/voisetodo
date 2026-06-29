import Foundation
import AVFoundation

/// 语音模块可配置常量 [v2 新增]
enum VoiceConstants {
    /// 静音检测阈值 (dB)，连续 silenceTimeout 秒低于此值则自动停止
    /// 合理范围：-35 到 -45 dB
    /// 太敏感会截断用户话语，太迟钝会让用户等待太久
    static let silenceThresholdDB: Float = -40.0

    /// 静音超时时间（秒）
    static let silenceTimeoutSeconds: TimeInterval = 2.0

    /// 硬性最大录音时长（秒）。到达即自动停止——防口袋误触/忘关导致超长转写，
    /// 也是成本整形（正常"说今天安排"远不到 90s）。注意：这是 UX/成本整形，
    /// 不是反滥用手段（绕过客户端直接打代理的攻击者不受此限制，防御在代理侧）。
    static let maxRecordingSeconds: TimeInterval = 90.0

    /// 停止输入后等待最终语音识别回调的最长时间
    static let finishRecordingWatchdogTimeoutSeconds: TimeInterval = 5.0

    /// 音量采样缓冲区大小
    static let audioBufferSize: AVAudioFrameCount = 1024

    /// 支持的语言
    static let supportedLocales: [Locale] = [
        Locale(identifier: "zh-Hans"),
        Locale(identifier: "en-US")
    ]
}
