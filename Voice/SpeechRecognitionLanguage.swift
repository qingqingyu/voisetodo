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
    /// 日本語
    case jaJP = "ja-JP"
    /// English
    case enUS = "en-US"

    var id: String { rawValue }

    /// Picker 显示文案（走本地化）。
    var displayName: String {
        switch self {
        case .auto:   return String(localized: "settings.speech_language.auto")
        case .zhHans: return String(localized: "settings.speech_language.zh-Hans")
        case .jaJP:   return String(localized: "settings.speech_language.ja-JP")
        case .enUS:   return String(localized: "settings.speech_language.en-US")
        }
    }

    /// 用户显式指定的 Locale。`auto` 返回 nil，由调用方回退到系统首选。
    var fixedLocale: Locale? {
        switch self {
        case .auto:   return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .jaJP:   return Locale(identifier: "ja-JP")
        case .enUS:   return Locale(identifier: "en-US")
        }
    }

    /// 持久化到 UserDefaults 的 key。
    static let storageKey = "speechRecognitionLanguage"

    /// `.auto` 当前会解析到的具体语言。onboarding 用它把「跟随系统」展开成
    /// 「跟随系统 · 中文」,让用户第一眼就知道 auto 意味着什么。
    ///
    /// 匹配规则与原 `VoiceInputManager.resolveSystemLocale()` 完全一致
    /// (后者已改为调用此处):按 `Locale.preferredLanguages.first` 的 languageCode
    /// 前缀依次匹配非 auto 的各 case,未命中回退 `.enUS`(非中日英系统走英文,国际通用)。
    ///
    /// 返回值永不为 `.auto`。
    ///
    /// 三个 languageCode 前缀 `"zh"` / `"ja"` / `"en"` 两两互不包含,任一
    /// `preferredLanguages.first` 最多命中其一,遍历顺序不影响结果。
    /// `allCases` 的顺序只决定 Picker 的显示顺序,可以自由调整。
    ///
    /// 繁中 / 粤语的已知限制(原逻辑既有,本次不修):`"zh-Hant-TW"` 和 `"zh-HK"`
    /// 都 `hasPrefix("zh")`,会落到 `.zhHans`。繁中普通话用户影响有限(识别引擎
    /// 都是普通话,只是输出简体字形),粤语用户会被塞进普通话识别器。MVP 不支持
    /// 繁中/粤语,接受现状。后续若要支持,匹配规则需细化到 `languageCode + script`
    /// (区分 `zh-Hans` / `zh-Hant`),而不是只比 `zh` 前缀。
    static var systemResolved: SpeechRecognitionLanguage {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en-US"
        for candidate in allCases where candidate != .auto {
            guard let code = candidate.fixedLocale?.language.languageCode?.identifier else { continue }
            if preferredLanguage.hasPrefix(code) { return candidate }
        }
        return .enUS
    }
}
