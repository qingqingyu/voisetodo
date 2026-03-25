import SwiftUI
import SwiftData

@main
struct VoiceTodoApp: App {
    // MARK: - SwiftData

    /// SwiftData ModelContainer
    let modelContainer: ModelContainer

    // MARK: - State

    @StateObject private var coordinator: AppCoordinator
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        // 配置 SwiftData ModelContainer（使用 App Group）
        do {
            let schema = Schema([TodoItem.self])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                groupContainer: .identifier("group.com.voicetodo.shared")
            )
            let container = try ModelContainer(
                for: schema,
                configurations: configuration
            )
            modelContainer = container

            // 初始化依赖
            let voiceInput = VoiceInputManager()
            let extractor = TodoExtractorService()
            let store = TodoStore(modelContext: container.mainContext)

            // 初始化 Coordinator
            _coordinator = StateObject(wrappedValue: AppCoordinator(
                voiceInput: voiceInput,
                extractor: extractor,
                store: store
            ))
        } catch {
            // 初始化失败 - 使用内存容器作为后备
            fatalError("Failed to initialize VoiceTodo: \(error)")
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            mainView
                .onAppear {
                    handleAppLaunch()
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(newPhase)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                        .interactiveDismissDisabled()
                }
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Main View

    @ViewBuilder
    private var mainView: some View {
        if hasCompletedOnboarding {
            // 已完成引导，显示主界面
            HomeView(store: TodoStore(modelContext: modelContainer.mainContext))
                .environmentObject(coordinator)
                .toast(
                    message: coordinator.toastMessage,
                    style: coordinator.toastStyle,
                    isPresented: $coordinator.showToast
                )
                .sheet(isPresented: $coordinator.showConfirmSheet) {
                    ConfirmSheetView(
                        transcript: coordinator.transcript,
                        todos: $coordinator.extractedTodos,
                        onConfirm: { todos in
                            coordinator.confirmTodos(todos)
                        },
                        onCancel: {
                            coordinator.cancelTodos()
                        }
                    )
                }
        } else {
            // 未完成引导，显示占位（引导会通过 sheet 显示）
            Color.clear
                .onAppear {
                    showOnboarding = true
                }
        }
    }

    // MARK: - Lifecycle Handling

    /// 处理 App 启动
    private func handleAppLaunch() {
        // 检查是否从 Action Button 启动
        if isLaunchedFromActionButton() {
            handleActionButtonLaunch()
        }
    }

    /// 处理场景状态变化
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // App 进入前台，检查待处理项
            Task {
                await coordinator.handleAppForeground()
            }
        case .inactive, .background:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Action Button Handling

    /// 检查是否从 Action Button 启动
    private func isLaunchedFromActionButton() -> Bool {
        // V1: 简单判断，Action Button 启动时会快速进入录音模式
        // 实际可以通过 launch options 判断
        // 未来可以通过 URL Scheme 或 User Activity 判断
        return false
    }

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        guard hasCompletedOnboarding else { return }

        Task {
            await coordinator.handleActionButtonLaunch()
        }
    }
}
