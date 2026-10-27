import Foundation
import SwiftData

/// Caches SwiftData containers used by Widget and AppIntent App Group access.
enum AppGroupModelContainerProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var readOnlyContainer: ModelContainer?
    nonisolated(unsafe) private static var writableContainer: ModelContainer?

    static func readOnly() throws -> ModelContainer {
        lock.lock()
        defer { lock.unlock() }

        if let readOnlyContainer {
            VoiceTodoLog.store.debug("app_group_container.read_only.cache_hit")
            return readOnlyContainer
        }
        VoiceTodoLog.store.info("app_group_container.read_only.create_start")
        let container = try makeContainer(allowsSave: false)
        readOnlyContainer = container
        VoiceTodoLog.store.info("app_group_container.read_only.create_success")
        return container
    }

    static func writable() throws -> ModelContainer {
        lock.lock()
        defer { lock.unlock() }

        if let writableContainer {
            VoiceTodoLog.store.debug("app_group_container.writable.cache_hit")
            return writableContainer
        }
        VoiceTodoLog.store.info("app_group_container.writable.create_start")
        let container = try makeContainer(allowsSave: true)
        writableContainer = container
        VoiceTodoLog.store.info("app_group_container.writable.create_success")
        return container
    }

    private static func makeContainer(allowsSave: Bool) throws -> ModelContainer {
        let schema = VoiceTodoSchema.schema
        // 显式关闭 iCloud 同步:现有 schema 含 .unique 等 CloudKit 不支持的约束,开同步前须先走 V2 迁移(见 docs/swiftdata-schema-v1-baseline.md)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: allowsSave,
            groupContainer: .identifier(AppGroupConfig.identifier),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
