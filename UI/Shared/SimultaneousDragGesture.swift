import SwiftUI
import UIKit

/// 对齐 SwiftUI `DragGesture.Value` 的简化快照,用于在调用点和原生 API 之间无缝替换。
struct DragTranslation: Equatable, Sendable {
    /// 手指落点(相对手势所在 view)。
    let startLocation: CGPoint
    /// 当前/最终位置(相对手势所在 view)。
    /// `onChanged` 时是最新采样点,`onEnded` 时是抬手位置。
    let location: CGPoint
    /// 当前瞬时速度(pt/s)。`onChanged` 时是基于最近两次采样的估算速度,
    /// `onEnded` 时是抬手前最后一次估算速度。供调用方做速度感知动画
    /// (如 `.animation(.spring(response:dampingFraction:initialVelocity:))`)
    /// 或快速轻扫阈值判定(位移不足但速度高时仍触发)。`.began` 时无意义,为 .zero。
    let velocity: CGVector

    /// 起点到终点的位移;`.height < 0` 表示上滑,`.height > 0` 表示下滑。
    var translation: CGSize {
        CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }
}

/// iOS 26 起,SwiftUI 的 `.simultaneousGesture(DragGesture(...))` 在 HStack/ScrollView/List
/// 等容器内**不再可靠触发**(Apple 回归 bug FB18199844)。本类型用 `UIGestureRecognizerRepresentable`
/// 包一个 `UIPanGestureRecognizer`,通过 delegate 允许与其他手势(按钮点击 / 列表滚动)同时识别,
/// 等价于"全局拖拽监听"。
///
/// ## 为什么用 UIPanGestureRecognizer 而非 UILongPressGestureRecognizer
///
/// 早期版本用 `UILongPressGestureRecognizer(minimumPressDuration=0, allowableMovement=infinity)`。
/// 问题:minimumPressDuration=0 时,手指一落下立即进入 `.began` 状态——
/// SwiftUI List 的 swipe action 按钮的 tap 事件被 `.began` 状态吞掉
/// (delete 按钮滑得出但点不动,因为 swipe action 按钮不走标准 Button 路径,
/// 而是 List 底层渲染器处理 tap,看到外层 longpress began 就丢弃)。
///
/// 改用 `UIPanGestureRecognizer`:位移达到 UIKit 内置阈值(~10pt)前不 began,
/// tap(位移 < 10pt)不受干扰,swipe action 按钮恢复响应。
///
/// ## minimumDistance 语义
///
/// 与原生 `DragGesture(minimumDistance:)` 类似:拖拽位移(任一方向)必须达到 `minimumDistance`
/// 才会触发 `onEnded`。`UIPanGestureRecognizer` 在 `.ended` 时用 `translation(in:)`
/// 检查累计位移是否达到 `minimumDistance` 阈值,未达到则不调用 `onEnded`。
///
/// 用法对齐 SwiftUI 原生手势:
/// ```swift
/// .gesture(SimultaneousDragGesture(
///     minimumDistance: 40,
///     direction: .vertical,
///     onChanged: { drag in /* 可选: 跟手反馈 */ },
///     onEnded: { drag in
///         // drag.translation.height / drag.velocity 等语义
///     }
/// ))
/// ```
struct SimultaneousDragGesture: UIGestureRecognizerRepresentable {
    /// 方向约束。用于 `gestureRecognizerShouldBegin(_:)` 的进入门槛,
    /// 让本 recognizer 一开始就放弃非匹配方向的触摸,把命中机会让给子视图的同类手势
    /// (例:.vertical 时横滑交给 List 的 swipeActions / 横向滚动条)。
    enum Direction {
        case any
        case vertical
        case horizontal
    }

    let minimumDistance: CGFloat
    let direction: Direction
    /// 拖拽进行中的跟手回调(可选)。位移达到 `minimumDistance` 后才触发——
    /// 避免点击 Button 的微小抖动被误判为拖拽起始。
    /// 默认 nil,调用方不传即不接收跟手事件(向后兼容现有调用点)。
    let onChanged: ((DragTranslation) -> Void)?
    let onEnded: (DragTranslation) -> Void
    /// 手势被系统中断(.cancelled / .failed)时的清理回调(可选)。
    /// 与 onEnded 互斥:同一个手势生命周期内只会派发其中之一。
    /// 必须做的事:复位调用方在 onChanged 里设的临时状态(如 isCollapseGesturing),
    /// 避免下次手势开始时 anchor 捕获基于陈旧状态。
    let onCancelled: (() -> Void)?
    /// 与 UIScrollView pan 冲突时的纯 predicate(可选)。返回 true 允许同时识别,
    /// 覆盖默认"ScrollView 内的滑动归 ScrollView"规则。
    ///
    /// **纯 predicate 契约**:闭包内**不要** mutate ScrollView(不要碰 bounces /
    /// contentOffset)。Coordinator 会基于返回值自动管理 bounces lifecycle:
    ///   - 返回 true 时:记录 `scrollView.bounces` 原值,同步 `bounces = false`
    ///     + `setContentOffset(_:animated:false)` 杀掉 in-flight bounce/decel
    ///   - gesture `.ended` / `.cancelled` / `.failed` 时:恢复原值
    /// 这保证 caller 只写判定逻辑,bookkeeping 由 Coordinator 单一负责,无关注点泄漏。
    ///
    /// **单 ScrollView 跟踪限制**:整个手势生命周期内只跟踪**首个**满足条件的 ScrollView。
    /// 若 view 层级下有多个 ScrollView 同时满足闭包,后续的会被拒绝共存(返回 false)。
    /// 这是因为 restore 只能恢复一个 bounces,跟踪多个会泄漏。当前调用场景(单个 List)无影响。
    ///
    /// 参数:
    /// - scrollView:冲突的 UIScrollView(从 `otherGestureRecognizer.view` 取得)
    /// - pan:对方 pan recognizer,可读 translation/velocity 做方向判定
    let allowSimultaneousWithScrollViewPan: ((UIScrollView, UIPanGestureRecognizer) -> Bool)?

    /// 显式 init:把 `onEnded` 放在参数列表最后,trailing closure 才能绑定到它
    /// (Swift 规则:单 trailing closure 绑定到最后一个 closure 参数)。
    /// 否则现有调用 `SimultaneousDragGesture(minimumDistance:) { drag in ... }`
    /// 的 trailing closure 会被错误地绑定到 `onChanged`。
    init(
        minimumDistance: CGFloat,
        direction: Direction = .any,
        onEnded: @escaping (DragTranslation) -> Void
    ) {
        self.init(
            minimumDistance: minimumDistance,
            direction: direction,
            onChanged: nil,
            onEnded: onEnded,
            onCancelled: nil,
            allowSimultaneousWithScrollViewPan: nil
        )
    }

    init(
        minimumDistance: CGFloat,
        direction: Direction = .any,
        onChanged: ((DragTranslation) -> Void)? = nil,
        onEnded: @escaping (DragTranslation) -> Void,
        onCancelled: (() -> Void)? = nil,
        allowSimultaneousWithScrollViewPan: ((UIScrollView, UIPanGestureRecognizer) -> Bool)? = nil
    ) {
        self.minimumDistance = minimumDistance
        self.direction = direction
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onCancelled = onCancelled
        self.allowSimultaneousWithScrollViewPan = allowSimultaneousWithScrollViewPan
    }

    /// 持有手势识别期间的临时状态与回调闭包。
    ///
    /// 生命周期:SwiftUI 管理 `UIView` 的 dealloc,view 释放时其 `gestureRecognizers`
    /// 被置 nil,recognizer 释放后 delegate(即本 Coordinator)随之释放,
    /// `onChanged` / `onEnded` 闭包捕获的外部引用也一并释放。不存在循环引用。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var minimumDistance: CGFloat = 0
        var direction: Direction = .any
        var onChanged: ((DragTranslation) -> Void)?
        var onEnded: ((DragTranslation) -> Void)?
        var onCancelled: (() -> Void)?
        var allowSimultaneousWithScrollViewPan: ((UIScrollView, UIPanGestureRecognizer) -> Bool)?
        /// 已被外层手势"接管"的 ScrollView。weak 是防御性选择:
        /// 理论上 Coordinator 由 SwiftUI 通过 UIView → gestureRecognizer → delegate 持有,
        /// 不存在直接的 retain cycle(ScrollView 不强引用 Coordinator);但 view tree 重建时
        /// 新旧 coordinator 的生命周期交接没有官方文档保证,weak 在 ScrollView 提前 dealloc
        /// 时让本属性自动 nil,避免悬垂引用。
        weak var trackedScrollView: UIScrollView?
        /// 进入手势时记录的原 bounces 值,gesture 结束时恢复。nil = 当前没有要恢复的。
        var savedBounces: Bool?

        /// Recognizer 进入 `.began` 前的方向门控。
        ///
        /// **为什么需要**:仅靠 `shouldRecognizeSimultaneouslyWith` 返回 false
        /// 只能阻止"共存",但 UIKit 仍要让两个 recognizer 之一进入 `.began`。
        /// 若本 recognizer 比 UIScrollView 的 pan 先到 `.began`(默认场景,因
        /// `UIScrollView.delaysContentTouches=true` 有延迟),UIKit 会强制对方
        /// `.failed` —— 此时横滑想触发 List swipeActions 会被外层吞掉。
        ///
        /// 方向门控把"放弃"提前到 `.began` 之前:非匹配方向的触摸直接返回 false,
        /// 本 recognizer 进入 `.failed`,子视图的 swipeActions / 横向滚动条正常接管。
        ///
        /// **判断时机**:UIKit 在位移足够判定方向后才调 `shouldBegin`(Apple 文档:
        /// "called when a gesture recognizer is about to begin"),此时
        /// `translation(in:)` 已能稳定反映主轴。位移 < 1pt 的极早期回调兜底
        /// 返回 true,让 UIKit 继续观察。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard direction != .any,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view else { return true }
            let t = pan.translation(in: view)
            guard abs(t.x) >= 1 || abs(t.y) >= 1 else { return true }
            switch direction {
            case .any: return true
            case .vertical: return abs(t.y) > abs(t.x)
            case .horizontal: return abs(t.x) > abs(t.y)
            }
        }

        /// 与 Button / List 等内置手势同时识别,避免被它们吞掉。
        ///
        /// **UIScrollView pan 的特殊处理**:默认返回 false —— 打破"ScrollView 滚动 +
        /// 外层 SimultaneousDragGesture 同时触发"的副作用。场景:HomeSelectedDayListView
        /// 的 List + HomeView.monthHomeView 外层折叠手势;HomeMonthHeaderView 内的
        /// 翻月手势与外层折叠手势共存(方向互斥,不会真同时激活)。
        /// 默认 false 后:ScrollView 内的滑动归 ScrollView;ScrollView 静止 / 滚到边界时
        /// (其 pan 进入 fail/began 状态)外层手势才接管。不影响 Button 点击(非 pan),
        /// 不影响无 ScrollView 容器(HomeMonthHeaderView 翻月手势等)。
        ///
        /// **caller 可覆盖**:若 `allowSimultaneousWithScrollViewPan` 闭包存在且返回 true,
        /// 则允许同时识别。这是"List 到顶 + 下滑 → 展开月网格"等边界场景的入口。
        /// 返回 true 时 Coordinator 同步做 bounce 抑制(详见闭包文档):
        ///   - 首次进入记录 `savedBounces`
        ///   - `scrollView.bounces = false` 防 in-flight bounce 继续
        ///   - `scrollView.setContentOffset(_:animated:false)` 杀掉进行中的 bounce/decel
        ///     动画(否则前 10-40pt 的位移被 List bounce 吃掉,外层 onChanged 收不到满量位移)
        /// 恢复在 `handleUIGestureRecognizerAction` 的 `.ended/.cancelled/.failed` 分支。
        ///
        /// 注意:`is UIScrollView` 含 UIScrollView 所有子类:
        /// `UITextView` / `UITableView` / `UICollectionView` / `WKWebView` 内部 scrollView 等。
        /// 未来若嵌入 TextEditor(UITextView),其滚动+文本选择不会被本手势干扰——
        /// 符合"ScrollView 内的触摸归 ScrollView"的设计意图。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if let pan = otherGestureRecognizer as? UIPanGestureRecognizer,
               let scrollView = otherGestureRecognizer.view as? UIScrollView {
                // caller 声明允许共存 → 同步抑制 bounce 并返回 true。
                // 注意:本方法可能被 UIKit 多次调用(每次手势状态变化),且可能对 view 层级下
                // **不同**的 ScrollView 调用(List 内可能嵌套子 ScrollView)。当前实现明确
                // 只跟踪**单个** ScrollView:首次进入记录并抑制;同一 ScrollView 重复调用
                // 跳过 mutate(已生效);不同 ScrollView 出现时返回 false 拒绝共存 ——
                // 因为 restore 只能恢复一个 bounces,跟踪多个会泄漏。
                // 若未来需要多 ScrollView 支持,需改为 [UIScrollView: Bool] 字典 + 逐个 restore。
                //
                // **粘性语义**:一旦 trackedScrollView 被设置,整个手势生命周期内 bounces 保持
                // false,即使后续闭包对同一 ScrollView 返回 false(如 contentOffset 变化导致
                // atTop 不再成立)。恢复只在 gesture 终态(.ended/.cancelled/.failed)发生。
                // 理由:外层手势可能已驱动 collapseProgress,bounces 中途抖动会破坏动画连续性。
                if let allow = allowSimultaneousWithScrollViewPan, allow(scrollView, pan) {
                    if let tracked = trackedScrollView {
                        // 已在跟踪某个 ScrollView:仅当是同一个才允许共存(幂等),否则拒绝。
                        return tracked === scrollView
                    }
                    savedBounces = scrollView.bounces
                    trackedScrollView = scrollView
                    scrollView.bounces = false
                    // 杀 in-flight bounce/decel:用户下滑瞬间 List 可能正在弹性回弹,
                    // 不打断会让前 10-40pt 位移被 bounce 吃掉,外层收不到满量 onChanged。
                    scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                    return true
                }
                return false
            }
            return true
        }

        /// gesture 终态时恢复 ScrollView 的 bounces。必须在派发 `onEnded` / `onCancelled`
        /// **之前**调用:让 List 回到正常 bounce 行为,然后再让 caller 做 collapseProgress
        /// snap 等终态处理;否则 List 在 snap 动画期间仍是 bounces=false,视觉不自然。
        ///
        /// 幂等:trackedScrollView == nil 时直接返回,允许在 .ended/.cancelled/.failed
        /// 三个分支都安全调用(其中两个是 cancel 路径,可能本就没 track 过 ScrollView)。
        ///
        /// weak 变 nil 的时序保证:ScrollView 被 dealloc 前,其 gestureRecognizers 会被
        /// 置 nil → recognizer 进入 .cancelled → 本方法在 cancel 分支被调用清空状态。
        /// 即使极端情况下 dealloc 早于 cancel,savedBounces 末尾仍被置 nil,不会泄漏。
        func restoreTrackedScrollView() {
            if let sv = trackedScrollView, let saved = savedBounces {
                sv.bounces = saved
            }
            trackedScrollView = nil
            savedBounces = nil
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // SwiftUI 每次重渲染都同步最新配置(闭包可能捕获了新状态)。
        context.coordinator.minimumDistance = minimumDistance
        context.coordinator.direction = direction
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.allowSimultaneousWithScrollViewPan = allowSimultaneousWithScrollViewPan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .changed:
            // 跟手回调:位移达到 minimumDistance 才派发——避免点击 Button 的微小抖动被误判为拖拽。
            // 与 .ended 用同一道阈值,保证"开始跟手"与"确认抬手"语义一致。
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let minD = coordinator.minimumDistance
            guard abs(translation.x) >= minD || abs(translation.y) >= minD else { return }
            let location = recognizer.location(in: view)
            let startLocation = CGPoint(
                x: location.x - translation.x,
                y: location.y - translation.y
            )
            let v = recognizer.velocity(in: view)
            coordinator.onChanged?(DragTranslation(
                startLocation: startLocation,
                location: location,
                velocity: CGVector(dx: v.x, dy: v.y)
            ))
        case .ended:
            // recognizer.view 在手势激活期间不应为 nil(view 持有 recognizer);
            // 若 nil 则说明状态异常,不派发回调以避免后续产生无意义的数据。
            guard let view = recognizer.view else {
                coordinator.restoreTrackedScrollView()
                return
            }
            // translation(in:) 返回 CGPoint(.x/.y 是从手指落点到当前点的累计位移);
            // location(in:) 在 .ended 时返回最后触摸位置。
            // 由这两者反推起点,保持 DragTranslation 语义不变。
            let translation = recognizer.translation(in: view)
            let location = recognizer.location(in: view)
            let startLocation = CGPoint(
                x: location.x - translation.x,
                y: location.y - translation.y
            )
            let minD = coordinator.minimumDistance
            // minimumDistance 语义对齐 DragGesture:任一方向位移超过阈值才算手势成立。
            // 位移不足则不调用 onEnded,等价于"手势未激活"。
            // 但若 .changed 已派发过(用户中途达到阈值后又挪回起点附近),onCancelled 必须补发,
            // 否则调用方(如 HomeView 折叠手势)在 onChanged 里设的 isCollapseGesturing 泄漏。
            // 恢复 ScrollView bounces 必须在派发 onCancelled/onEnded 之前:
            // caller 在 onCancel/onEnded 里会做 collapseProgress snap + withAnimation,
            // 动画期间 List 不应仍处于 bounces=false 的"接管"态。
            guard abs(translation.x) >= minD || abs(translation.y) >= minD else {
                coordinator.restoreTrackedScrollView()
                coordinator.onCancelled?()
                return
            }
            // velocity(in:) 是 UIPanGestureRecognizer 原生的瞬时速度估算(pt/s),
            // 比手动采样差分更稳。转 CGVector 保持 DragTranslation.velocity 语义。
            let v = recognizer.velocity(in: view)
            coordinator.restoreTrackedScrollView()
            coordinator.onEnded?(DragTranslation(
                startLocation: startLocation,
                location: location,
                velocity: CGVector(dx: v.x, dy: v.y)
            ))
        case .cancelled, .failed:
            // .cancelled / .failed:手势被系统中断(ScrollView 抢手势 / 系统边缘滑动 / 来电弹窗等),
            // 非用户主动结束。位移不完整,不能拿来 snap 状态,所以不派发 onEnded。
            // 但必须通知调用方清理:否则调用方(如 HomeView 折叠手势)的 isCollapseGesturing
            // 不会被复位,下次拖拽的 anchor 捕获会基于陈旧状态,产生视觉跳跃。
            // 通过 onCancelled 回调显式通知调用方做清理。
            // 恢复 ScrollView bounces 在前(同 .ended 理由)。
            coordinator.restoreTrackedScrollView()
            coordinator.onCancelled?()
        default:
            // .began: UIPanGestureRecognizer 位移未达 UIKit 内置阈值(~10pt)时不会进入 .changed;
            // 这里不做任何处理,等 .changed / .ended 携带有效位移后再派发。
            // .possible: 初始态,无数据可派发。
            break
        }
    }
}
