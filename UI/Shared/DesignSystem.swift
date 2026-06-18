import SwiftUI

// MARK: - 温暖配色主题

enum WarmTheme {
    // 主色调 - 温暖的珊瑚橙
    static let primary = Color(hex: "FF8A6B")
    static let primaryLight = Color(hex: "FFB5A0")
    static let primaryDark = Color(hex: "E56B4F")

    // 背景色 - 奶油白
    static let background = Color(hex: "FFFBF7")
    static let cardBackground = Color(hex: "FFFFFF")
    static let secondaryBackground = Color(hex: "FFF5EE")

    // 手绘风格 - 纸张色
    static let paperBackground = Color(hex: "FFF8F0")

    // 文字色
    static let textPrimary = Color(hex: "3D3A38")
    static let textSecondary = Color(hex: "8B8580")
    static let textMuted = Color(hex: "B8B3AD")

    // 手绘风格 - 墨水色
    static let ink = Color(hex: "4A4543")
    static let sketch = Color(hex: "6B6560")

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
