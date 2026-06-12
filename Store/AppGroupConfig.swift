import Foundation

/// App Group 配置
enum AppGroupConfig {
    /// App Group 标识符
    static let identifier = "group.com.voicetodo.shared"

    /// Widget/AppIntent 写入后用于提示主 App 刷新的共享版本号
    static let externalChangeVersionKey = "VoiceTodoExternalChangeVersion"

    /// 共享容器 URL
    /// - Returns: App Group 共享容器路径
    /// P1 修复: 返回 Optional 而不是 fatalError
    static var sharedContainerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// App Group 共享 UserDefaults
    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// 当前外部写入版本号
    static func currentExternalChangeVersion() -> Double {
        sharedDefaults()?.double(forKey: externalChangeVersionKey) ?? 0
    }

    /// 标记 Widget/AppIntent 已修改共享数据
    static func markExternalDataChanged(date: Date = Date()) {
        sharedDefaults()?.set(date.timeIntervalSince1970, forKey: externalChangeVersionKey)
    }

    /// SwiftData 数据库文件路径
    /// - Returns: 数据库文件完整路径
    /// P1 修复: 返回 Optional 而不是 crash
    static var databaseURL: URL? {
        return sharedContainerURL?.appendingPathComponent("VoiceTodo.sqlite")
    }

    /// 获取共享容器 URL（带错误处理）
    /// - Throws: 如果无法获取容器
    /// - Returns: 共享容器 URL
    static func getSharedContainerURL() throws -> URL {
        guard let url = sharedContainerURL else {
            throw VoiceTodoError.storageReadFailed("无法获取 App Group 容器: \(identifier)")
        }
        return url
    }

    /// 获取数据库 URL（带错误处理）
    /// - Throws: 如果无法获取路径
    /// - Returns: 数据库 URL
    static func getDatabaseURL() throws -> URL {
        guard let url = databaseURL else {
            throw VoiceTodoError.storageReadFailed("无法获取数据库路径")
        }
        return url
    }
}
