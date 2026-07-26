import SwiftUI

// MARK: - MarqueePhase

/// MarqueeText 的纯函数相位数学。抽出 struct 是为了能单测——View 本身没法断言 offset。
///
/// 三个输出函数都是 `t` 的纯函数:
/// - `offset(at:)`:文字 x 偏移。0 → -travel(尾段保持)。
/// - `opacity(at:)`:文字整体可见度。首 fade 秒淡入、末 fade 秒淡出。位移归零
///   恰好发生在 `t mod cycleDuration == 0`,这一刻 opacity=0,所以回跳肉眼不可见。
/// - `edgeOpacities(at:)`:两端渐隐强度。`fadeWidth` 是 mask 单侧绝对宽度(pt),
///   scrolled/remaining 跟它相除得到该侧"还有多少文字没露"的连续插值。
///
/// 所有函数都满足 `f(t) == f(t + cycleDuration)`(周期性)。
struct MarqueePhase {
    /// 需要滚动的距离 = intrinsic 宽 - 可用宽。`<= 0` 时跑马灯不启动,所有函数退化为常数。
    var travel: CGFloat
    /// 滚动速度(pt/s)。22pt/s 在 30Hz 下每帧 0.73pt,肉眼顺滑。
    var speed: Double = 22
    /// 周期首停顿(秒):用户读首段时间。
    var startPause: Double = 1.5
    /// 周期末停顿(秒):用户读尾段时间。
    var endPause: Double = 1.0
    /// 周期首末淡入淡出时长(秒)。位移在不可见时归零,fade 必须 > 0 让回跳不可见。
    /// 要求 `startPause`/`endPause` >= `fade`(否则首/末段没有稳定停留时间)。
    ///
    /// 此外要求 `cycleDuration >= fade * 2`,否则"首 fade 区间"和"末 fade 区间"
    /// 会重叠,`opacity(at:)` 在重叠区会同时命中两个分支(实际由 `if` 顺序决定结果),
    /// 产生不符合预期的非单调 opacity 曲线。默认值 (cycleDuration ≥ 2.5s, fade=0.35s)
    /// 远满足,但调用方若传极端参数需自检。
    var fade: Double = 0.35
    /// 渐隐遮罩单侧宽度(pt)。两端 stop opacity 按"该侧还剩多少文字没露"连续插值,
    /// 相除时用此常量做分母。Apple Music 渐隐宽度约 12-16pt,这里取 10pt 配合 11pt chip。
    var fadeWidth: CGFloat = 10

    /// 单次滚动耗时(秒)。travel <= 0 时为 0。
    var scrollDuration: Double {
        travel <= 0 ? 0 : Double(travel) / speed
    }

    /// 完整周期时长(秒) = 首停 + 滚动 + 末停。
    var cycleDuration: Double {
        startPause + scrollDuration + endPause
    }

    /// 校验相位参数的内部不变量。供调试/断言用,生产路径不强制调用。
    /// 违反任一条件会导致 `opacity(at:)` 输出不符合设计预期(但不会 crash)。
    var isInvariantsSatisfied: Bool {
        travel > 0
            && cycleDuration > 0
            && startPause >= fade
            && endPause >= fade
            && cycleDuration >= fade * 2
    }

    /// 给定时刻的 x 轴偏移量(负值向左)。
    /// - `[0, startPause)`:0(首停,文字贴左)
    /// - `[startPause, startPause + scrollDuration)`:`-travel * progress`(线性滚动)
    /// - `[startPause + scrollDuration, cycleDuration)`:`-travel`(末停,文字贴右)
    func offset(at t: Double) -> CGFloat {
        guard travel > 0, cycleDuration > 0 else { return 0 }
        let phaseT = t.truncatingRemainder(dividingBy: cycleDuration)
        guard phaseT >= 0 else { return 0 }
        if phaseT < startPause { return 0 }
        let scrollEnd = startPause + scrollDuration
        if phaseT < scrollEnd {
            let progress = (phaseT - startPause) / scrollDuration
            return -travel * progress
        }
        return -travel
    }

    /// 给定时刻的整体 opacity(0..1)。
    /// 周期首 `fade` 秒:0 → 1 淡入(位移归零在不可见时发生)。
    /// 周期末 `fade` 秒:1 → 0 淡出。
    /// 中间段:1。
    func opacity(at t: Double) -> Double {
        guard travel > 0, cycleDuration > 0, fade > 0 else { return 1 }
        let phaseT = t.truncatingRemainder(dividingBy: cycleDuration)
        guard phaseT >= 0 else { return 0 }
        if phaseT < fade {
            return phaseT / fade
        }
        if phaseT > cycleDuration - fade {
            return (cycleDuration - phaseT) / fade
        }
        return 1
    }

    /// 给定时刻的两端渐隐强度(0..1,1=完全不虚,0=全虚)。
    /// - leading(左侧):scrolled=0 时文字开头贴左,边缘是"开头",不虚。
    ///   随滚动进行,左侧露出中段文字,边缘变成"中间字符",该侧该虚。
    ///   leading = `1 - min(1, scrolled / fadeWidth)` 单调递减。
    /// - trailing(右侧):remaining=travel-scrolled 越小,说明右侧越接近"尾段"
    ///   完整文字,该侧不该虚。trailing = `1 - min(1, remaining / fadeWidth)` 单调递增。
    /// - `travel == 0` 时 scrolled 和 remaining 都是 0,两端 opacity 都为 1(无渐隐)。
    func edgeOpacities(at t: Double) -> (leading: Double, trailing: Double) {
        let travelF = Double(travel)
        let fadeW = Double(fadeWidth)
        guard travelF > 0, fadeW > 0 else { return (1, 1) }
        let currentOffset = Double(offset(at: t))
        let scrolled = max(0, -currentOffset)
        let remaining = max(0, travelF - scrolled)
        let leading = 1 - min(1, scrolled / fadeW)
        let trailing = 1 - min(1, remaining / fadeW)
        return (leading, trailing)
    }

    /// FNV-1a 64-bit。跨进程稳定的字符串哈希。
    ///
    /// 用于 `MarqueeText.phaseShift` —— 不能用 `String.hashValue`(Swift 标准库
    /// 为防 hash flooding 加了每进程随机 seed,冷启动后哈希值会变,导致同一条
    /// todo 的错峰位置每次启动都不一样)。
    ///
    /// 算法:初始 offset = `0xcbf29ce484222325`,prime = `0x100000001b8b1c65`,
    /// 每个 byte 做 `hash ^= byte; hash &*= prime`。`&*` 是 wrapping 乘法,
    /// 跟标准 FNV-1a 一致(显式溢出而非 trap)。
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b8b1c65
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }
}

// MARK: - MarqueeText

/// 单行文本的"放不下则跑马灯滚动"行为。
///
/// 文字放得下时跟普通 `Text` 完全一致;放不下时容器宽度固定不变,文字横向滚动:
/// 开头停 ~1.5s → 慢速滚到尾 → 停 ~1s → 淡出归零再淡入,循环。
/// 两端动态渐隐(只在文字真的滚到边缘时该侧才发虚)。
///
/// # 为什么用"双层结构"避开布局回环
///
/// `.fixedSize(horizontal: true, vertical: false)` 的 `Text` 以完整 intrinsic 宽
/// 参与布局且不可压缩——对短文本("18:00")是对的,但对 AI 原文这种长度无界的
/// 文本会挤压兄弟元素。本组件用两层 `Text` 解耦:
/// - **布局锚层**:`Text.lineLimit(1)` 不挂 fixedSize,`.opacity(0)`。
///   `Text` 的 ideal width = intrinsic, min width 极小,所以父容器给的宽度
///   天然就是 `min(intrinsic, 父宽)`——这正是要的"有空间就贴合,没空间就让步"。
///   永不显示,只撑布局。
/// - **显示层**:`.overlay(alignment: .leading)` 里的 `Text.fixedSize(horizontal: true)`
///   永远是完整文字,按相位做 `.offset(x:)`,外层 `.clipped()` 裁掉溢出。
///
/// 测量用 `.onGeometryChange`(iOS 17+),不通过 `GeometryReader`,不影响 layout;
/// `offset` 是 transform 不改尺寸,所以测量不会触发重布局,无 layout cycle 风险。
///
/// # 动画驱动
///
/// 用无状态 `TimelineView(.periodic(from: .now, by: 1.0/30.0))`。30 Hz 在 22 pt/s
/// 速度下每帧位移 0.73pt,肉眼顺滑,又不像 `.animation` 每帧重绘在低端机掉帧。
///
/// 不用 `@State + .onAppear + .repeatForever`:`List` 的 cell 随滚动被回收重建,
/// `@State` 重置会让滚动位置跳变,与 `ConfirmGroupedList.swift:163-166` 记录的
/// `StreamingFooter` 闪烁问题同源;也避开 `BottomInputPanelView.swift:145-146`
/// 记录的 `.repeatForever` 停不下来的 SwiftUI 缺陷。
///
/// # 错峰(避免"广告屏"机械感)
///
/// 多张卡片整齐划一同时滚动像商场广告屏。但"按各自入场时刻起算"要存 `@State`
/// 时间戳,`List` cell 回收重建会重置——卡片滚出再滚回跑马灯从头再来。
///
/// 两全做法是从文本内容哈希出确定性相位偏移(`phaseShift`),用 `stableHash`
/// (FNV-1a 64-bit, 跨进程稳定)而非 `String.hashValue`(每进程随机 seed,
/// 冷启动后会变)。这样既错峰又无状态,cell 重建后相位连续。
///
/// # 三个静态短路条件
///
/// 任一命中就不建 `TimelineView`、不起帧、渲染成一个普通 `Text`:
/// - `travel <= 0`(文字放得下)——绝大多数短文本走这条,零成本
/// - `@Environment(\.accessibilityReduceMotion)` 为真——退化为静态截断 + 右侧渐隐
/// - 卡片滚出视野——`.onScrollVisibilityChange(threshold: 0.05)` 置 isVisible=false
///
/// # threshold = 0.05 而非 0.5 的理由
///
/// `offset` 是绝对时间的纯函数,"暂停"只是停止重绘、并不冻结相位——恢复渲染的
/// 那一刻会直接跳到当前时刻应有的位置。取 0.5 这个跳变发生在卡片半可见时、
/// 正对着用户眼睛;取 0.05 则推到卡片几乎完全出屏的位置,肉眼基本抓不到。
/// 省帧收益差别不大——List 本身早就把远处的 cell 拆掉了,这个 threshold 只
/// 兜住"贴着边缘还活着"的那一两张。
///
/// # 依赖的 iOS 版本
///
/// - `onScrollVisibilityChange(threshold:action:)`:iOS 17.0+
/// - `onGeometryChange(for:of:action:)`:iOS 16.0+ 但稳定使用建议 17.0+
/// 项目 deployment target 为 iOS 17.0+,均可用。若未来下调 deployment,需先
/// 替换这两个 API。
struct MarqueeText: View {
    let text: String
    var font: Font
    /// nil(默认)时显示层 Text 不显式设 foregroundColor,跟随父 environment。
    /// 调用方需要 chip 分类色等语义色时不必显式传 —— 父 HStack.foregroundColor
    /// 已经在 environment 里。ChipView 走 marquee 分支时显式传 resolvedAccent
    /// 是因为 ChipView.label 在 marquee 路径下没把 accent 设进 environment。
    var foregroundColor: Color? = nil
    /// 容器最小宽度兜底。AX5 字号下父容器可能给极小宽度,锚层被压到接近 0 时
    /// 测得的"可用宽"失真,导致 marquee 提前启动。36pt 是观察到的"中文 2 字 +
    /// chip padding"下限,够显示首字符 + 渐隐遮罩。
    ///
    /// 已知限制:若父 HStack 给 chip 的预算宽度 < `minWidth`,锚层仍会被撑到
    /// `minWidth` 参与布局,理论上可能轻微挤压兄弟元素。当前所有 chip 调用点
    /// (ChipView in PendingDateTodoRow / WarmTodoCard)的兄弟元素都是 fixedSize
    /// 按钮(44pt hit target),不会被这 36pt 兜底挤到不可用。若未来出现极窄列
    /// 场景(如 split view),需要重审 minWidth 与父预算的关系。
    var minWidth: CGFloat = 36

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableWidth: CGFloat = 0
    @State private var intrinsicWidth: CGFloat = 0
    @State private var isVisible: Bool = true

    /// 当前相位参数。travel 由两层 onGeometryChange 测得的宽度差决定。
    private var phase: MarqueePhase {
        MarqueePhase(travel: max(0, intrinsicWidth - availableWidth))
    }

    /// 内容哈希出的确定性相位偏移(`0 ..< cycleDuration`)。
    /// 让同屏多张卡片错峰滚动,避开"广告屏"机械感。
    private var phaseShift: Double {
        let cycle = phase.cycleDuration
        guard cycle > 0 else { return 0 }
        return Double(MarqueePhase.stableHash(text) % 1000) / 1000 * cycle
    }

    @ViewBuilder
    private var anchorLabel: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
    }

    @ViewBuilder
    private var displayLabel: some View {
        let base = Text(text)
            .font(font)
            .lineLimit(1)
        if let foregroundColor {
            base.foregroundColor(foregroundColor)
        } else {
            base
        }
    }

    var body: some View {
        let phase = self.phase
        let canMarquee = phase.travel > 0 && !reduceMotion && isVisible

        Group {
            if canMarquee {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate + phaseShift
                    let offset = phase.offset(at: t)
                    let opacity = phase.opacity(at: t)
                    let edges = phase.edgeOpacities(at: t)

                    anchorLayer
                        .overlay(alignment: .leading) {
                            displayLayer
                                .offset(x: offset)
                                .opacity(opacity)
                        }
                        .clipped()
                        .mask(edgeMask(
                            leadingOpacity: edges.leading,
                            trailingOpacity: edges.trailing,
                            fadeWidthPt: phase.fadeWidth
                        ))
                }
            } else {
                // 静态路径:travel==0(短文本) / reduceMotion / 滚出视野。
                // travel==0 时 mask 两端 opacity 都 1,等于无渐隐,跟普通 Text 一致。
                // travel>0 但 reduceMotion/不可见 时,mask 左侧=1 右侧=0,呈现"开头 + 右侧渐隐"
                // —— 模拟 marquee 首帧的视觉(首停顿期间位移=0,左侧贴开头,右侧还没露尾段)。
                anchorLayer
                    .overlay(alignment: .leading) {
                        displayLayer
                    }
                    .clipped()
                    .mask(edgeMask(
                        leadingOpacity: 1,
                        trailingOpacity: phase.travel > 0 ? 0 : 1,
                        fadeWidthPt: phase.fadeWidth
                    ))
            }
        }
        .onScrollVisibilityChange(threshold: 0.05) { visible in
            if isVisible != visible {
                isVisible = visible
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 布局锚层:撑尺寸,不显示(opacity 0)。挂 onGeometryChange 测可用宽。
    /// 不挂 fixedSize → Text 的 ideal width = intrinsic, min width 极小,
    /// 父容器给的宽度天然取 min(intrinsic, 父宽)。
    private var anchorLayer: some View {
        anchorLabel
            .opacity(0)
            .frame(minWidth: minWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(availableWidth - newWidth) > 0.5 {
                    availableWidth = newWidth
                }
            }
    }

    /// 显示层:挂 fixedSize 永远完整宽度,挂 onGeometryChange 测 intrinsic 宽。
    /// offset/opacity 由调用方按相位 transform。
    private var displayLayer: some View {
        displayLabel
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(intrinsicWidth - newWidth) > 0.5 {
                    intrinsicWidth = newWidth
                }
            }
    }

    /// 4 段 stop 的 LinearGradient mask,两端 opacity 连续插值。
    /// `fadeWidthPt` 是绝对宽度(单位 pt),通过 GeometryReader 在 mask 内部换算成
    /// 相对 location(0..1)。`min(0.5, fadeWidthPt/w)` 防止极窄容器时 fadeLocation
    /// 超过 0.5 导致中间不透明段消失。
    ///
    /// 注意:此处的 `fadeWidthPt` 必须与 `MarqueePhase.fadeWidth` 保持一致——
    /// mask 渐隐范围要与 edgeOpacities 计算时假设的"渐隐带宽度"匹配,
    /// 否则视觉渐隐与 opacity 计算错位。调用方应直接传 `phase.fadeWidth`,
    /// 不要在 mask 内重新硬编码。
    private func edgeMask(
        leadingOpacity: Double,
        trailingOpacity: Double,
        fadeWidthPt: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let fadeLoc = w > 0 ? min(0.5, fadeWidthPt / w) : 0
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(leadingOpacity), location: 0.0),
                    .init(color: .black.opacity(1), location: fadeLoc),
                    .init(color: .black.opacity(1), location: 1.0 - fadeLoc),
                    .init(color: .black.opacity(trailingOpacity), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

// MARK: - Previews

#if DEBUG

/// MarqueeText 的预览:覆盖 短/长 × 默认/AX5 四种组合。
/// Canvas 里观察:
/// - 短文本("下午")必须完全静止、视觉与改动前一致
/// - 长文本("by the end of this month")容器宽度固定不变,文字循环滚动,两端动态渐隐
/// - AX5 字号下没有 ... 伪截断,marquee 仍能滚动
private struct MarqueePreviewContainer: View {
    let label: String
    let text: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack {
                MarqueeText(text: text, font: WarmFont.caption(11.5))
            }
            .padding(8)
            .background(WarmTheme.sketch.opacity(0.18))
            .cornerRadius(7)
            // 固定宽度模拟 chip 容器在 HStack 中被父给的预算宽度
            .frame(width: width, alignment: .leading)
        }
    }
}

#Preview("MarqueeText — short/long × default/AX5") {
    VStack(alignment: .leading, spacing: 16) {
        MarqueePreviewContainer(label: "短 ZH(应静止)", text: "下午", width: 200)
        MarqueePreviewContainer(label: "短 EN(应静止)", text: "tonight", width: 200)
        MarqueePreviewContainer(label: "长 ZH(应滚动)", text: "每个月15号下午3点", width: 200)
        MarqueePreviewContainer(label: "长 EN(应滚动)", text: "by the end of this month", width: 200)
    }
    .padding()
}

#Preview("MarqueeText — AX5 字号") {
    VStack(alignment: .leading, spacing: 16) {
        MarqueePreviewContainer(label: "长 EN AX5(应滚动,无截断)", text: "by the end of this month", width: 200)
        MarqueePreviewContainer(label: "长 ZH AX5(应滚动,无截断)", text: "每个月15号下午3点", width: 200)
    }
    .padding()
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#endif

