import SwiftUI
import UIKit

/// 对齐 SwiftUI `DragGesture.Value` 的简化快照,用于在调用点和原生 API 之间无缝替换。
struct DragTranslation: Equatable, Sendable {
    /// 手指落点(相对手势所在 view)。
    let startLocation: CGPoint
    /// 手指抬起点(相对手势所在 view)。
    let location: CGPoint

    /// 起点到终点的位移;`.height < 0` 表示上滑,`.height > 0` 表示下滑。
    var translation: CGSize {
        CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }
}

/// iOS 26 起,SwiftUI 的 `.simultaneousGesture(DragGesture(...))` 在 HStack/ScrollView/List
/// 等容器内**不再可靠触发**(Apple 回归 bug FB18199844)。本类型用 `UIGestureRecognizerRepresentable`
/// 包一个 `UILongPressGestureRecognizer`(minimumPressDuration=0 + allowableMovement=infinity),
/// 通过 delegate 允许与其他手势(按钮点击 / 列表滚动)同时识别,等价于"全局拖拽监听"。
///
/// ## minimumDistance 语义
///
/// 与原生 `DragGesture(minimumDistance:)` 类似:拖拽位移(任一方向)必须达到 `minimumDistance`
/// 才会触发 `onEnded`。但由于底层是 `UILongPressGestureRecognizer`,`.began` 会立即触发
/// (用于记录起点),`minimumDistance` 仅作为 `.ended` 时的位移过滤阈值——位移不足则不调用
/// `onEnded`,等价于"手势未成立"。
///
/// 用法对齐 SwiftUI 原生手势:
/// ```swift
/// .gesture(SimultaneousDragGesture(minimumDistance: 40) { drag in
///     // drag.translation.height 等语义与 DragGesture.Value 一致
/// })
/// ```
struct SimultaneousDragGesture: UIGestureRecognizerRepresentable {
    let minimumDistance: CGFloat
    let onEnded: (DragTranslation) -> Void

    /// 持有手势识别期间的临时状态与回调闭包。
    ///
    /// 生命周期:SwiftUI 管理 `UIView` 的 dealloc,view 释放时其 `gestureRecognizers`
    /// 被置 nil,recognizer 释放后 delegate(即本 Coordinator)随之释放,
    /// `onEnded` 闭包捕获的外部引用也一并释放。不存在循环引用。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var minimumDistance: CGFloat = 0
        var onEnded: ((DragTranslation) -> Void)?
        var startLocation: CGPoint?

        // 关键:允许与 ScrollView / Button 等内置手势同时识别,否则会被它们吞掉。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        // minimumPressDuration = 0:不等长按,手指一落下就跟踪
        recognizer.minimumPressDuration = 0
        // allowableMovement = infinity:手指只要没抬起都算手势内,不因移动距离失效。
        // 不用有限值(如 1000pt)是为了在超大屏 / 多屏连续拖拽场景下不意外失效;
        // delegate 已允许与 ScrollView/Button 同时识别,不会屏蔽系统手势。
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        // SwiftUI 每次重渲染都同步最新配置(闭包可能捕获了新状态)。
        context.coordinator.minimumDistance = minimumDistance
        context.coordinator.onEnded = onEnded
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began:
            // recognizer.view 在手势激活期间不应为 nil(view 持有 recognizer);
            // 若 nil 则说明状态异常,不记录起点以避免后续产生无意义的数据。
            guard let view = recognizer.view else { return }
            coordinator.startLocation = recognizer.location(in: view)
        case .ended:
            defer { coordinator.startLocation = nil }
            guard let start = coordinator.startLocation else { return }
            guard let view = recognizer.view else { return }
            let end = recognizer.location(in: view)
            let translation = CGSize(width: end.x - start.x, height: end.y - start.y)
            let minD = coordinator.minimumDistance
            // minimumDistance 语义对齐 DragGesture:任一方向位移超过阈值才算手势成立。
            // 位移不足则不调用 onEnded,等价于"手势未激活"。
            guard abs(translation.width) >= minD || abs(translation.height) >= minD else { return }
            coordinator.onEnded?(DragTranslation(startLocation: start, location: end))
        case .cancelled, .failed:
            // .cancelled 表示手势被系统中断(如 ScrollView / 系统边缘滑动抢手势),
            // 非用户主动结束——此时用部分位移触发 onEnded 会误切换状态,故只清理起点。
            // .failed 同为终态,也清理起点保持状态机干净(下次 .began 会覆盖,但显式清理更稳)。
            coordinator.startLocation = nil
        default:
            break
        }
    }
}
