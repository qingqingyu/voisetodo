import SwiftUI

/// 数字「弹一下」的通用 modifier。trigger 变化时,scale 从 1.0 弹到 1.08 再回 1.0,
/// 双阶段写法照抄 `UI/ConfirmSheet/ConfirmSheetAnimations.swift` 中 `PopCount` 的实现:
/// `@State popping` + `Task.sleep` 复位 + `popGeneration` 比对防并发竞写。
///
/// **与 PopCount 的差异**:
/// - PopCount 是「View」,只在 ConfirmSheet 按钮里渲染一个独立 Text;
///   NumberPopModifier 是「ViewModifier」,挂到任意 View 上(这里是 progressBarRow 的数字 Text)。
/// - PopCount 缩放 1.42 + light haptic(emoji pop 风格,要有触觉);
///   NumberPopModifier 缩放 1.08(数字小弹,触觉由调用方在更高层统筹——
///   ConfirmSheet 的 confirmAction 已触发 `.success` 触觉,数字 pop 不再重复)。
/// - PopCount 不 gate;NumberPopModifier 仅在 trigger **递增**时弹(避免左右滑切日
///   total 变化、删除导致 total 减少等场景误触发)。当前调用方传单调递增的 token,
///   行为与旧 `oldValue > 0` gate 等价但语义更通用。
///
/// **Follow-up**:后续可与 PopCount 统一为同一个 modifier(给 trigger/animation/scale
/// 都做参数化)。本次拆开避免影响 PopCount 的现有调用。
struct NumberPopModifier: ViewModifier {
    /// 触发 pop 的值。通常等于 `total` 或 `completed`,变化时弹一下。
    let trigger: Int

    @State private var popping = false
    /// 当前 pop 复位 Task 的标识,用于在快速连续触发时让上一次 Task 提前 no-op。
    /// 用 generation 数字比对:Task 闭包捕获 generation,只有 generation 未变才复位。
    @State private var popGeneration = 0
    /// 持有当前 pop Task 句柄:view 销毁时 SwiftUI 自动 cancel @State Task;
    /// 连续触发时手动 cancel 旧 task,避免旧 task 与新 task 同时写 popping。
    /// Task 类型是 `Task<Void, Error>`(非 Never):Task.sleep 闭包 throwing
    /// (只 throw CancellationError),Failure=Never 编译失败,与项目其他 Task 风格一致。
    @State private var popTask: Task<Void, Error>?

    /// pop 持续时间(从 scale 1.08 复位到 1.0 的等待时长)。
    /// 比 PopCount 的 50ms 略长(1.08 缩放幅度小,50ms 用户感知不到)。
    private static let popResetIntervalNanos: UInt64 = 200_000_000

    func body(content: Content) -> some View {
        content
            .scaleEffect(popping ? 1.08 : 1.0)
            .animation(
                .spring(response: 0.3, dampingFraction: 0.6),
                value: popping
            )
            .onChange(of: trigger) { oldValue, newValue in
                // 仅递增才 pop。当前调用方传单调递增的 confirm token,
                // 每次成功添加 → 弹一下;切日 / 删除等减少场景不会触发。
                // 不再用旧 `oldValue > 0` gate:token 首次 0→1 也该弹
                // (进度条行入场动画在 app 启动时早已播完,不存在撕裂)。
                guard newValue > oldValue else { return }
                triggerPop()
            }
            // 兜底:modifier 所在 view 被移出树(条件分支切换、id() 变化)时,
            // 显式 cancel 挂起的复位 Task,避免旧 Task 醒来后尝试写已销毁 view 的 @State。
            // 当前 progressBarRow 是固定位置挂 modifier,不会触发;此处为防御性写法。
            // 注:ConfirmSheetAnimations.PopCount 当前未做 onDisappear cancel,
            // 因为 PopCount 在 ConfirmSheet 单一稳定位置渲染;NumberPopModifier 是
            // 通用 modifier,可能套到任意位置,故此处比 PopCount 更严。
            .onDisappear {
                popTask?.cancel()
            }
    }

    /// pop 触发:置 true,然后用 Task.sleep 异步复位。
    /// 用 generation 比对避免并发竞写:连续快速触发时,旧 Task 醒来发现 generation
    /// 已变,不再写 popping,让最新一次触发独占复位。
    ///
    /// sleep 仅 throw CancellationError(任务被取消,view 已销毁或新 Task 接管);
    /// 显式 catch 而非 try?,符合项目「错误显式传播」:被取消是预期的无操作路径,
    /// 不掩盖其他错误(sleep 不可能 throw 其他错误)。
    private func triggerPop() {
        popping = true
        popGeneration += 1
        let generation = popGeneration
        popTask?.cancel()
        popTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.popResetIntervalNanos)
            } catch is CancellationError {
                return
            } catch {
                // 不可达:Task.sleep 只 throw CancellationError。但 catch 必须
                // 穷尽(否则闭包整体 throws),与 ConfirmSheetAnimations.PopCount 同理由。
                return
            }
            guard generation == popGeneration else { return }
            popping = false
        }
    }
}

extension View {
    /// 数字弹一下。`trigger` **递增**时,scale 从 1.0 弹到 1.08 再回 1.0;
    /// trigger 减少 / 不变时不触发(避免切日、删除等场景误弹)。
    func numberPop(trigger: Int) -> some View {
        modifier(NumberPopModifier(trigger: trigger))
    }
}
