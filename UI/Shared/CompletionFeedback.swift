import SwiftUI

// 完成待办的正反馈组件(分级制方案 docs/todo-completion-feedback.md,含 2026-09-01 复核修订):
// - 常规档:爆花 = 勾号原地「点+星」放射 + 细涟漪,success 绿 + 分类色,~500ms;
// - 大庆祝:全屏彩带(今日清空)+ 中央庆祝文案;
// - 全部 Canvas/TimelineView 自绘,零第三方依赖;纯视觉层不可命中 + a11y 隐藏,
//   不加 a11y identifier(「UI 测试防护」:防 identifier 污染历史坑)。

// MARK: - 常量

/// 完成正反馈的时序/尺寸常量。
enum CompletionFeedbackMetrics {
    /// 爆花在 tap 后的接力延时:WarmTodoCard 勾号 trim 描画(0.3s easeInOut)
    /// 进行到大半时爆开,接力不抢戏(方案 §4)。PendingDateTodoRow 无勾号动画,
    /// 同一固定延时(复核 B:时机退化为 tap 后固定延时)。
    static let burstRelayDelay: TimeInterval = 0.22

    /// 单次爆花总时长(点+星飞散淡出 + 涟漪扩散)。
    static let burstDuration: TimeInterval = 0.5

    /// 爆花实例从集合清理的延时(动画时长 + 余量;行滚出屏幕也不提前掐断)。
    static let burstCleanupDelay: TimeInterval = burstRelayDelay + burstDuration + 0.2

    /// 今日清空检测延时:toggle 改 store → `.task(id:)` 先清空 monthOccurrences 缓存
    /// (HomeView.swift 该 task 首段同步执行),之后 selectedDayStats() 走
    /// store.todos 兜底分支读到新值。250ms 足够跨过这一拍。
    static let clearCheckDelay: TimeInterval = 0.25

    /// 全屏彩带时长。
    static let confettiDuration: TimeInterval = 1.5

    /// 彩带实例清理延时(动画时长 + 余量)。
    static let confettiCleanupDelay: TimeInterval = confettiDuration + 0.3

    /// 中央庆祝文案显示时长。
    static let celebrationBannerDuration: TimeInterval = 2.0
}

// MARK: - Checkbox 锚点上报

/// checkbox 边界上报:WarmTodoCard / PendingDateTodoRow 的勾选框把自己的 bounds
/// 以 todo id 为键上浮;HomeView 顶层 overlay 据此定位爆花原点。
///
/// 为什么不挂行内粒子:List 行把内容裁到行边界(HomeSelectedDayListView 是 `List`),
/// 行高 56-76pt 会切掉飞散中的粒子;顶层 overlay 与行生命周期解耦,
/// 行滚出屏幕动画也不被掐断(方案「实现要点」/复核 A)。
struct CompletionCheckboxAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        for (id, anchor) in nextValue() {
            value[id] = anchor
        }
    }
}

// MARK: - 爆花模型与渲染

/// 一次爆花实例。连点互不打断:每次完成生成独立实例并行渲染,到点自清理
/// (方案「实现要点」:顶层维护「进行中的爆花」集合而非单个 @State)。
struct CompletionBurst: Identifiable {
    let id = UUID()

    /// 被勾选的 todo id —— 用于从 anchor 表查 checkbox 位置。
    let todoID: UUID

    /// 粒子参数。创建时按确定性随机一次性生成,Canvas 每帧只做纯时间函数渲染。
    let particles: [CompletionBurstParticle]

    /// 爆花起播时刻(创建时刻 + 接力延时;渲染层在起播前不画)。
    let startsAt: Date
}

/// 单颗爆花粒子。
struct CompletionBurstParticle {
    enum Shape {
        /// 圆点(主力,负责「爆」)。
        case dot
        /// 四角小星(点缀 1-2 颗,负责「趣」)。
        case star
    }

    let shape: Shape
    /// 放射方向(弧度)。
    let angle: Double
    /// 出发半径:checkbox 圆环外沿(24pt 圆环,半径 ~10pt)。
    let startRadius: Double
    /// 终点半径。
    let endRadius: Double
    /// 粒子尺寸(pt;star 为外接半径)。
    let size: Double
    let color: Color
}

/// 爆花粒子生成 + 帧渲染。无状态:同 seed 生成同粒子,同 (粒子, 时刻) 画同画面。
enum CompletionBurstRenderer {
    /// 7±2 颗圆点 + 1-2 颗四角星,颜色 = success 绿 + 分类色各半左右。
    static func particles(colors: [Color], seed: UInt64) -> [CompletionBurstParticle] {
        var rng = SeededRandom(seed: seed)
        let dotCount = rng.intRange(6, 9)
        let starCount = rng.intRange(1, 2)
        var result: [CompletionBurstParticle] = []
        result.reserveCapacity(dotCount + starCount)
        for _ in 0..<dotCount {
            result.append(
                CompletionBurstParticle(
                    shape: .dot,
                    angle: rng.range(0, 2 * .pi),
                    startRadius: rng.range(11, 14),
                    endRadius: rng.range(26, 40),
                    size: rng.range(2.5, 4.2),
                    color: colors[rng.intRange(0, colors.count - 1)]
                )
            )
        }
        for _ in 0..<starCount {
            result.append(
                CompletionBurstParticle(
                    shape: .star,
                    angle: rng.range(0, 2 * .pi),
                    startRadius: rng.range(11, 13),
                    endRadius: rng.range(24, 32),
                    size: rng.range(5.0, 6.5),
                    color: colors[rng.intRange(0, colors.count - 1)]
                )
            )
        }
        return result
    }

    /// 渲染一帧:涟漪先画(框出爆点),粒子 ease-out 减速飞散、末段淡出。
    static func draw(
        particles: [CompletionBurstParticle],
        rippleColor: Color,
        center: CGPoint,
        startsAt: Date,
        now: Date,
        context: inout GraphicsContext
    ) {
        let t = now.timeIntervalSince(startsAt) / CompletionFeedbackMetrics.burstDuration
        guard t >= 0, t <= 1 else { return }
        let eased = 1 - pow(1 - t, 3)

        // 细涟漪:半径 12 → 28,线宽随扩散收细,整体淡出。
        let rippleRadius = 12 + eased * 16
        let rippleAlpha = 0.8 * (1 - t)
        var ripple = Path()
        ripple.addEllipse(
            in: CGRect(
                x: center.x - rippleRadius,
                y: center.y - rippleRadius,
                width: rippleRadius * 2,
                height: rippleRadius * 2
            )
        )
        context.stroke(
            ripple,
            with: .color(rippleColor.opacity(rippleAlpha)),
            style: StrokeStyle(lineWidth: max(0.5, 2 * (1 - eased)))
        )

        // 粒子:出发于圆环外沿,ease-out 减速到终点;前 60% 全不透明,后 40% 线性淡出;
        // 尺寸随飞行轻微收缩,增强「飞散消散」的观感。
        let particleAlpha: Double = t < 0.6 ? 1 : (1 - t) / 0.4
        for particle in particles {
            let radius = particle.startRadius + eased * (particle.endRadius - particle.startRadius)
            let x = center.x + cos(particle.angle) * radius
            let y = center.y + sin(particle.angle) * radius
            let size = particle.size * (1 - 0.25 * eased)
            let color = particle.color.opacity(particleAlpha)
            switch particle.shape {
            case .dot:
                var dot = Path()
                dot.addEllipse(
                    in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                )
                context.fill(dot, with: .color(color))
            case .star:
                let star = starPath(center: CGPoint(x: x, y: y), radius: size)
                context.fill(star, with: .color(color))
            }
        }
    }

    /// 四角星路径:8 个顶点在外接/内切半径间交替,起点朝上。
    private static func starPath(center: CGPoint, radius: Double) -> Path {
        var path = Path()
        let innerRadius = radius * 0.4
        for i in 0..<8 {
            let angle = -.pi / 2 + Double(i) * .pi / 4
            let r = i.isMultiple(of: 2) ? radius : innerRadius
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// 爆花渲染层:挂在 HomeView 顶层,按 anchor 表解析每个进行中爆花的 checkbox 位置。
///
/// a11y/命中防护(方案「实现要点」):`.allowsHitTesting(false)` + `.accessibilityHidden(true)`
/// —— 挂顶层 overlay 后会进入 a11y 树,光靠不加 identifier 不足以让元素查询忽略它。
struct CompletionBurstLayer: View {
    /// 进行中的爆花集合(HomeView 维护)。
    let bursts: [CompletionBurst]
    /// checkbox 边界表(overlayPreferenceValue 直供,天然最新)。
    let anchors: [UUID: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: bursts.isEmpty)) { timeline in
                Canvas { context, _ in
                    for burst in bursts {
                        // 行已滚出屏幕 → anchor 不在表里,本实例无声跳过(不做位置兜底)。
                        guard let anchor = anchors[burst.todoID] else { continue }
                        let rect = proxy[anchor]
                        CompletionBurstRenderer.draw(
                            particles: burst.particles,
                            rippleColor: WarmTheme.success,
                            center: CGPoint(x: rect.midX, y: rect.midY),
                            startsAt: burst.startsAt,
                            now: timeline.date,
                            context: &context
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 全屏彩带(今日清空大庆祝)

/// 单片彩带纸条。
struct CompletionConfettiPiece {
    /// 出发横向位置(0..1 屏宽比例)。
    let x0: Double
    /// 出发延时:错落下落,避免一排整齐掉下来。
    let fallDelay: Double
    /// 下落总时长。
    let fallDuration: Double
    let width: Double
    let height: Double
    let color: Color
    /// 自旋速度(圈/全程)。
    let spin: Double
    /// 横向摆幅(pt)与摆动频率。
    let driftAmp: Double
    let driftFreq: Double
}

/// 一次彩带展示实例。
struct CompletionConfettiShow: Identifiable {
    let id = UUID()
    let pieces: [CompletionConfettiPiece]
    let startedAt: Date
}

/// 彩带生成器:分类色 + 暖色系纸条 24 片(方案 §6:20-30 片)。
enum CompletionConfettiGenerator {
    static func pieces(count: Int = 24, seed: UInt64) -> [CompletionConfettiPiece] {
        var rng = SeededRandom(seed: seed)
        let palette: [Color] = [
            WarmTheme.color(for: .work),
            WarmTheme.color(for: .study),
            WarmTheme.color(for: .life),
            WarmTheme.color(for: .health),
            WarmTheme.color(for: .finance),
            WarmTheme.color(for: .social),
            WarmTheme.color(for: .other),
            WarmTheme.primary,
            WarmTheme.primaryLight,
            WarmTheme.warning,
        ]
        return (0..<count).map { _ in
            CompletionConfettiPiece(
                x0: rng.range(0.02, 0.98),
                fallDelay: rng.range(0, 0.25),
                fallDuration: rng.range(
                    CompletionFeedbackMetrics.confettiDuration * 0.75,
                    CompletionFeedbackMetrics.confettiDuration
                ),
                width: rng.range(5, 9),
                height: rng.range(3, 5),
                color: palette[rng.intRange(0, palette.count - 1)],
                spin: rng.range(0.8, 2.2),
                driftAmp: rng.range(6, 22),
                driftFreq: rng.range(0.8, 1.6)
            )
        }
    }
}

/// 全屏彩带渲染层:顶部撒落,1.5s,纯视觉不挡交互(清空瞬间用户可能马上离 app)。
struct CompletionConfettiLayer: View {
    let show: CompletionConfettiShow

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, canvasSize in
                guard canvasSize.height > 0 else { return }
                let elapsed = timeline.date.timeIntervalSince(show.startedAt)
                for piece in show.pieces {
                    let t = (elapsed - piece.fallDelay) / piece.fallDuration
                    guard t >= 0, t <= 1 else { continue }
                    let y = -30 + t * (canvasSize.height + 60)
                    let x = piece.x0 * canvasSize.width
                        + sin(t * 2 * .pi * piece.driftFreq + piece.x0 * 6.28) * piece.driftAmp
                    let alpha: Double = t < 0.75 ? 1 : (1 - t) / 0.25
                    let transform = CGAffineTransform(translationX: x, y: y)
                        .rotated(by: t * piece.spin * 2 * .pi)
                    let strip = Path(
                        roundedRect: CGRect(
                            x: -piece.width / 2,
                            y: -piece.height / 2,
                            width: piece.width,
                            height: piece.height
                        ),
                        cornerRadius: piece.width * 0.25
                    ).applying(transform)
                    context.fill(strip, with: .color(piece.color.opacity(alpha)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 中央庆祝文案

/// 今日清空的中央庆祝文案。复用 Toast 的视觉语言(白底圆角卡 + 阴影 + 图标 + 正文),
/// 但居中浮现、独立成件 —— 不动共享 ToastModifier 的 top/bottom 通道。
struct CelebrationBannerView: View {
    let message: String

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            ZStack {
                Circle()
                    .fill(WarmTheme.success.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(WarmTheme.success)
                    .font(.system(size: 18))
            }

            Text(message)
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textPrimary)
                // 文案短(一行),按项目文本布局规则 lineLimit 必配 minimumScaleFactor。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.sheet)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowMedium, radius: 16, x: 0, y: 8)
        )
        .padding(.horizontal, WarmSpacing.md)
    }
}

// MARK: - 确定性随机

/// SplitMix64 确定性伪随机:同 seed 同序列,让粒子/彩带参数在创建时一次定死,
/// Canvas 逐帧渲染成为纯时间函数(无每帧可变状态,连点多实例天然无冲突)。
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// 从 UUID 折叠出种子(uuid_t 是元组不能下标,取 uuidString 的 UTF-8 逐字节混入;
    /// 目的只是「单次实例内确定」,跨启动稳定性无要求)。
    init(id: UUID) {
        var seed: UInt64 = 0
        for byte in id.uuidString.utf8 {
            seed = seed &* 31 &+ UInt64(byte)
        }
        state = seed
    }

    /// 便捷:从一个全新随机 UUID 产生随机种子。
    /// 用于「单次实例内确定、跨实例随机」的粒子/彩带参数生成。
    static func randomSeed() -> UInt64 {
        var generator = SeededRandom(id: UUID())
        return generator.next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EF
        return z ^ (z >> 31)
    }

    /// [0, 1) 均匀分布(取高 53 位,保证 Double 精度内严格小于 1)。
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// [lo, hi] 均匀分布。
    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + unit() * (hi - lo)
    }

    /// [lo, hi] 闭区间整数(unit() 严格小于 1 → 加一取整不会越过 hi)。
    mutating func intRange(_ lo: Int, _ hi: Int) -> Int {
        lo + Int(unit() * Double(hi - lo + 1))
    }
}
