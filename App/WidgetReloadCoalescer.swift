import Foundation
import WidgetKit

/// Widget timeline reload 去抖合并器。
///
/// iOS 对 `WidgetCenter.reloadAllTimelines()` 有每日预算（约 40–70 次/天），
/// 超限后系统拒绝刷新，widget 显示陈旧数据直到次日。App 前台内的连续操作
/// （批量确认、列表快速勾选、拖拽排序）会在数秒内打出多次 reload，
/// 每次都实打实消耗一次预算——本 actor 把去抖窗口内的多次请求合并为一次。
///
/// 使用范围约定：
/// - **仅用于 App 前台进程内的 UI 驱动调用点**（AppCoordinator / HomeView /
///   HomeSettingsSheet 等）。
/// - Siri / Widget Extension 进程里的 AppIntent **不要用**：这些进程生命周期短，
///   `perform()` 返回后可能立刻挂起，去抖窗口内的 pending reload 会随进程丢失
///   （ToggleTodoIntent 等 Intent 内保留直调是有意的）。
///
/// App 进后台前调用 `flushNow()`，防止挂起吞掉 pending 的 reload。
actor WidgetReloadCoalescer {
    static let shared = WidgetReloadCoalescer()

    /// 去抖窗口（秒）。500ms：用户感知为即时，又能吃掉连点/批量操作的风暴。
    private let window: TimeInterval
    /// 实际执行 reload 的动作。注入以便测试计数，不真打 WidgetCenter。
    private let reload: @Sendable () -> Void

    private var pendingTask: Task<Void, Never>?
    /// 自上次真实 reload 以来合并掉的请求数（日志观测用）。
    private var pendingRequests = 0

    init(
        window: TimeInterval = 0.5,
        reload: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.window = window
        self.reload = reload
    }

    /// 同步上下文(MainActor UI 代码)的便捷入口——内部 hop 到 actor。
    /// 去抖语义下调用顺序无关紧要:窗口内任意一次 schedule 都会重置计时器。
    nonisolated static func scheduleReload() {
        Task { await shared.schedule() }
    }

    /// 同步上下文的立即冲刷入口(App 进后台前调用)。
    nonisolated static func flushPendingReloads() {
        Task { await shared.flushNow() }
    }

    /// 请求一次 widget reload。去抖窗口内重复请求只触发一次。
    func schedule() {
        pendingRequests += 1
        pendingTask?.cancel()
        pendingTask = Task { [window, reload] in
            do {
                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            } catch {
                // 被更新的 schedule()/flushNow() 取消——这正是去抖机制本身，不是错误。
                return
            }
            pendingTask = nil
            let coalesced = pendingRequests
            pendingRequests = 0
            VoiceTodoLog.widget.info("widget.reload.coalesced requests=\(coalesced)")
            reload()
        }
    }

    /// 立即执行 pending 的 reload（若有）。App 进后台前调用，防止挂起丢请求。
    /// 无 pending 时不动作——不白白消耗 reload 预算。
    func flushNow() {
        guard pendingTask != nil else { return }
        pendingTask?.cancel()
        pendingTask = nil
        let coalesced = pendingRequests
        pendingRequests = 0
        VoiceTodoLog.widget.info("widget.reload.flushed requests=\(coalesced)")
        reload()
    }
}
