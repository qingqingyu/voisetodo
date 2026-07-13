import SwiftUI
import UIKit

// MARK: - 温暖配色主题

enum WarmTheme {
    // 主色调 - 温暖的珊瑚橙
    static let primary = Color(hex: "FF8A6B")
    static let primaryLight = Color(hex: "FFB5A0")
    static let primaryDark = Color(hex: "E56B4F")

    // 背景色 - 奶油白（深色模式自适应为暖中性深色）
    static let background = Color(light: "FFFBF7", dark: "1C1B1A")
    static let cardBackground = Color(light: "FFFFFF", dark: "2B2926")
    static let secondaryBackground = Color(light: "FFF5EE", dark: "26241F")

    // 手绘风格 - 纸张色
    static let paperBackground = Color(light: "FFF8F0", dark: "1F1E1C")

    // 文字色（深色模式自适应为浅墨色）
    static let textPrimary = Color(light: "3D3A38", dark: "EDE8E2")
    static let textSecondary = Color(light: "8B8580", dark: "A8A29B")
    static let textMuted = Color(light: "B8B3AD", dark: "6B6660")

    // 手绘风格 - 墨水色
    static let ink = Color(light: "4A4543", dark: "E8E3DD")
    static let sketch = Color(light: "6B6560", dark: "B0AAA3")

    // 状态色
    static let success = Color(hex: "7BC47F")
    static let urgent = Color(hex: "FF6B6B")
    static let warning = Color(hex: "FFB347")

    // 分类色
    static let categoryWork = Color(hex: "6B8FE8")
    static let categoryStudy = Color(hex: "9B7FE8")
    static let categoryLife = Color(hex: "E8A87C")
    static let categoryHealth = Color(hex: "6EC99E")
    static let categoryFinance = Color(hex: "E8C86B")
    static let categorySocial = Color(hex: "E87C9B")
    static let categoryOther = Color(hex: "9BA8B8")

    // 阴影
    static let shadowLight = Color(hex: "3D3A38").opacity(0.08)
    static let shadowMedium = Color(hex: "3D3A38").opacity(0.12)

    // 输入面板：键盘模式下「发送」按钮的深色（替代散落的 RGB 字面量）
    static let deepAction = Color(light: "2F2A26", dark: "EDE8E2")

    // 警告 banner 文字色：深棕橙（浅色）/ 浅米色（深色），保证在 WarmTheme.warning.opacity(0.1) 背景上可读
    static let warningText = Color(light: "92600A", dark: "F0D9A8")
    // 键盘模式文本框背景：奶油白（浅色）/ 深灰（深色），跟随 cardBackground 的明暗逻辑
    static let inputFieldBackground = Color(light: "FAFAF8", dark: "2B2926")

    /// 根据分类获取对应颜色
    static func color(for category: TodoCategory) -> Color {
        switch category {
        case .work: return categoryWork
        case .study: return categoryStudy
        case .life: return categoryLife
        case .health: return categoryHealth
        case .finance: return categoryFinance
        case .social: return categorySocial
        case .other: return categoryOther
        }
    }
}

// MARK: - 间距（严格 4 借数系统）

enum WarmSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// MARK: - 圆角

enum WarmRadius {
    static let chip: CGFloat = 8       // 小标签、徽标
    static let card: CGFloat = 12      // 卡片
    static let section: CGFloat = 16   // 区块容器
    static let sheet: CGFloat = 20     // 弹窗、大装饰
}

// MARK: - 尺寸

enum WarmSize {
    static let icon: CGFloat = 28      // 内嵌图标 badge
    static let touch: CGFloat = 44     // iOS HIG hit target（保留 44，不归 4 借数）
    /// FAB 与 tabPillSize 的直径差：FAB 是主操作，比 tab 胶囊略大形成视觉层级。
    /// 改任一个直径时必须同步评估此不变量是否仍合理。
    static let fabTabSizeDelta: CGFloat = 8
    /// 底部 VoiceFAB 直径（68pt——方案一：FAB 独占底部，是 app 签名按钮，比三件套时代大一圈）。
    static let fab: CGFloat = 68
    /// 底部 tab 玻璃胶囊直径（48→52 增大热区）。
    /// 只读计算属性（Swift 计算属性必须用 static var 声明，无 setter 故不可写），
    /// 由 fab - fabTabSizeDelta 推导，不变量在编译期成立。
    static var tabPillSize: CGFloat { fab - fabTabSizeDelta }
    static let sendButton: CGFloat = 48 // 输入面板发送钮
    static let hero: CGFloat = 80      // 大圆圈装饰
    static let mega: CGFloat = 120     // 最大装饰元素
}

// MARK: - 动画

enum WarmAnimation {
    static let springFast = Animation.spring(response: 0.25, dampingFraction: 0.8)
    static let springStandard = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let springSmooth = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let springSlow = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let springCard = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let springButton = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let springEntrance = Animation.spring(response: 0.6, dampingFraction: 0.8)

    // 月历单元格选中态缩放系数：弱提示（避免挤压相邻格），Reduce Motion 时 animation 被系统忽略
    static let monthDaySelectedScale: CGFloat = 1.05
    static let monthDayDefaultScale: CGFloat = 1.0
}

// MARK: - 统一字体工具

enum WarmFont {
    /// 根据 pt 大小推断对应的语义 textStyle，作为 Dynamic Type 缩放基准。
    /// 让 `.custom(size:)` 跟随系统「设置 → 显示 → 文字大小」缩放，符合 iOS HIG 无障碍要求。
    /// 推断依据：iOS HIG 默认字号表（caption2=11 / caption=12 / footnote=13 /
    /// subheadline=15 / callout=16 / body=17 / title3=20 / title2=22 / title=28 / largeTitle=34）。
    private static func relativeTextStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...12:        return .caption2      // 11-12pt
        case 13...14:      return .footnote      // 13-14pt
        case 15:           return .subheadline   // 15pt
        case 16:           return .callout       // 16pt
        case 17...19:      return .body          // 17-19pt
        case 20...21:      return .title3        // 20-21pt
        case 22...25:      return .title2        // 22-25pt
        case 26...32:      return .title         // 26-32pt
        default:           return .largeTitle    // 33pt+
        }
    }

    /// 手写风格展示字体 — 用于问候语、大标题等情感化文字
    static func display(_ size: CGFloat) -> Font {
        .custom("Noteworthy", size: size, relativeTo: relativeTextStyle(for: size)).weight(.bold)
    }

    /// 展示字体轻量版 — 用于副标题、装饰性文字
    static func displayLight(_ size: CGFloat) -> Font {
        .custom("Noteworthy", size: size, relativeTo: relativeTextStyle(for: size)).weight(.light)
    }

    /// 衬线展示字体：主页与日历标题使用系统语义字号，随 Dynamic Type 缩放。
    static func serifDisplay(_ size: CGFloat) -> Font {
        .system(relativeTextStyle(for: size), design: .serif).weight(.semibold)
    }

    static func title(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.bold)
    }

    static func headline(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.semibold)
    }

    static func body(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.medium)
    }

    static func caption(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.regular)
    }
}

extension TimeBucket {
    var localizedTitle: String {
        switch self {
        case .anytime:
            return String(localized: "time_bucket.anytime")
        case .morning:
            return String(localized: "time_bucket.morning")
        case .afternoon:
            return String(localized: "time_bucket.afternoon")
        case .evening:
            return String(localized: "time_bucket.evening")
        }
    }
}

// MARK: - 纸张纹理背景

/// 可复用的纸张纹理背景组件 — 从 Onboarding 延续到全局
struct PaperTextureBackground: View {
    var baseColor: Color = WarmTheme.background
    var showCornerDoodles: Bool = false

    private static let grainOpacity: Double = 0.015

    private static let texturePoints: [(x: CGFloat, y: CGFloat, opacity: Double)] = {
        var points: [(x: CGFloat, y: CGFloat, opacity: Double)] = []
        var seed: UInt64 = 12345
        func seededRandom() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed & 0xFFFF) / Double(0xFFFF)
        }
        for _ in 0..<80 {
            points.append((
                x: seededRandom(),
                y: seededRandom(),
                opacity: 0.008 + seededRandom() * grainOpacity
            ))
        }
        return points
    }()

    var body: some View {
        ZStack {
            baseColor
                .ignoresSafeArea()

            Canvas { context, size in
                for point in Self.texturePoints {
                    let x = point.x * size.width
                    let y = point.y * size.height
                    let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Color.black.opacity(point.opacity))
                    )
                }
            }
            .ignoresSafeArea()

            if showCornerDoodles {
                VStack {
                    HStack {
                        CornerDoodle(rotation: 0)
                        Spacer()
                        CornerDoodle(rotation: 90)
                    }
                    Spacer()
                    HStack {
                        CornerDoodle(rotation: -90)
                        Spacer()
                        CornerDoodle(rotation: 180)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// 可复用的角落手绘装饰
struct CornerDoodle: View {
    let rotation: Double

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 30))
            path.addCurve(
                to: CGPoint(x: 30, y: 0),
                control1: CGPoint(x: 0, y: 15),
                control2: CGPoint(x: 15, y: 0)
            )
        }
        .stroke(WarmTheme.sketch.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 30, height: 30)
        .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Color Extension

extension Color {
    /// 自适应颜色：根据系统浅色/深色模式选择对应的 hex 值。
    /// 复用下方的 `Color(hex:)` 解析逻辑，通过动态 UIColor 在运行时跟随 traitCollection。
    init(light: String, dark: String) {
        self = Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? Color(hex: dark) : Color(hex: light))
        })
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
