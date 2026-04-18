import Foundation

/// 网络配置
enum NetworkConfig {
    /// API 超时时间（秒）
    static let apiTimeout: TimeInterval = 15.0
    /// 重试次数
    static let retryCount: Int = 1
    /// 重试间隔（秒）
    static let retryInterval: TimeInterval = 2.0
    /// Claude 模型名称
    static let claudeModel = "claude-sonnet-4-20250514"
    /// Claude API Endpoint
    static let apiEndpoint = "https://api.anthropic.com/v1/messages"
    /// Anthropic API Version
    static let apiVersion = "2023-06-01"
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
    /// 小尺寸显示条数
    static let smallItemCount = 1
    /// 中尺寸显示条数
    static let mediumItemCount = 3
    /// 大尺寸显示条数
    static let largeItemCount = 6
    /// 锁屏显示条数
    static let lockscreenItemCount = 2
}
