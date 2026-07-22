import SwiftUI
import UIKit

/// 观察 app 内 drag-and-drop session 的开始/结束,通过 `UIDropInteraction` 实现。
///
/// **为什么用 UIKit 不用 SwiftUI**:SwiftUI 的 `.draggable` / `.dropDestination` 不暴露
/// 全局 session 生命周期回调。`.dropDestination isTargeted:` 只在 drag 悬停**特定目标**时
/// 触发,无法回答"现在是否有 drag 在进行"。`UIDropInteraction` 的 `sessionDidEnter:` /
/// `sessionDidEnd:` 是 iOS 17+ 唯一可靠的"drag 开始/结束"信号。
///
/// **iOS 26+ 替代方案**:`onDragSessionUpdated(_:)` 给原生 `DragSession.phase`
/// (`.began`/`.changed`/`.ended`),但它挂在 drag **源**上,不是全局观察者。
/// 本 app 范围 iOS 17+,继续用 UIKit bridge。
///
/// **用法**:作为全屏透明 overlay 挂在最顶层,`.allowsHitTesting(false)` 让 tracker
/// 不消费 touch(UIDropInteraction 本身只观察 drop session,不拦截 touch;加这个
/// modifier 是为了 SwiftUI 渲染层的命中测试也跳过它)。
///
/// **关键契约**:
/// - `sessionDidEnter` → `onSessionBegan` (overlay 应该显示)
/// - `sessionDidEnd` → `onSessionEnded` (overlay 应该隐藏;**drop 或 cancel 都触发**)
/// - `sessionDidUpdate` 返回 `.cancel` proposal,不消费 drop,让 SwiftUI `.dropDestination` 接管
///
/// **已知限制**:SwiftUI List 内部会吞掉父级 `UIDropInteraction`(Douglas Hill 2024 发现)。
/// VoiceTodo 的 Calendar tab timeline 用 ScrollView 不用 List,不受影响;Today tab
/// 用 List 但不挂 tracker(只有 Calendar tab 需要观察 task drag)。
///
/// **参考**:
/// - [UIDropInteractionDelegate — Apple Developer](https://developer.apple.com/documentation/uikit/uidropinteractiondelegate)
/// - [Drop doesn't work over List — Douglas Hill](https://douglashill.co/2024/drop-doesnt-work-over-list/)
struct DragSessionTracker: UIViewRepresentable {
    let onSessionBegan: () -> Void
    let onSessionEnded: () -> Void

    func makeUIView(context: Context) -> TrackerView {
        let view = TrackerView()
        // UIDropInteraction 持有 delegate(coordinator);view 持有 interaction。
        // 生命周期由 SwiftUI 管理:makeUIView 创建一次,updateUIView 仅同步闭包。
        let interaction = UIDropInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: TrackerView, context: Context) {
        // SwiftUI 重渲染时同步最新闭包(可能捕获了新状态)。
        context.coordinator.onBegan = onSessionBegan
        context.coordinator.onEnded = onSessionEnded
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 空 UIView,只为挂 `UIDropInteraction`。无视觉、无命中测试(touch 走它下面的 SwiftUI 内容)。
    final class TrackerView: UIView {
        // isAccessibilityElement 默认 false,不需要给 VoiceOver 暴露任何东西。
        // frame 由 SwiftUI overlay 容器决定,此处不设约束。
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var onBegan: () -> Void = {}
        var onEnded: () -> Void = {}

        /// 只接受能提供 String(NSString)payload 的 session —— 即 `.draggable(id.uuidString)`。
        /// 过滤掉非任务卡片的 drag(理论上 app 内不存在,但防御性兜底)。
        func dropInteraction(
            _ interaction: UIDropInteraction,
            canHandle session: UIDropSession
        ) -> Bool {
            session.canLoadObjects(ofClass: NSString.self)
        }

        /// Drag 进入 tracker view 范围(全屏)→ 派发 began。
        /// 实际触发时机:drag 从 `.draggable` source lift 起,session 一进入 app 窗口即派发。
        /// 异步到 main run loop,避免在 UIKit gesture 回调里同步改 SwiftUI state 引起 SwiftUI
        /// render-while-updating 崩溃。
        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidEnter session: UIDropSession
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.onBegan()
            }
        }

        /// 返回 `.cancel`:tracker **不消费** drop,让其他 `UIDropInteraction`(SwiftUI
        /// `.dropDestination` 内部就是)接管实际落点。返回 `.forbidden` 会硬禁止 propagation,
        /// 会破坏 SwiftUI dropDestination 的命中 —— 不要用。
        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            UIDropProposal(operation: .cancel)
        }

        /// Session 结束(drop 或 cancel 都触发)→ 派发 ended。
        /// 这是 iOS 17+ 唯一可靠的"drag 真正结束"信号;`sessionDidExit:` 只表示离开了
        /// tracker view 的 frame,drag 可能还在继续(用户拖出 app 边界或挪到其他 view)。
        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidEnd session: UIDropSession
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.onEnded()
            }
        }
    }
}
