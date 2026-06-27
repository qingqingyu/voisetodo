import Foundation

/// 轻量客户端熔断器。
///
/// 连续失败达到阈值后进入「打开」状态，冷却窗口内 `shouldShortCircuit()` 返回 true，
/// 调用方据此直接失败（不再打网络），避免持续打击已故障的代理。冷却结束后转「半开」，
/// 放行一次探测；探测成功则闭合并清零，失败则重新打开。
///
/// 仅统计「服务类」故障（网络不可用 / 超时 / 限流），不统计解析类错误。
actor ExtractorCircuitBreaker {
    enum State: Equatable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private let now: () -> Date

    private var consecutiveFailures = 0
    private(set) var state: State = .closed

    init(
        failureThreshold: Int = NetworkConfig.circuitBreakerFailureThreshold,
        cooldown: TimeInterval = NetworkConfig.circuitBreakerCooldown,
        now: @escaping () -> Date = { Date() }
    ) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
        self.now = now
    }

    /// 是否应短路（冷却窗口内直接失败）。冷却到期会转入半开并放行。
    func shouldShortCircuit() -> Bool {
        switch state {
        case .closed, .halfOpen:
            return false
        case .open(let until):
            if now() >= until {
                state = .halfOpen
                return false
            }
            return true
        }
    }

    /// 记录一次成功：清零并闭合。
    func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
    }

    /// 记录一次服务类失败：达到阈值或处于半开探测失败时打开冷却窗口。
    func recordFailure() {
        consecutiveFailures += 1
        if state == .halfOpen || consecutiveFailures >= failureThreshold {
            state = .open(until: now().addingTimeInterval(cooldown))
        }
    }
}
