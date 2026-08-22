import Foundation

/// 复盘「下周三件事」的置顶标记存储(阶段 3,拍板 6)。
///
/// 设计约束(docs/todo-review-flow-design.md §阶段 3 · 第 4 步):
/// - **不动 `TodoItem.sortOrder`**——sortOrder 承载用户手动拖拽序(含 sort_order
///   迁移),复盘改它会破坏用户自排的序。置顶是独立标记,只影响展示层排序。
/// - 存 App Group UserDefaults(与 `PersonalGlossaryStore` / `CorrectionTracker`
///   同范式):量小(最多 3 个 id/次),不值得进 SwiftData 动 schema。
/// - HomeView 消费方式:**读排序比较器**,把 pinned id 浮顶,不写任何 todo 字段。
///
/// 生命周期:置顶在复盘第 4 步确认时写入;用户在首页完成该任务后,调用方可
/// `prune(existingIDs:)` 清掉已消失的 id,防止集合随时间膨胀。
final class ReviewPinningStore {
    static let shared = ReviewPinningStore()
    static let pinnedIDsKey = "VoiceTodoReviewPinnedTodoIDs"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)) {
        self.defaults = defaults
    }

    // MARK: - 读写

    /// 当前置顶的 todo id 集合。defaults 不可用时返回空集(只读路径降级,
    /// 不抛错——置顶是增强,不能阻塞首页渲染)。
    func pinnedIDs() -> Set<UUID> {
        guard let defaults else { return [] }
        return lock.withLock {
            Self.load(from: defaults)
        }
    }

    /// 整体覆写置顶集合(复盘第 4 步确认时调用)。
    /// defaults 不可用时打 warning 日志显式记录,不静默假装成功。
    func setPinned(_ ids: Set<UUID>) {
        guard let defaults else {
            VoiceTodoLog.app.warning("review_pinning.set.failed reason=defaults_unavailable count=\(ids.count)")
            return
        }
        lock.withLock {
            Self.save(ids, to: defaults)
        }
        VoiceTodoLog.app.info("review_pinning.set.success count=\(ids.count)")
    }

    /// 清掉已不存在的 id(如任务被完成/删除后)。防御集合膨胀。
    func prune(existingIDs: Set<UUID>) {
        let current = pinnedIDs()
        let kept = current.intersection(existingIDs)
        if kept != current {
            setPinned(kept)
        }
    }

    // MARK: - 存取实现

    private static func load(from defaults: UserDefaults) -> Set<UUID> {
        guard let data = defaults.data(forKey: pinnedIDsKey) else { return [] }
        do {
            return Set(try JSONDecoder().decode([UUID].self, from: data))
        } catch {
            // 脏数据:显式记日志后按空集处理——置顶丢失可由用户重选,不值得崩溃。
            VoiceTodoLog.app.error("review_pinning.load.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }

    private static func save(_ ids: Set<UUID>, to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(Array(ids))
            defaults.set(data, forKey: pinnedIDsKey)
        } catch {
            VoiceTodoLog.app.error("review_pinning.save.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }
}

// MARK: - 展示层排序(纯函数,单测友好)

/// 置顶浮顶的排序工具。HomeView 侧消费,`TodoItem.sortOrder` 不被触碰(拍板 6)。
enum ReviewPinningSort {
    /// 稳定分区:pinned 的条目浮到前面,组内保持原顺序。
    /// 用于任意 `Identifiable`(id == UUID)序列(如 `[TodoItemData]`)。
    static func pinnedFirst<Item: Identifiable>(_ items: [Item], pinned: Set<UUID>) -> [Item] where Item.ID == UUID {
        pinnedFirst(items, id: \.id, pinned: pinned)
    }

    /// keyPath 形态:供 id 不是 UUID 的包装类型用
    /// (如 `[TodoOccurrenceData]`,其自身 id 是 "todoUUID-date" 复合 String,
    /// 置顶判定要看内层 `\.todo.id`)。
    static func pinnedFirst<Item>(_ items: [Item], id: KeyPath<Item, UUID>, pinned: Set<UUID>) -> [Item] {
        guard !pinned.isEmpty else { return items }
        var head: [Item] = []
        var tail: [Item] = []
        for item in items {
            if pinned.contains(item[keyPath: id]) { head.append(item) } else { tail.append(item) }
        }
        return head + tail
    }

    /// 排序比较器形态(供 `sorted(by:)` 用):pinned 优先,其次调用方自定义次序。
    /// 注意 `sorted(by:)` 非稳定,需要稳定时用 `pinnedFirst(_:)`。
    static func comparator(pinned: Set<UUID>) -> (UUID, UUID) -> Bool {
        { lhs, rhs in
            let l = pinned.contains(lhs)
            let r = pinned.contains(rhs)
            if l != r { return l }
            return false
        }
    }
}
