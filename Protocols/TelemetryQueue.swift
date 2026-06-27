import Foundation

/// 遥测事件的持久化载体。发送给 AIProxy 的载荷即此结构的 JSON 编码。
struct TelemetryPayload: Codable, Equatable {
    let name: String
    let timestamp: Date
    let sessionID: String
    let deviceID: String
    let appVersion: String
    let iosVersion: String
    let params: [String: String]
}

/// 遥测事件队列。存储在 App Group UserDefaults 中，跨主 App / Widget Extension / AppIntent 共享。
///
/// - Note: 同进程内用串行队列保护 read-modify-write；跨进程依赖 UserDefaults 的原子 set
///   （last-write-wins），极端并发下可能丢失少量事件，可接受。
enum TelemetryQueue {
    /// 队列持久化 key。
    static let queueKey = "VoiceTodoTelemetryQueue"

    /// 队列容量上限，超出丢老的。
    static let maxQueueSize = 500

    /// 单个事件最大保留时长，超出 GC 清理。
    static let maxAge: TimeInterval = 7 * 24 * 3600  // 7 天

    /// 单批上报最大事件数（与 AIProxy `/v1/telemetry/events` 协议对齐）。
    static let maxBatchSize = 100

    private static let lock = DispatchQueue(label: "VoiceTodo.TelemetryQueue")

    /// 返回 App Group 共享 UserDefaults。值与 `AppGroupConfig.identifier` / `WidgetConfig.appGroupIdentifier` 一致。
    /// 直接用 WidgetConfig 避免依赖 Store/ 模块（SPM Protocols 包限制）。
    private static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)
    }

    // MARK: - Private 核心（始终编译，不可进 #if DEBUG）
    // 生产便捷方法与 DEBUG 测试 seam 都转调这里的下划线核心，算法与原 defaults: 版完全一致。

    private static func _enqueue(_ payload: TelemetryPayload, defaults: UserDefaults?, now: Date = Date()) {
        lock.sync {
            var items = load(defaults: defaults)
            items.append(payload)
            trim(&items, now: now)
            save(items, defaults: defaults)
        }
    }

    private static func _drain(defaults: UserDefaults?, now: Date = Date()) -> [TelemetryPayload] {
        lock.sync {
            let items = load(defaults: defaults)
            save([], defaults: defaults)
            return items
        }
    }

    private static func _restore(_ items: [TelemetryPayload], defaults: UserDefaults?, now: Date = Date()) {
        guard !items.isEmpty else { return }
        lock.sync {
            var current = load(defaults: defaults)
            current.append(contentsOf: items)
            trim(&current, now: now)
            save(current, defaults: defaults)
        }
    }

    private static func _peek(defaults: UserDefaults?) -> [TelemetryPayload] {
        lock.sync { load(defaults: defaults) }
    }

    private static func _count(defaults: UserDefaults?) -> Int {
        lock.sync { load(defaults: defaults).count }
    }

    private static func _gc(defaults: UserDefaults?, now: Date = Date()) {
        lock.sync {
            var items = load(defaults: defaults)
            trim(&items, now: now)
            save(items, defaults: defaults)
        }
    }

    private static func _clear(defaults: UserDefaults?) {
        lock.sync { save([], defaults: defaults) }
    }

    // MARK: - Public（生产 API，默认使用 sharedDefaults()）
    // 对外生产表面仅这 4 个：enqueue / drain / restore / count。

    /// 入队一个事件。会顺带做容量裁剪和过期 GC，保证队列不无限增长。
    static func enqueue(_ payload: TelemetryPayload, now: Date = Date()) {
        _enqueue(payload, defaults: sharedDefaults(), now: now)
    }

    /// 取出全部事件并清空队列。调用方需在上报失败时手动 `restore(_:)` 回滚。
    static func drain(now: Date = Date()) -> [TelemetryPayload] {
        _drain(defaults: sharedDefaults(), now: now)
    }

    /// 把上传失败的事件放回队列。成功时不调用。空数组为 no-op。
    static func restore(_ items: [TelemetryPayload], now: Date = Date()) {
        _restore(items, defaults: sharedDefaults(), now: now)
    }

    /// 当前队列长度。
    static func count() -> Int {
        _count(defaults: sharedDefaults())
    }

    // MARK: - 测试 seam（注入隔离 UserDefaults）
    // 此组方法仅供 @testable 测试访问，Release 配置编译缺席。
    // 若以 Release 跑测试，TelemetryTests 将编译不过（预期取舍，因 swift test / Xcode 测试默认走 Debug）。
#if DEBUG
    /// 入队一个事件到指定 UserDefaults。测试用。
    static func enqueue(_ payload: TelemetryPayload, defaults: UserDefaults?, now: Date = Date()) {
        _enqueue(payload, defaults: defaults, now: now)
    }

    /// 取出并清空指定 defaults 中的队列。测试用。
    static func drain(defaults: UserDefaults?, now: Date = Date()) -> [TelemetryPayload] {
        _drain(defaults: defaults, now: now)
    }

    /// 把上传失败的事件放回指定 defaults。测试用。
    static func restore(_ items: [TelemetryPayload], defaults: UserDefaults?, now: Date = Date()) {
        _restore(items, defaults: defaults, now: now)
    }

    /// 查看指定 defaults 中的队列。测试用。
    static func peek(defaults: UserDefaults?) -> [TelemetryPayload] {
        _peek(defaults: defaults)
    }

    /// 查询指定 defaults 中队列长度。测试用。
    static func count(defaults: UserDefaults?) -> Int {
        _count(defaults: defaults)
    }

    /// 手动 GC 指定 defaults。测试用。
    static func gc(defaults: UserDefaults?, now: Date = Date()) {
        _gc(defaults: defaults, now: now)
    }

    /// 清空指定 defaults 中的队列。测试用。
    static func clear(defaults: UserDefaults?) {
        _clear(defaults: defaults)
    }
#endif

    // MARK: - Private

    /// 容量裁剪 + 过期清理。原地修改。
    private static func trim(_ items: inout [TelemetryPayload], now: Date) {
        let cutoff = now.addingTimeInterval(-maxAge)
        items.removeAll { $0.timestamp < cutoff }
        if items.count > maxQueueSize {
            items.removeFirst(items.count - maxQueueSize)
        }
    }

    /// 从 UserDefaults 读出当前队列。解码失败返回空（容错）。
    private static func load(defaults: UserDefaults?) -> [TelemetryPayload] {
        guard let defaults,
              let data = defaults.data(forKey: queueKey) else {
            return []
        }
        return (try? JSONDecoder().decode([TelemetryPayload].self, from: data)) ?? []
    }

    /// 把队列写回 UserDefaults。defaults 不可用时打日志，不静默吞。
    private static func save(_ items: [TelemetryPayload], defaults: UserDefaults?) {
        guard let defaults else {
            VoiceTodoLog.app.warning("telemetry.queue.save_failed reason=defaults_unavailable items=\(items.count)")
            return
        }
        guard let data = try? JSONEncoder().encode(items) else {
            VoiceTodoLog.app.error("telemetry.queue.encode_failed items=\(items.count)")
            return
        }
        defaults.set(data, forKey: queueKey)
    }
}
