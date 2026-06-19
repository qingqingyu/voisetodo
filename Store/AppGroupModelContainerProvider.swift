import Foundation
import SwiftData

/// Caches SwiftData containers used by Widget and AppIntent App Group access.
enum AppGroupModelContainerProvider {
    nonisolated(unsafe) private static let lock = NSLock()
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
        let schema = Schema([TodoItem.self, TodoOccurrenceCompletion.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: allowsSave,
            groupContainer: .identifier(AppGroupConfig.identifier)
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
