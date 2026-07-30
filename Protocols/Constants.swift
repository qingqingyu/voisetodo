import Foundation

/// 网络配置
enum NetworkConfig {
    /// API 超时时间（秒）。
    /// 必须 > Worker 上游 timeoutMs（`AIProxy/wrangler.toml` 当前 30s），否则客户端先放弃时
    /// Worker 仍在烧 token（abort 信号经 `worker.js` 传到上游），客户端只看到自己的 -1001
    /// 而拿不到 Worker 的真实错误响应。35s = Worker 30s + 5s 余量(冷启动 + 网络往返)。
    static let apiTimeout: TimeInterval = 35.0
    /// 最大重试次数
    static let retryCount: Int = 2
    /// 指数退避基准间隔（秒）：第 N 次重试等待 base * 2^(N-1) + 抖动
    static let retryBaseInterval: TimeInterval = 1.0
    /// 退避上限（秒）：单次等待不超过此值
    static let retryMaxInterval: TimeInterval = 8.0
    /// 熔断：连续失败达到此阈值后进入冷却
    static let circuitBreakerFailureThreshold: Int = 3
    /// 熔断：冷却窗口时长（秒），窗口内直接失败不打网络
    static let circuitBreakerCooldown: TimeInterval = 30.0
    /// VoiceTodo AI 代理端点（公开 URL，不包含任何 AI 供应商密钥）
    static let proxyEndpoint: String = configuredValue(
        environmentKey: "VOICETODO_AI_PROXY_ENDPOINT",
        infoPlistKey: "VoiceTodoProxyEndpoint"
    ) ?? ""
    /// 可选 App Token。它只是代理侧弱防护标识，不是 AI Key。
    static let proxyAppToken: String? = configuredValue(
        environmentKey: "VOICETODO_AI_PROXY_APP_TOKEN",
        infoPlistKey: "VoiceTodoProxyAppToken"
    )
    /// 匿名设备标识，仅用于代理侧额度限制，不是认证凭证。
    static let proxyDeviceIdentifier: String = {
        let storageKey = "VoiceTodoProxyDeviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: storageKey),
           isConfigured(existing) {
            return existing
        }
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: storageKey)
        return identifier
    }()
    /// 是否启用流式响应（Streaming SSE）
    static let streamingEnabled = true
    /// 离线 pending 批量处理最大并发数
    static let pendingBatchConcurrency = 3
    /// 免费档每日上限（UI 占位 / 本地估算后备；代理 `X-Quota-*` 头优先于此值）。
    /// 与 `AIProxy/wrangler.toml` 的 `DAILY_REQUEST_LIMIT` 对应。
    static let freeDailyLimit: Int = 2
    /// Pro 档每日上限（paywall 对比卡展示用）。与 `AIProxy/wrangler.toml` 的
    /// `PAID_DAILY_LIMIT` 对应。Pro **不是无限**，UI 不得宣称无限。
    /// 订阅后的真实上限以代理返回的 `X-Quota-Limit` 为准。
    static let proDailyLimit: Int = 100

    private static func configuredValue(environmentKey: String, infoPlistKey: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey],
           isConfigured(value) {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
           isConfigured(value) {
            return value
        }
        return nil
    }

    private static func isConfigured(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }
}

/// UI 配置
enum UIConfig {
    /// 成功动画时长
    static let successAnimationDuration: Double = 0.4
    /// Toast 显示时长
    static let toastDuration: Double = 2.0
    /// 删除动画时长
    static let deleteAnimationDuration: Double = 0.28

    /// 屏幕尺寸 fallback:仅当 `UIApplication.shared.connectedScenes` 中
    /// 没有 foregroundActive 的 windowScene 时使用(app 启动早期 / scene 异常)。
    /// 取 iPhone 17 Pro 高度作为合理保守值。
    enum UIScreenFallback {
        static let defaultHeight: CGFloat = 956
    }
}

/// Widget 配置
enum WidgetConfig {
    /// App Group 标识符（供 Widget 读取共享容器）
    static let appGroupIdentifier = "group.com.voicetodo.shared"
    /// 刷新间隔（秒）
    static let refreshInterval: TimeInterval = 1800  // 30 分钟
    /// Widget 勾选后保留完成态的时间，用于 timeline 中间态动画
    static let completionAnimationRetention: TimeInterval = 0.5
    /// Widget 交互失败提示保留时长
    static let interactionErrorRetention: TimeInterval = 60
    /// 中尺寸显示条数
    static let mediumItemCount = 3
    /// 大尺寸显示条数
    static let largeItemCount = 6
    /// 锁屏显示条数
    static let lockscreenItemCount = 2
}
