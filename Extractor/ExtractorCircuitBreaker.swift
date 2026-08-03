import Foundation

/// 轻量客户端熔断器。
///
/// 连续失败达到阈值后进入「打开」状态，冷却窗口内 `shouldShortCircuit()` 返回 true，
/// 调用方据此直接失败（不再打网络），避免持续打击已故障的代理。冷却结束后转「半开」，
/// 放行一次探测；探测成功则闭合并清零，失败则重新打开。
///
/// 仅统计「服务类」故障（网络不可用 / 超时 / 服务端错误），不统计限流、配额或解析类错误。
/// **用户主动取消不是故障**——取消的过滤在调用方（`TodoExtractorService.isCancellation`），
/// 熔断器本身不认识 Error 类型，只接受已经分类好的信号。
actor ExtractorCircuitBreaker {
    enum State: Equatable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    /// 状态迁移结果。调用方据此打日志 / 上报遥测，让熔断器本身保持纯函数式、可测。
    enum Transition: Equatable {
        /// 计入失败但未跳闸。
        case counted(consecutiveFailures: Int)
        /// 本次失败触发跳闸。
        case opened(until: Date)
        /// 已在冷却窗口内，不叠加冷却。
        case alreadyOpen
        /// 从非闭合态恢复。
        case closed
        /// 本来就是闭合态，无迁移。
        case noChange
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
    @discardableResult
    func recordSuccess() -> Transition {
        let wasDegraded = state != .closed
        consecutiveFailures = 0
        state = .closed
        return wasDegraded ? .closed : .noChange
    }

    /// 记录一次服务类失败：达到阈值或处于半开探测失败时打开冷却窗口。
    ///
    /// 跳闸时 **必须清零 `consecutiveFailures`**：不清零的话计数永远 >= threshold，
    /// 冷却结束转半开后任意一次失败都会重开一个完整窗口，熔断器退化成单向阀，
    /// 只能靠一次成功或重启进程复位。这是「远端 AI 间歇性失效」的成因之一。
    @discardableResult
    func recordFailure() -> Transition {
        // 已在冷却窗口内（半开期间放行的并发请求刚把它打开）→ 不叠加冷却，
        // 否则 PendingRecoveryFlow 的并发批处理会把一个窗口推成 N 个串行窗口。
        if case .open(let until) = state, now() < until {
            return .alreadyOpen
        }

        consecutiveFailures += 1
        guard state == .halfOpen || consecutiveFailures >= failureThreshold else {
            return .counted(consecutiveFailures: consecutiveFailures)
        }

        let until = now().addingTimeInterval(cooldown)
        state = .open(until: until)
        consecutiveFailures = 0
        return .opened(until: until)
    }

    /// 复位到闭合态。用于 App 回到前台时给远端一次干净的机会——熔断是纯内存态，
    /// 否则用户只能靠等冷却或重启 App 恢复。
    func reset() {
        consecutiveFailures = 0
        state = .closed
    }
}
