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
    /// 顺序也决定 Picker 显示顺序:auto → 中文 → 日本語 → English
    static let supportedLocales: [Locale] = [
        Locale(identifier: "zh-Hans"),
        Locale(identifier: "ja-JP"),
        Locale(identifier: "en-US")
    ]

    /// 中文 STT baseline 时间词("X点半"模式)。
    ///
    /// **Why**: 用户反馈"设置十点半的任务"被识别成"随时"。两种可能根因:
    ///   - AI prompt 缺"X点半" few-shot(已在 AIProxy base.js 示例 16/17 补上)
    ///   - STT 把"十点半"识别成别的字(如"是点半"),prompt 怎么改都没用
    ///
    /// 这里是 STT 层的兜底:把"X点半"模式词塞进 contextualStrings,
    /// 让 SFSpeechRecognizer 优先匹配这些字面量。仅中文 locale 注入。
    ///
    /// **How to apply**: 由 VoiceInputManager.makeRecognitionRequest 在
    /// 用户词汇前 prepend,合并去重后取前 N 项(N = UserVocabularyConfig.speechContextualStringsLimit)。
    /// baseline 占 12 个名额,剩 88 个给用户高频词——影响可接受(用户词汇是辅助识别)。
    static let chineseTimeExpressionHints: [String] = [
        "一点半", "两点半", "三点半", "四点半", "五点半", "六点半",
        "七点半", "八点半", "九点半", "十点半", "十一点半", "十二点半"
    ]
}
