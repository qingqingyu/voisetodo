import Foundation
import Network
import Combine

/// 网络状态监测器
/// 使用 NWPathMonitor 提供实时网络状态监测
@MainActor
final class NetworkMonitor: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isConnected = false
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var connectionType: ConnectionType = .unknown

    // MARK: - Private Properties

    private var monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var cancellables = Set<AnyCancellable>()
    private let uiTestOptions = UITestLaunchOptions.current
    private var lastLoggedState: String?

    // MARK: - Types

    enum ConnectionType: String {
        case wifi = "WiFi"
        case cellular = "Cellular"
        case wired = "Wired"
        case loopback = "Loopback"
        case unknown = "Unknown"
    }

    // MARK: - Initialization

    static let shared = NetworkMonitor()

    private init() {
        startMonitoring()
    }

    // MARK: - Public Methods

    /// 开始监测网络状态
    func startMonitoring() {
        if uiTestOptions.isUITesting {
            isConnected = !uiTestOptions.forceOffline
            isExpensive = false
            isConstrained = false
            connectionType = uiTestOptions.forceOffline ? .unknown : .wifi
            logStateIfChanged(source: "ui_test")
            return
        }

        VoiceTodoLog.network.info("network_monitor.start")
        updateState(from: monitor.currentPath)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                self.updateState(from: path)
            }
        }

        monitor.start(queue: queue)
    }

    /// 停止监测网络状态
    func stopMonitoring() {
        monitor.cancel()
        VoiceTodoLog.network.info("network_monitor.stop")
    }

    /// 重启监测（App 回到前台时调用，确保监测器处于活跃状态）
    func restartIfNeeded() {
        if uiTestOptions.isUITesting {
            VoiceTodoLog.network.info("network_monitor.restart.ui_test")
            startMonitoring()
            return
        }

        // Apple 文档：cancel() 后必须创建新实例，不能重用
        VoiceTodoLog.network.info("network_monitor.restart")
        monitor.cancel()
        monitor = NWPathMonitor()
        startMonitoring()
    }

    /// 检查网络是否可用（异步）
    /// - Returns: 网络是否可用
    func checkNetworkAvailability() async -> Bool {
        return isConnected
    }

    /// 等待网络连接（带超时）
    /// - Parameter timeout: 超时时间（秒）
    /// - Returns: 是否连接成功
    func waitForConnection(timeout: TimeInterval = 10.0) async -> Bool {
        guard !isConnected else {
            VoiceTodoLog.network.debug("network_monitor.wait.skipped reason=already_connected")
            return true
        }

        let startedAt = Date()
        VoiceTodoLog.network.info("network_monitor.wait.start timeoutSeconds=\(timeout)")
        do {
            let connected: Bool = try await withCheckedThrowingContinuation { continuation in
                let wrapper = AsyncContinuationWrapper(continuation)

                // 监听连接状态变化
                let cancellable = $isConnected
                    .filter { $0 }
                    .first()
                    .sink { _ in
                        wrapper.resume(returning: true)
                    }

                // 超时处理
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    wrapper.resume(returning: false)
                    cancellable.cancel()
                }
            }
            if !connected {
                VoiceTodoLog.network.warning("network_monitor.wait.timeout timeoutSeconds=\(timeout) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            }
            VoiceTodoLog.network.info("network_monitor.wait.finished connected=\(connected) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return connected
        } catch {
            VoiceTodoLog.network.error("network_monitor.wait.failed durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return false
        }
    }
}

extension NetworkMonitor {
    private func updateState(from path: NWPath) {
        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wired
        } else if path.usesInterfaceType(.loopback) {
            connectionType = .loopback
        } else {
            connectionType = .unknown
        }
        logStateIfChanged(source: "path_update")
    }

    private func logStateIfChanged(source: String) {
        let state = "connected=\(isConnected) expensive=\(isExpensive) constrained=\(isConstrained) type=\(connectionType.rawValue)"
        guard state != lastLoggedState else { return }
        lastLoggedState = state
        VoiceTodoLog.network.info("network_monitor.state source=\(source, privacy: .public) \(state, privacy: .public)")
    }
}

// MARK: - Convenience Extensions

extension NetworkMonitor {
    /// 网络状态描述
    var statusDescription: String {
        if !isConnected {
            return "无网络连接"
        }

        var description = connectionType.rawValue

        if isExpensive {
            description += " (计费网络)"
        }

        if isConstrained {
            description += " (低数据模式)"
        }

        return description
    }
}

// MARK: - Async Continuation Safety Wrapper

/// 防止 CheckedContinuation 被多次 resume 的包装器
/// 用于 Combine + async/await 桥接场景，确保 continuation 只 resume 一次
private final class AsyncContinuationWrapper<T> {
    private let continuation: CheckedContinuation<T, Error>
    private let lock = NSLock()
    private var hasResumed = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(throwing: error)
    }
}
