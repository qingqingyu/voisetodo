import Foundation

/// 网络配置
enum NetworkConfig {
    /// API 超时时间（秒）
    static let apiTimeout: TimeInterval = 15.0
    /// 重试次数
    static let retryCount: Int = 1
    /// 重试间隔（秒）
    static let retryInterval: TimeInterval = 2.0
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
    /// 小尺寸显示条数
    static let smallItemCount = 1
    /// 中尺寸显示条数
    static let mediumItemCount = 3
    /// 大尺寸显示条数
    static let largeItemCount = 6
    /// 锁屏显示条数
    static let lockscreenItemCount = 2
}
