import SwiftUI
import UIKit

// MARK: - 温暖配色主题

enum WarmTheme {
    // 主色调 - 珊瑚橙。使用场景收紧:仅用于「当前日期高亮 + 麦克风按钮」,
    // 不覆盖任务卡背景 / 进度环 / tab 下划线 / overdue 等次要元素。
    static let primary = Color(hex: "FF8A6B")
    static let primaryLight = Color(hex: "FFB5A0")
    static let primaryDark = Color(hex: "E56B4F")
    /// 浅色背景上的橙字(用 primary 直接做小字号文字对比度偏低)。
    /// 调用场景:时间/分类/优先级等选中态的橙字(背景是 primarySurface 浅橙底)。
    /// dark mode 反向:浅橙底配深字反而看不清,沿用 primaryLight 让字仍暖且够亮。
    static let primaryText = Color(light: "C44F35", dark: "FFB5A0")
    /// 浅色背景上的红字(优先级 high 选中态)。
    /// 与 urgent(实心红)区分:urgent 用于强调底色,urgentText 用于浅红底上的深红字。
    static let urgentText = Color(light: "C43B40", dark: "FFB3B5")

    // 背景色 - 中性冷灰白。冷化让白卡靠对比浮起。
    static let background = Color(light: "F4F5F7", dark: "1A1C1E")
    static let cardBackground = Color(light: "FFFFFF", dark: "26282B")
    static let secondaryBackground = Color(light: "FFFFFF", dark: "2A2D31")

    // 手绘风格 - 纸张色（名称保留,值跟随整体冷化）
    static let paperBackground = Color(light: "F6F7F9", dark: "1F2022")

    // 文字色 - 深墨蓝。
    static let textPrimary = Color(light: "1E2A3A", dark: "C5CBD3")
    static let textSecondary = Color(light: "5C6A7A", dark: "8A94A4")
    static let textMuted = Color(light: "8E97A4", dark: "5A626E")

    // 手绘风格 - 墨水色
    static let ink = Color(light: "2A3445", dark: "B0B8C2")
    static let sketch = Color(light: "8993A4", dark: "4A5260")

    // 状态色。urgent 用真正的红,与品牌橘明确拉开。
    static let success = Color(hex: "7BC47F")
    static let urgent = Color(hex: "E5484D")
    static let warning = Color(hex: "FFB347")

    // 分类色
    static let categoryWork = Color(hex: "6B8FE8")
    static let categoryStudy = Color(hex: "9B7FE8")
    static let categoryLife = Color(hex: "E8A87C")
    static let categoryHealth = Color(hex: "6EC99E")
    static let categoryFinance = Color(hex: "E8C86B")
    static let categorySocial = Color(hex: "E87C9B")
    static let categoryOther = Color(hex: "9BA8B8")

    // 阴影 - 冷墨蓝基色,opacity 补偿冷色阴影视觉感偏弱。
    static let shadowLight = Color(hex: "1E2A3A").opacity(0.10)
    static let shadowMedium = Color(hex: "1E2A3A").opacity(0.14)

    // 分组分隔线 - 用于 ConfirmSheet 分组 header 后的细线(对齐 HTML --line #E7E4DE)。
    // 浅色模式下接近 paperBackground 的暖灰;深色模式用 secondaryBackground 同色系。
    static let divider = Color(light: "E7E4DE", dark: "3A3D42")
    // 分组卡片内、条目之间的发丝线(对齐 HTML 设计稿 --hair #EAECEF)。
    // 与 divider 分开:divider 偏暖(#E7E4DE),画在纯白卡片上会透出一点米色,
    // 与冷化后的 cardBackground / textPrimary 不同色温;这里用中性冷灰。
    static let rowHairline = Color(light: "EAECEF", dark: "34373C")
    // 分组卡片内的小标题条底色(Today 卡里的「整天 / 上午 / 下午 / 按时间」灰条)。
    // 比 cardBackground 低一档,让它读起来是"卡片内部的分隔带"而不是一条内容。
    static let subheadBackground = Color(light: "F7F8FA", dark: "2C2F33")
    // 控件底色(未选态):中性冷灰,与冷色系文字(textPrimary/Secondary/Muted 均偏墨蓝)同色温。
    // 历史:原 #F0EDE8 米灰偏暖,与墨蓝文字混搭显"旧式 App"观感 → 改中性 #F3F4F6,
    // 暖感全部交给 primary 珊瑚橙承担,不让灰色背景也跟着暖。
    static let subtleControlBackground = Color(light: "F3F4F6", dark: "32353A")

    // 输入面板:键盘模式下「发送」按钮的深色。
    // 刻意保留暖棕:发送按钮是高频主操作,暖色作为"温度锚点"与冷背景形成对比,
    // 提升视觉优先级。
    static let deepAction = Color(light: "2F2A26", dark: "EDE8E2")

    // 警告 banner 文字色:深棕橙(浅)/ 浅米色(深),保证在 warning.opacity(0.1) 背景上可读。
    // 保留暖色:warning 背景本身是暖橙 opacity,文字同色系保证色相和谐 + 可读对比度。
    static let warningText = Color(light: "92600A", dark: "F0D9A8")
    // 警告 banner 浅色底(浅色暖米橙 / 深色深棕)。
    // 与 warningText 配对使用:背景承担「这是提示」的色相暗示,文字承担可读对比度。
    // 之前 ConfirmSheet 冲突 banner 用系统 .orange + opacity(0.08) 拼凑,色相偏离主题、
    // 深色模式下泛红像错误警告 —— 改用 token 后跟随主题整体暖灰系。
    static let warningSurface = Color(light: "FFF3E0", dark: "3A2E1F")
    // 键盘模式文本框背景:跟随 cardBackground 的明暗逻辑。
    static let inputFieldBackground = Color(light: "F8FAFB", dark: "26282B")

    // MARK: - 周条圆点透明度
    // 仅服务于 HomeMonthHeaderView.WeekStripCard 的未完成圆点 fill。
    // 月历格 eventBar 的"已完成 vs 未完成"对比已迁移到形态通道(失去填充 + 删除线),
    // 见 HomeMonthGridButton.eventBar 注释;此处不再"集中管理对比度"。
    /// 未完成圆点的透明度(接近不透明,保证分类色识别)。
    static let activeEventOpacity: Double = 0.85

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

    /// 分类浅色背景(月网格事件条用):主色 15% 透明度。
    /// 改 color(for:) 主色会自动联动,不需单独维护一套 pastel hex。
    static func categoryBackground(for category: TodoCategory) -> Color {
        color(for: category).opacity(0.15)
    }

    /// 分类深色文字(月网格事件条用):主色 85%。
    static func categoryTextColor(for category: TodoCategory) -> Color {
        color(for: category).opacity(0.85)
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
    static let segmentedThumb: CGFloat = 7   // segmented 选中滑块(比 chip 小一级,呼应外圆角)
    static let chip: CGFloat = 8             // 小标签、徽标、分类 chip、优先级选项
    static let chipEmphasis: CGFloat = 9     // 详情页频率选项 chip(介于 chip 和 segmentedTrack 之间,选中态视觉重量略升)
    static let segmentedTrack: CGFloat = 10  // segmented 外容器(比 card 小一级,层级清晰)
    static let card: CGFloat = 12            // 卡片
    static let section: CGFloat = 16         // 区块容器
    static let sheet: CGFloat = 20           // 弹窗、大装饰
}

// MARK: - 尺寸

enum WarmSize {
    static let icon: CGFloat = 28      // 内嵌图标 badge
    static let touch: CGFloat = 44     // iOS HIG hit target（保留 44，不归 4 借数）

    // MARK: - 分组卡片行高（Today 列表）
    // 设计稿只允许两档行高：单行标题 56，带副行（钟点 / 重复规则 / 「选日期」）76。
    // 这两个值是**最小高度**——长中文标题、AX5 字号下该行照常换行撑高，不截断
    // （见 CLAUDE.md「文本截断零容忍」）。视觉上绝大多数行仍落在这两档上。
    /// 单行标题行的最小高度。
    static let rowCompact: CGFloat = 56
    /// 带副行（第二行元数据 / 「选日期」按钮）的行的最小高度。
    static let rowTall: CGFloat = 76
    /// 卡内 tier 小标题条（「整天」/「上午」/「按时间」）的最小高度。
    static let rowSubhead: CGFloat = 28
    /// 行内容左边缘到分类图标左边缘的距离，= 卡内水平 padding(md 16) + checkbox 命中框(44)
    /// + HStack 间距(sm 12)。条目之间的发丝线用它做 leading inset，让线的左端与图标对齐，
    /// 而不是顶到卡片左边——这是设计稿里「分组卡看起来是一整块」的关键。
    /// 改 `WarmTodoCard` / `PendingDateTodoRow` 的 checkbox 命中框或水平 padding 时要同步改这里。
    static let rowContentLeading: CGFloat = WarmSpacing.md + 44 + WarmSpacing.sm
    /// 次要入口的视觉尺寸（如 header 齿轮按钮）：低于 HIG 44 是有意识取舍——
    /// 实际 hit target 通过外层 frame 扩展到 `touch`(44)，视觉只占 36。
    static let secondaryHit: CGFloat = 36
    /// FAB 与 tabPillSize 的直径差：FAB 是主操作，比 tab 胶囊略大形成视觉层级。
    /// 2026-07 注:底部 TabBar 已删除,此值仅服务于下方 tabPillSize 推导,
    /// 而 tabPillSize 已无引用方;保留两者仅供未来恢复 TabBar 时引用,值跟随 fab 变化不影响渲染。
    static let fabTabSizeDelta: CGFloat = 8
    /// 底部 VoiceFAB 直径（2026-07 用户反馈 68pt 在浅色玻璃材质下显眼度不足 → 72pt）。
    /// 配合 VoiceFAB 外发光圈(见 BottomTabBar.swift)提升「主操作锚点」感。
    static let fab: CGFloat = 72
    /// VoiceFAB 外发光圈在按钮单边外溢的半径(2026-07-24 抽出)。
    /// 光晕总直径 = `fab + fabHaloOverflow * 2` = 72 + 16*2 = 104。
    /// 2026-07-27 注:VoiceFAB 已改为悬浮 overlay,光晕不再占 safeAreaInset,
    /// 卡片可从光晕背后穿过并渐隐溶入背景(见 HomeView.swift 的 overlay 挂载)。
    /// 改此值需同步真机验证:光晕既不被裁切,也不挤占按钮可点击区。
    static let fabHaloOverflow: CGFloat = 16
    /// 底部 tab 玻璃胶囊直径（48→52 增大热区）。
    /// 只读计算属性（Swift 计算属性必须用 static var 声明，无 setter 故不可写），
    /// 由 fab - fabTabSizeDelta 推导。
    /// 2026-07 注:底部 TabBar 已删除,此值已无引用方,保留仅供未来恢复时引用,值跟随 fab 变化不影响渲染。
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

    /// 固定字号版 — 不响应 Dynamic Type。
    /// 用于 UI 元素(辅助按钮 label、日历日期数字、进度环里的完成计数),这些元素参考
    /// Apple Calendar 的做法不跟随系统字号缩放——日期数字是 UI 而非内容,放大后会撑爆
    /// 格子或挤压布局。
    ///
    /// 何时**不**用:tab 标签、section header、卡片标题等「文本内容」应跟随 Dynamic Type
    /// 以满足 iOS HIG 无障碍建议——继续用 `headline(_:)` 即可。判定标准:
    /// 「这是 UI 装饰数字 / label」→ 用 fixed;「这是用户要读的文本」→ 用动态。
    ///
    /// 实现:不带 `relativeTo:` 参数,`.custom` 即退化为固定字号(等同 UIKit 的 UIFont)。
    ///
    /// **已知陷阱(frame-locked 场景必须配 `.fixedSize()`)**:
    /// 字号本身不缩放,但 SwiftUI 对固定字号 Text 在 `ZStack + .frame(width:height:)` 内
    /// 仍会按 `@Environment(\.sizeCategory)` 调整 **layout 补偿**(AX1-AX5 档位下系数 ×2~3)。
    /// 表现:Text 报给父容器的 intrinsic width 被放大到超过 frame 固定宽 → 触发 `.tail`
    /// truncation → 真机显示「…」。上一轮列表模式行高下限修复未覆盖此根因。
    ///
    /// 解法:在用到本字体且被 `.frame(width:height:)` 硬约束的 `Text` 上**紧跟 `.fixedSize()`**,
    /// 让 Text 按字体本身算宽度,退出 Dynamic Type layout 补偿。例外:若 Text 在自由布局里
    /// (外层 `.frame(maxWidth: .infinity)` 或 capsule 自适应宽度),不加也不会出问题。
    ///
    /// **当前已加 fixedSize 的位置**(新增同类使用时按同模式处理):
    /// - `HomeMonthGridButton` 月历日期格(22pt circle)
    ///
    /// **未加但不受影响**:
    /// - `HomeView.statsBadge` 进度环 (40pt frame,3~5 字符 "12/30" 余量充足,暂未复现 truncation)
    static func headlineFixed(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.semibold)
    }

    static func body(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.medium)
    }

    static func caption(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.regular)
    }

    /// `caption` 的固定字号版——不响应 Dynamic Type。
    /// 用于"预览类 UI 容器"内的小字文本(如月历格事件条标题):这些文本是点开看详情的概览,
    /// 不是用户主读内容,字号跟随系统缩放会撑爆容器或触发伪截断。与 `headlineFixed` 同模式:
    /// 不带 `relativeTo:` 参数,`.custom` 即退化为固定字号(等同 UIKit UIFont)。
    ///
    /// **取舍**:违反 iOS HIG「内容文本应跟随 Dynamic Type」建议。判定标准与 `headlineFixed`
    /// 一致——「这是 UI 装饰/预览」→ 用 fixed;「这是用户要读的正文」→ 用动态 `caption`。
    ///
    /// **陷阱 A — frame-locked 场景**:与 `headlineFixed` 相同。字号不缩放,但 SwiftUI 在
    /// `ZStack + .frame(width:height:)` 内仍会按 `@Environment(\.sizeCategory)` 做 layout 补偿
    /// (AX1-AX5 ×2~3)。判据:同时用 `.frame(width:height:)` 锁死两个维度才算 frame-locked,
    /// 只锁高度(`.frame(height:)`)不触发。若 frame-locked 需紧跟 `.fixedSize()`。
    /// 例外:外层 `.frame(maxWidth: .infinity)` 自由布局时不触发此问题。
    ///
    /// **陷阱 B — HStack 内多段同行文本**:当与其它挂 `fixedSize` 的兄弟元素(如时间数字、+N 尾标)
    /// 同处一个 HStack 时,正文 Text(未挂 fixedSize)会被优先压缩(compression-resistance=250),
    /// 即使物理上总宽度还有余量,也会被压成"…"伪截断。
    /// 正解:用 `Text + Text` 拼接合并为单个 `Text`(iOS 13+ 稳定,每段保留自己的 `.font`),
    /// 或用 `AttributedString` + `.font` run 属性(iOS 17.0~17.1 部分反馈称 run 属性被忽略,优先选前者)。
    /// 详见 feedback_no_text_truncation.md 的"正确实现"条目。
    static func captionFixed(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.regular)
    }

    /// 等宽数字字体（SF Mono）— 用于时间刻度、进度数字等技术性 UI 数据。
    /// 与 `headlineFixed` 同逻辑：固定字号、不跟随 Dynamic Type（这些数字是 UI 装饰，
    /// 放大会撑爆格子或破坏时间网格对齐）。受限于 `.frame(width:height:)` 的 Text 同样需要 `.fixedSize()`。
    /// 2026-07 视觉改版：等宽 + 衬线标题 + Avenir 正文三种字体共存，营造「精致工具」辨识度。
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
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
