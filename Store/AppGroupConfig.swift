import Foundation

/// App Group 配置
enum AppGroupConfig {
    /// App Group 标识符
    static let identifier = "group.com.voicetodo.shared"

    /// Widget/AppIntent 写入后用于提示主 App 刷新的共享版本号
    static let externalChangeVersionKey = "VoiceTodoExternalChangeVersion"
    private static let widgetInteractionErrorTimestampKey = "VoiceTodoWidgetInteractionErrorTimestamp"
    private static let widgetInteractionErrorOperationKey = "VoiceTodoWidgetInteractionErrorOperation"
    private static let widgetInteractionErrorTodoIDKey = "VoiceTodoWidgetInteractionErrorTodoID"
    private static let widgetInteractionErrorMessageKey = "VoiceTodoWidgetInteractionErrorMessage"

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
        guard let defaults = sharedDefaults() else {
            VoiceTodoLog.widget.warning("app_group.defaults_unavailable kind=markExternalDataChanged identifier=\(identifier, privacy: .public)")
            return
        }
        defaults.set(date.timeIntervalSince1970, forKey: externalChangeVersionKey)
    }

    /// 记录最近一次 Widget/AppIntent 交互失败，用于 Widget timeline 展示短提示。
    static func recordWidgetInteractionError(
        operation: WidgetInteractionOperation,
        todoID: UUID,
        messageKey: String = WidgetInteractionError.defaultMessageKey,
        date: Date = Date()
    ) {
        guard let defaults = sharedDefaults() else {
            VoiceTodoLog.widget.warning("app_group.defaults_unavailable kind=recordWidgetInteractionError identifier=\(identifier, privacy: .public) operation=\(operation.rawValue, privacy: .public) todoID=\(todoID.uuidString, privacy: .public)")
            return
        }
        recordWidgetInteractionError(
            operation: operation,
            todoID: todoID,
            messageKey: messageKey,
            date: date,
            defaults: defaults
        )
    }

    /// 记录最近一次 Widget/AppIntent 交互失败到指定 defaults，便于测试。
    static func recordWidgetInteractionError(
        operation: WidgetInteractionOperation,
        todoID: UUID,
        messageKey: String = WidgetInteractionError.defaultMessageKey,
        date: Date = Date(),
        defaults: UserDefaults
    ) {
        defaults.set(date.timeIntervalSince1970, forKey: widgetInteractionErrorTimestampKey)
        defaults.set(operation.rawValue, forKey: widgetInteractionErrorOperationKey)
        defaults.set(todoID.uuidString, forKey: widgetInteractionErrorTodoIDKey)
        defaults.set(messageKey, forKey: widgetInteractionErrorMessageKey)
    }

    /// 清除最近一次 Widget/AppIntent 交互失败提示。
    static func clearWidgetInteractionError() {
        guard let defaults = sharedDefaults() else {
            VoiceTodoLog.widget.warning("app_group.defaults_unavailable kind=clearWidgetInteractionError identifier=\(identifier, privacy: .public)")
            return
        }
        clearWidgetInteractionError(defaults: defaults)
    }

    /// 清除指定 defaults 中最近一次 Widget/AppIntent 交互失败提示，便于测试。
    static func clearWidgetInteractionError(defaults: UserDefaults) {
        defaults.removeObject(forKey: widgetInteractionErrorTimestampKey)
        defaults.removeObject(forKey: widgetInteractionErrorOperationKey)
        defaults.removeObject(forKey: widgetInteractionErrorTodoIDKey)
        defaults.removeObject(forKey: widgetInteractionErrorMessageKey)
    }

    /// 读取仍处于有效期内的 Widget/AppIntent 交互失败提示。
    static func currentWidgetInteractionError(
        now: Date = Date(),
        retention: TimeInterval = WidgetConfig.interactionErrorRetention
    ) -> WidgetInteractionError? {
        guard let defaults = sharedDefaults() else {
            VoiceTodoLog.widget.warning("app_group.defaults_unavailable kind=currentWidgetInteractionError identifier=\(identifier, privacy: .public)")
            return nil
        }
        return widgetInteractionError(from: defaults, now: now, retention: retention)
    }

    /// 读取指定 defaults 中仍处于有效期内的 Widget/AppIntent 交互失败提示。
    static func widgetInteractionError(
        from defaults: UserDefaults,
        now: Date = Date(),
        retention: TimeInterval = WidgetConfig.interactionErrorRetention
    ) -> WidgetInteractionError? {
        let timestamp = defaults.double(forKey: widgetInteractionErrorTimestampKey)
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        guard now.timeIntervalSince(date) <= retention else { return nil }
        guard let rawOperation = defaults.string(forKey: widgetInteractionErrorOperationKey),
              let operation = WidgetInteractionOperation(rawValue: rawOperation),
              let rawTodoID = defaults.string(forKey: widgetInteractionErrorTodoIDKey),
              let todoID = UUID(uuidString: rawTodoID) else {
            return nil
        }
        return WidgetInteractionError(
            timestamp: date,
            operation: operation,
            todoID: todoID,
            messageKey: defaults.string(forKey: widgetInteractionErrorMessageKey) ?? WidgetInteractionError.defaultMessageKey
        )
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

/// Widget 交互类型。
enum WidgetInteractionOperation: String, Equatable {
    case toggleTodo
}

/// Widget 交互失败提示。
struct WidgetInteractionError: Equatable {
    static let defaultMessageKey = "widget.update_failed"

    let timestamp: Date
    let operation: WidgetInteractionOperation
    let todoID: UUID
    let messageKey: String

    var expiresAt: Date {
        timestamp.addingTimeInterval(WidgetConfig.interactionErrorRetention)
    }
}
