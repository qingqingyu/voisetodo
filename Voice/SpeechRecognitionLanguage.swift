import Foundation

/// 用户可选择的语音识别语言（用于 HomeSettingsSheet 的 Picker）。
///
/// 设计：`auto` 跟随系统首选语言（`Locale.preferredLanguages.first`），
/// 其他两个固定 locale。这让用户在「系统是英文但常用中文说」的场景下
/// 能强制指定识别器语言，而不需要改整个系统语言。
///
/// **不在 `VoiceInputManager.init` 时一次性决定**——而是在每次 `startRecording`
/// 时解析一次，让用户改了设置之后下次录音立即生效（不用重启 App）。
enum SpeechRecognitionLanguage: String, CaseIterable, Identifiable {
    /// 跟随系统首选语言（默认值，向后兼容旧行为）
    case auto = "auto"
    /// 简体中文（对中英混说容忍度高，双语用户首选）
    case zhHans = "zh-Hans"
    /// English
    case enUS = "en-US"

    var id: String { rawValue }

    /// Picker 显示文案（走本地化）。
    var displayName: String {
        switch self {
        case .auto:   return String(localized: "settings.speech_language.auto")
        case .zhHans: return String(localized: "settings.speech_language.zh-Hans")
        case .enUS:   return String(localized: "settings.speech_language.en-US")
        }
    }

    /// 用户显式指定的 Locale。`auto` 返回 nil，由调用方回退到系统首选。
    var fixedLocale: Locale? {
        switch self {
        case .auto:   return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .enUS:   return Locale(identifier: "en-US")
        }
    }

    /// 持久化到 UserDefaults 的 key。
    static let storageKey = "speechRecognitionLanguage"
}
