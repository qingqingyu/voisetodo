import Foundation
import SwiftData

/// 服务容器
/// 简单的依赖注入容器，管理应用的所有服务
final class ServiceContainer {
    // MARK: - Singleton

    static let shared = ServiceContainer()

    private init() {}

    // MARK: - Services

    private var services: [String: Any] = [:]
    private let lock = NSLock()

    // MARK: - Registration

    /// 注册服务
    /// - Parameters:
    ///   - type: 服务类型
    ///   - service: 服务实例
    func register<T>(_ type: T.Type, service: T) {
        lock.lock()
        defer { lock.unlock() }

        let key = String(describing: type)
        services[key] = service
    }

    /// 注册服务工厂
    /// - Parameters:
    ///   - type: 服务类型
    ///   - factory: 服务工厂闭包
    func register<T>(_ type: T.Type, factory: @escaping () -> T) {
        lock.lock()
        defer { lock.unlock() }

        let key = String(describing: type)
        services[key] = factory
    }

    // MARK: - Resolution

    /// 解析服务
    /// - Parameter type: 服务类型
    /// - Returns: 服务实例
    func resolve<T>(_ type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }

        let key = String(describing: type)

        if let service = services[key] as? T {
            return service
        } else if let factory = services[key] as? () -> T {
            return factory()
        }

        return nil
    }

    /// 强制解析服务（如果不存在则 crash）
    /// - Parameter type: 服务类型
    /// - Returns: 服务实例
    func resolve<T>(_ type: T.Type) -> T {
        guard let service = resolve(type) else {
            fatalError("Service not registered: \(type)")
        }
        return service
    }

    // MARK: - Convenience Methods

    /// 检查服务是否已注册
    /// - Parameter type: 服务类型
    /// - Returns: 是否已注册
    func isRegistered<T>(_ type: T.Type) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let key = String(describing: type)
        return services[key] != nil
    }

    /// 移除服务
    /// - Parameter type: 服务类型
    func remove<T>(_ type: T.Type) {
        lock.lock()
        defer { lock.unlock() }

        let key = String(describing: type)
        services.removeValue(forKey: key)
    }

    /// 清空所有服务
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        services.removeAll()
    }
}

// MARK: - Property Wrapper

/// 依赖注入属性包装器
@propertyWrapper
struct Injected<T> {
    private var service: T

    var wrappedValue: T {
        return service
    }

    init() {
        guard let service = ServiceContainer.shared.resolve(T.self) else {
            fatalError("Service not registered: \(T.self)")
        }
        self.service = service
    }
}

/// 可选的依赖注入属性包装器
@propertyWrapper
struct OptionalInjected<T> {
    private var service: T?

    var wrappedValue: T? {
        return service
    }

    init() {
        self.service = ServiceContainer.shared.resolve(T.self)
    }
}
