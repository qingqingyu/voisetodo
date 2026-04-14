import Foundation
import Security

/// Keychain 辅助工具
/// 用于安全存储敏感信息（如 API Key）
final class KeychainHelper {
    static let shared = KeychainHelper()

    private init() {}

    // MARK: - App Group Access

    /// Keychain 访问组（用于 App Group 内共享，如 Widget Extension）
    private static let accessGroup = "group.com.voicetodo.shared"

    // MARK: - Public Methods

    /// 保存数据到 Keychain
    /// - Parameters:
    ///   - value: 要保存的值
    ///   - key: 键名
    /// - Returns: 是否保存成功
    @discardableResult
    func save(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        // 先删除旧值
        delete(for: key)

        // 创建查询字典
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup
        ]

        // 添加到 Keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从 Keychain 读取数据
    /// - Parameter key: 键名
    /// - Returns: 存储的值（如果存在）
    func get(for key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// 从 Keychain 删除数据
    /// - Parameter key: 键名
    /// - Returns: 是否删除成功
    @discardableResult
    func delete(for key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Keys

    enum Key: String {
        case claudeAPIKey = "com.voicetodo.claude_api_key"
    }
}
