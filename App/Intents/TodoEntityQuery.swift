import AppIntents
import Foundation
import SwiftData

/// 让 Siri 能按自然语言解析到具体某条 `TodoEntity`。
///
/// 三条路径:
/// - `entities(for:)`:按 ID 精确取(Shortcuts/Siri 内部传递已知引用)
/// - `suggestedEntities()`:Siri 提示候选(用户没有明确指名时弹出的列表)
/// - `entities(matching:)`:按标题模糊匹配(用户说"完成 [买菜]"时定位"买菜"那条)
///
/// 三条路径都走 `AppGroupModelContainerProvider.readOnly()` + 临时 `ModelContext`。
/// 不走主 App 的 `TodoStore`,因为 AppIntent 可能运行在主 App 之外的进程上下文,
/// 并且主 App 的 `TodoStore` 是 `@MainActor`,无法在 EntityQuery 的 async 上下文里安全调用。
///
/// 注:`entities(matching:)` 是 `EntityQuery` 的可选方法。Siri 解析自然语言到 entity 时
/// 若找到此方法会用它做 string-based 匹配;若没有则回退到 `suggestedEntities()` + 消歧列表。
/// 不需要单独的 `StringQuery` 协议 conformance(iOS 16+ 直接支持此方法签名)。
struct TodoEntityQuery: EntityQuery {
    /// Siri 候选 / snippet 默认拉取的上限。过多会让 Siri 朗读冗长、snippet 渲染卡顿。
    private static let suggestedLimit = 20

    func entities(for identifiers: [UUID]) async throws -> [TodoEntity] {
        guard !identifiers.isEmpty else { return [] }
        let intentID = VoiceTodoLog.makeID("entity-fetch")
        VoiceTodoLog.intent.info("entity.fetch.start id=\(intentID, privacy: .public) count=\(identifiers.count)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.readOnly()
        } catch {
            VoiceTodoLog.intent.error("entity.fetch.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
        let context = ModelContext(container)

        let targetIDs = Set(identifiers)
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { targetIDs.contains($0.id) }
        )
        do {
            let items = try context.fetch(descriptor)
            VoiceTodoLog.intent.info("entity.fetch.success id=\(intentID, privacy: .public) matched=\(items.count)")
            return items.map { TodoEntity(from: $0.toData()) }
        } catch {
            VoiceTodoLog.intent.error("entity.fetch.failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }

    func suggestedEntities() async throws -> [TodoEntity] {
        let intentID = VoiceTodoLog.makeID("entity-suggested")
        VoiceTodoLog.intent.info("entity.suggested.start id=\(intentID, privacy: .public)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.readOnly()
        } catch {
            VoiceTodoLog.intent.error("entity.suggested.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = Self.suggestedLimit
        do {
            let items = try context.fetch(descriptor)
            VoiceTodoLog.intent.info("entity.suggested.success id=\(intentID, privacy: .public) count=\(items.count)")
            return items.map { TodoEntity(from: $0.toData()) }
        } catch {
            VoiceTodoLog.intent.error("entity.suggested.failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }

    func entities(matching string: String) async throws -> [TodoEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        let intentID = VoiceTodoLog.makeID("entity-match")
        VoiceTodoLog.intent.info("entity.match.start id=\(intentID, privacy: .public) queryLen=\(trimmed.count)")

        let container: ModelContainer
        do {
            container = try AppGroupModelContainerProvider.readOnly()
        } catch {
            VoiceTodoLog.intent.error("entity.match.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
        let context = ModelContext(container)

        // #Predicate 的 contains 是大小写敏感的,这里先拉一批未完成候选再在本地做大小写不敏感过滤。
        // 数据库层做 localizedStandardContains 在 SwiftData #Predicate 下行为不稳定 (各后端支持差异),
        // 这里保守走"先 DB 过滤 isCompleted,再内存做标题匹配"。
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = Self.suggestedLimit * 2
        do {
            let items = try context.fetch(descriptor)
            let lowered = trimmed.lowercased()
            let matched = items
                .filter { $0.title.lowercased().contains(lowered) }
                .prefix(Self.suggestedLimit)
                .map { TodoEntity(from: $0.toData()) }
            VoiceTodoLog.intent.info("entity.match.success id=\(intentID, privacy: .public) matched=\(matched.count)")
            return matched
        } catch {
            VoiceTodoLog.intent.error("entity.match.failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }
}
