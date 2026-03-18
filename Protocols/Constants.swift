import Foundation

/// 音频配置
enum AudioConfig {
    /// 静音检测阈值（dB），低于此值视为静音
    static let silenceThreshold: Float = -40.0
    /// 连续静音多久后自动停止（秒）
    static let silenceDuration: TimeInterval = 2.0
}

/// 网络配置
enum NetworkConfig {
    /// API 超时时间（秒）
    static let apiTimeout: TimeInterval = 15.0
    /// 重试次数
    static let retryCount: Int = 1
    /// 重试间隔（秒）
    static let retryInterval: TimeInterval = 2.0
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
