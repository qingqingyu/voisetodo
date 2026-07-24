import SwiftUI

/// ConfirmSheet 专用的动画 modifier 集合。
/// 文件独立存放:这些 modifier 只在 ConfirmSheet 视图树用,
/// 不污染 UI/Shared 的通用 modifier 库。
///
/// 对齐 jul-redesign.html:
/// - `.emoji` bump:`@keyframes bump` 从 scale(0.4) 弹到 scale(1.0),delay 0.12s
/// - `.count` pop:`@keyframes pop` 从 scale(1.0) → 1.42 → 1.0
enum ConfirmSheetAnimations {
    /// emoji bump delay(秒),对齐 HTML CSS 0.12s。
    static let emojiBumpDelay: Double = 0.12
    /// count pop 触发后回到静止态的间隔(纳秒)。50ms = 50_000_000ns。
    static let popResetInterval: UInt64 = 50_000_000
}

// MARK: - EmojiBumpModifier

/// emoji 入场缩放动画。从 scale 0.4 + opacity 0 弹到 scale 1.0 + opacity 1,
/// delay 0.12s,对齐 HTML `.emoji` 的 `@keyframes bump`。
///
/// 动画由 `.onAppear` 驱动:SwiftUI 在 modifier 附着的 view 首次出现时触发。
/// 若需在 todo 重排时重播,调用方应在 emoji Text 上挂 `.id(todo.id)` 强制重建。
struct EmojiBumpModifier: ViewModifier {
    @State private var bumped = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(bumped ? 1.0 : 0.4)
            .opacity(bumped ? 1.0 : 0)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.55)
                    .delay(ConfirmSheetAnimations.emojiBumpDelay),
                value: bumped
            )
            .onAppear { bumped = true }
    }
}

// MARK: - PopCount

/// Confirm 按钮内的数字。count 变化时 scale 弹一下 + 触发 light haptic,
/// 对齐 HTML `.count.pop` 动画。
///
/// **为什么不用 `.animation(_, value:)` 单动画**:
/// pop 动画需要先放大到 1.42 再回到 1.0,是「双向」过渡;
/// SwiftUI 的隐式 animation 只能在状态间插值,需要手动切 @State 才能模拟关键帧。
struct PopCount: View {
    let count: Int

    @State private var popping = false
    /// 当前 pop 复位 Task 的标识,用于在快速连续触发时让上一次 Task 提前 no-op。
    /// 用 generation 数字比对:Task 闭包捕获 generation,只有 generation 未变才复位。
    @State private var popGeneration = 0
    /// 持有当前 pop Task 句柄:view 销毁时 SwiftUI 自动 cancel @State Task;
    /// 连续触发 triggerPop 时手动 cancel 旧 task,避免旧 task 与新 task 同时写 popping。
    /// 与 TodoItemRow.deleteTask 风格一致。
    ///
    /// Task 类型是 `Task<Void, Error>`(非 Never):Task.sleep 闭包 throwing
    /// (只 throw CancellationError),Failure=Never 编译失败,与 deleteTask 同原因。
    @State private var popTask: Task<Void, Error>?

    var body: some View {
        Text("\(count)")
            .font(WarmFont.captionFixed(13))
            .monospacedDigit()
            .padding(.horizontal, WarmSpacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.white.opacity(0.26))
            )
            .scaleEffect(popping ? 1.0 : 1.42)
            .animation(
                .spring(response: 0.34, dampingFraction: 0.55),
                value: popping
            )
            .onChange(of: count) { _, newValue in
                guard newValue > 0 else { return }
                triggerPop()
            }
    }

    /// pop 触发:置 true + haptic,然后用 Task.sleep 异步复位。
    /// 用 generation 比对避免并发竞写:连续快速触发时,旧 Task 醒来发现 generation
    /// 已变,不再写 popping,让最新一次触发独占复位。
    ///
    /// sleep 仅 throw CancellationError(任务被取消,view 已销毁或新 Task 接管);
    /// 显式 catch 而非 try?,符合项目「错误显式传播」:被取消是预期的无操作路径,
    /// 不掩盖其他错误(sleep 不可能 throw 其他错误)。
    private func triggerPop() {
        popping = true
        HapticFeedback.light()
        popGeneration += 1
        let generation = popGeneration
        popTask?.cancel()
        popTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: ConfirmSheetAnimations.popResetInterval)
            } catch is CancellationError {
                return
            }
            guard generation == popGeneration else { return }
            popping = false
        }
    }
}
