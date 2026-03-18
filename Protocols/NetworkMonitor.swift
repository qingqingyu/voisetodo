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

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var cancellables = Set<AnyCancellable>()

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
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }

                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained

                // 判断连接类型
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .wired
                } else if path.usesInterfaceType(.loopback) {
                    self.connectionType = .loopback
                } else {
                    self.connectionType = .unknown
                }
            }
        }

        monitor.start(queue: queue)
    }

    /// 停止监测网络状态
    func stopMonitoring() {
        monitor.cancel()
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
        guard !isConnected else { return true }

        return await withCheckedContinuation { continuation in
            var hasResumed = false

            // 监听连接状态变化
            let cancellable = $isConnected
                .filter { $0 }
                .first()
                .sink { _ in
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(returning: true)
                }

            // 超时处理
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !hasResumed else { return }
                hasResumed = true
                cancellable.cancel()
                continuation.resume(returning: false)
            }
        }
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
