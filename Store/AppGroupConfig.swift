import Foundation

/// App Group 配置
enum AppGroupConfig {
    /// App Group 标识符
    static let identifier = "group.com.voicetodo.shared"

    /// 共享容器 URL
    /// - Returns: App Group 共享容器路径
    /// P1 修复: 返回 Optional 而不是 fatalError
    static var sharedContainerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
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
