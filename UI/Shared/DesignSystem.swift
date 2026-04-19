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

    // 阴影
    static let shadowLight = Color(hex: "3D3A38").opacity(0.08)
    static let shadowMedium = Color(hex: "3D3A38").opacity(0.12)
}

// MARK: - 统一字体工具

enum WarmFont {
    static func title(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.bold)
    }

    static func headline(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.semibold)
    }

    static func body(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.medium)
    }

    static func caption(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.regular)
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
