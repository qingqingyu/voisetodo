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

    /// 音量采样缓冲区大小
    static let audioBufferSize: AVAudioFrameCount = 1024

    /// 支持的语言
    static let supportedLocales: [Locale] = [
        Locale(identifier: "zh-Hans"),
        Locale(identifier: "en-US")
    ]
}
