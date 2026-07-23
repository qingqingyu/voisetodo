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
///     onChanged: { drag in /* 可选: 跟手反馈 */ },
///     onEnded: { drag in
///         // drag.translation.height / drag.velocity 等语义
///     }
/// ))
/// ```
struct SimultaneousDragGesture: UIGestureRecognizerRepresentable {
    let minimumDistance: CGFloat
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

    /// 显式 init:把 `onEnded` 放在参数列表最后,trailing closure 才能绑定到它
    /// (Swift 规则:单 trailing closure 绑定到最后一个 closure 参数)。
    /// 否则现有调用 `SimultaneousDragGesture(minimumDistance:) { drag in ... }`
    /// 的 trailing closure 会被错误地绑定到 `onChanged`。
    init(
        minimumDistance: CGFloat,
        onEnded: @escaping (DragTranslation) -> Void
    ) {
        self.init(minimumDistance: minimumDistance, onChanged: nil, onEnded: onEnded)
    }

    init(
        minimumDistance: CGFloat,
        onChanged: ((DragTranslation) -> Void)? = nil,
        onEnded: @escaping (DragTranslation) -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        self.minimumDistance = minimumDistance
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onCancelled = onCancelled
    }

    /// 持有手势识别期间的临时状态与回调闭包。
    ///
    /// 生命周期:SwiftUI 管理 `UIView` 的 dealloc,view 释放时其 `gestureRecognizers`
    /// 被置 nil,recognizer 释放后 delegate(即本 Coordinator)随之释放,
    /// `onChanged` / `onEnded` 闭包捕获的外部引用也一并释放。不存在循环引用。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var minimumDistance: CGFloat = 0
        var onChanged: ((DragTranslation) -> Void)?
        var onEnded: ((DragTranslation) -> Void)?
        var onCancelled: (() -> Void)?

        /// 与 Button / List 等内置手势同时识别,避免被它们吞掉。
        ///
        /// **例外**:UIScrollView 的 pan 手势返回 false —— 打破"ScrollView 滚动 + 外层
        /// SimultaneousDragGesture 同时触发"的副作用。场景:HomeSelectedDayListView
        /// 的 List + HomeView.monthHomeView 外层折叠手势;HomeMonthHeaderView 内的
        /// 翻月手势与外层折叠手势共存(方向互斥,不会真同时激活)。
        /// 改为 false 后:ScrollView 内的滑动归 ScrollView;ScrollView 静止 / 滚到边界时
        /// (其 pan 进入 fail/began 状态)外层手势才接管。不影响 Button 点击(非 pan),
        /// 不影响无 ScrollView 容器(HomeMonthHeaderView 翻月手势等)。
        ///
        /// 注意:`is UIScrollView` 含 UIScrollView 所有子类:
        /// `UITextView` / `UITableView` / `UICollectionView` / `WKWebView` 内部 scrollView 等。
        /// 未来若嵌入 TextEditor(UITextView),其滚动+文本选择不会被本手势干扰——
        /// 符合"ScrollView 内的触摸归 ScrollView"的设计意图。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIPanGestureRecognizer,
               otherGestureRecognizer.view is UIScrollView {
                return false
            }
            return true
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
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
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
            guard let view = recognizer.view else { return }
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
            guard abs(translation.x) >= minD || abs(translation.y) >= minD else {
                coordinator.onCancelled?()
                return
            }
            // velocity(in:) 是 UIPanGestureRecognizer 原生的瞬时速度估算(pt/s),
            // 比手动采样差分更稳。转 CGVector 保持 DragTranslation.velocity 语义。
            let v = recognizer.velocity(in: view)
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
            coordinator.onCancelled?()
        default:
            // .began: UIPanGestureRecognizer 位移未达 UIKit 内置阈值(~10pt)时不会进入 .changed;
            // 这里不做任何处理,等 .changed / .ended 携带有效位移后再派发。
            // .possible: 初始态,无数据可派发。
            break
        }
    }
}
