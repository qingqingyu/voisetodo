import Foundation
import SwiftData

/// ServiceContainer 的 VoiceTodo 扩展
/// 提供具体服务的注册方法
extension ServiceContainer {
    /// 注册 VoiceTodo 的所有服务
    /// - Parameter modelContext: SwiftData ModelContext
    @MainActor
    func registerVoiceTodoServices(modelContext: ModelContext) {
        // 注册 VoiceInputManager
        register(VoiceInputManager.self, service: VoiceInputManager())

        // 注册 TodoExtractorService
        register(TodoExtractorService.self, service: TodoExtractorService())

        // 注册 TodoStore
        register(TodoStore.self, service: TodoStore(modelContext: modelContext))

        // 注册 NetworkMonitor
        register(NetworkMonitor.self, service: NetworkMonitor.shared)
    }
}
