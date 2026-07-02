import Foundation
import Combine

/// 监听待办变化，对账式驱动本地通知排程。
/// 订阅 `TodoStore.todos`（增删改/完成/拖排/pending 恢复都汇聚于此），债务收敛到单一入口，
/// 避免在各变更点零散挂钩而漏排/漏销。
@MainActor
final class TodoNotificationSync: ObservableObject {
    private let store: TodoStore
    private let scheduler: NotificationScheduling
    private var cancellables = Set<AnyCancellable>()

    init(store: TodoStore, scheduler: NotificationScheduling) {
        self.store = store
        self.scheduler = scheduler
        // 去抖：批量增删（如确认多条）只触发一次对账。订阅即会带出当前值做首次对账。
        store.$todos
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileNow()
            }
            .store(in: &cancellables)
        // 监听设置变化（含"到点提醒"总开关）：拨动后立即对账（关→清空，开→补排）。
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileNow()
            }
            .store(in: &cancellables)
    }

    /// 立即用当前待办对账通知（生命周期钩子：冷启动、回前台、开关变化）。
    func reconcileNow() {
        let enabled = UserDefaults.standard.object(forKey: NotificationPlanner.enabledDefaultsKey) as? Bool ?? true
        let notifications = NotificationPlanner.plannedNotifications(from: store.todos, now: Date(), enabled: enabled)
        Task { @MainActor in
            await scheduler.reconcile(notifications: notifications)
        }
    }
}
