import Foundation

/// 网络配置
enum NetworkConfig {
    /// Worker 侧单个 provider 的上游超时（秒）。镜像 `AIProxy/wrangler.toml` 里
    /// `PROVIDERS[].timeoutMs = 30000`。改一边必须改另一边。
    static let workerProviderTimeout: TimeInterval = 30.0
    /// Worker 侧最多尝试几个 provider。镜像 `AIProxy/wrangler.toml` 的
    /// `AI_PROVIDER_MAX_ATTEMPTS = "2"`（不显式配置时 Worker 取候选全量，会随
    /// provider 数量悄悄变大并击穿下面的预算）。
    static let workerMaxAttempts: Int = 2
    /// 最后一跳的 TTFB 余量 + Worker 自身开销（KV / DO 往返、JWS 验签、isolate 冷启动）。
    static let workerTailAllowance: TimeInterval = 15.0

    /// API 超时时间（秒）。
    ///
    /// ⚠️ 这是 URLSession 的 **timeoutIntervalForRequest** 语义——「字节之间的静默上限」，
    /// 不是总时长上限。所以 55s 不代表 happy path 上用户要等 55 秒：只有 Worker 正在
    /// failover、通道上一个字节都没有的时候它才咬合。
    ///
    /// 下界 = (workerMaxAttempts - 1) × workerProviderTimeout + workerTailAllowance
    ///      = 1 × 30 + 15 = 45s，取 55s 留 10s 余量。
    ///
    /// 旧值 35s 低于这个下界，产生了最隐蔽的一种失效：provider 1 挂到 30s、Worker 正切到
    /// provider 2 且注定会成功，客户端却已经在 35s 放弃，还把 `.apiTimeout` 当成一次服务
    /// 故障喂给熔断器——用户看到降级，服务端日志里却是一次成功的 failover。
    /// `ExtractorTests.testTimeoutBudgetExceedsWorkerFailoverWorstCase` 守着这个不变量。
    static let apiTimeout: TimeInterval = 55.0
    /// 最大重试次数
    static let retryCount: Int = 2
    /// 指数退避基准间隔（秒）：第 N 次重试等待 base * 2^(N-1) + 抖动
    static let retryBaseInterval: TimeInterval = 1.0
    /// 退避上限（秒）：单次等待不超过此值
    static let retryMaxInterval: TimeInterval = 8.0
    /// 熔断：连续失败达到此阈值后进入冷却。
    /// 5 而非 3——与 Worker 侧 `AIProxy/src/health.js` 的 DEFAULT_THRESHOLD 对齐，理由相同：
    /// AI 上游偶发 5xx / 超时是常态。且主路径 `extractStreaming` **没有重试**（重试循环只在
    /// 非流式 `extract()` 里），每次失败都是满权重的，阈值必须相应放宽。
    static let circuitBreakerFailureThreshold: Int = 5
    /// 熔断：冷却窗口时长（秒），窗口内直接失败不打网络。
    /// 30 → 15：客户端熔断器的唯一职责是别猛捶已故障的代理，真正的保护在 Worker 侧
    /// （KV 持久化 + 指数退避到 5 分钟）。客户端每多冷却一秒，就多一秒用户说话被静默降级
    /// 成本地截断，所以取够用的最小值。
    static let circuitBreakerCooldown: TimeInterval = 15.0
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

/// feedback-relay Worker 配置。与 AIProxy 同一个 App,客户端身份校验靠 X-App-Token,
/// 复用 `NetworkConfig.proxyAppToken`,不另开 token。
enum FeedbackConfig {
    /// feedback-relay Worker 的公开端点(不含路径,Worker 自带 `/v1/feedback`)。
    /// 通过 Xcode build setting `VOICETODO_FEEDBACK_ENDPOINT` → Info.plist 注入。
    /// 判空逻辑与 `NetworkConfig.isConfigured` 同源(trim 后判空 + `$(` 占位过滤),
    /// 避免空白字符端点漏过导致 URL 构造成功但请求失败。
    static let endpoint: String = {
        if let env = ProcessInfo.processInfo.environment["VOICETODO_FEEDBACK_ENDPOINT"],
           isConfiguredValue(env) {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "VoiceTodoFeedbackEndpoint") as? String,
           isConfiguredValue(plist) {
            return plist
        }
        return ""
    }()

    private static func isConfiguredValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }
    /// 客户端身份校验 token。沿用 AIProxy 的 APP_TOKEN(同一个 App,同一个客户端)。
    static var appToken: String? { NetworkConfig.proxyAppToken }
    /// 单张截图字节上限。镜像 `feedback-relay/worker.js` 的 MAX_SCREENSHOT_BYTES,
    /// 客户端预先压缩避免 base64 后 body 超限。
    static let maxScreenshotBytes: Int = 3 * 1024 * 1024
    /// transcript 截断字符数。镜像 worker.js 的 MAX_TRANSCRIPT_CHARS,
    /// 客户端预先截断避免 base64 后 body 超限。
    static let maxTranscriptChars: Int = 1000
    /// extractedTodoTitle 截断字符数。镜像 worker.js 的 MAX_TITLE_CHARS。
    static let maxTitleChars: Int = 200
    /// 反馈上传请求超时(秒)。反馈是 best-effort,不需要 AI 提取那样长 failover 预算;
    /// 30s 足够覆盖带 3MB 截图的慢网,也避免用户卡在 ProgressView 旁。
    static let requestTimeout: TimeInterval = 30.0
}

/// 提醒提前量(单条待办"提前 X 分钟提醒")配置。
/// 上限是**跨模块契约**:消毒(Models)、调度钳制(NotificationPlanner)、
/// 落库钳制(TodoStore)、UI 档位(TodoReminderOffsetRow)四层共用。
/// 收敛为单一常量前该值以字面量散落 6 处,调整上限极易漏改造成层间不一致;
/// 现在只改这一处,各层禁止重写字面量。
enum ReminderOffsetConfig {
    /// 最大提前分钟数(= 1 天)。0/负数/超界一律按"准时"(nil)处理。
    static let maxMinutes = 1440

    /// App 级「默认提前提醒」的 UserDefaults 键(标准库;Widget 不读该值)。
    /// 存档位原始 Int:0 = 准时,5/15/30/60/1440 = 提前分钟数。
    static let defaultOffsetDefaultsKey = "todoDefaultReminderOffsetMinutes"

    /// 当前生效的全局默认提前量(nil = 准时)。
    /// 键缺失/0/越界脏值一律降级为准时。只在待办"出生"时读取——
    /// 不影响存量待办,用户改设置不会重排已有通知。
    static func effectiveDefaultOffset(from defaults: UserDefaults = .standard) -> Int? {
        let raw = defaults.integer(forKey: defaultOffsetDefaultsKey)
        return (1...maxMinutes).contains(raw) ? raw : nil
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
    static let lockscreenItemCount = 3
}
