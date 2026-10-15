import SwiftUI

// MARK: - 复盘流程视觉共用件(v6 视觉改版)
//
// 复盘五步流程共用的小型视觉原语。R12:不进 `ReviewFlowView.swift`;
// R11:不碰回顾页(`ReviewView`)在用的 `RecapHeroSection` / `RecapStatCard`
// (经 `RecapStatsRow`)——本文件只新增复盘专用视图。(`RecapEvidenceRow`
// 虽在 R11 列名,但回顾页从未用它,v6 后无调用方,见其类型注释。)

/// 小标题(eyebrow,v6 §1.4):英文 12pt 大写加字距;中文、日文 13pt 不大写
/// 不加字距。语言判定跟随 **App 实际渲染所用的本地化**
/// (`Bundle.main.preferredLocalizations`,与 `String(localized:)` 取同一语言)
/// ——不是系统语言设置(内容语言与系统语言解耦的既有口径)。
struct ReviewEyebrow: View {
    let text: String

    var body: some View {
        Group {
            if Self.usesCJKTraits {
                Text(text)
                    .font(WarmFont.caption(13))
            } else {
                Text(text.uppercased())
                    .font(WarmFont.caption(12))
                    .tracking(0.8)
            }
        }
        .foregroundColor(WarmTheme.textMuted)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// 当前本地化是否中日文(eyebrow 走「不大写不加字距」的 13pt 形态)。
    static var usesCJKTraits: Bool {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return code.hasPrefix("zh") || code.hasPrefix("ja")
    }
}
