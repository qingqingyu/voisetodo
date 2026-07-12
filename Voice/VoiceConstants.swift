import Foundation
import AVFoundation

/// 语音模块可配置常量 [v2 新增]
enum VoiceConstants {
    /// 静音检测阈值 (dB)，连续 silenceTimeout 秒低于此值则自动提交。
    /// 仅在已有转写内容时触发——用户没说话不自动提交（避免空 transcript 送 AI）。
    static let silenceThresholdDB: Float = -40.0

    /// 说话后静音自动提交的超时时间（秒）。
    /// 用户说完话后等 1.5s 静音即自动提交，Send 按钮变为可选快捷路径。
    static let silenceTimeoutSeconds: TimeInterval = 1.5

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
