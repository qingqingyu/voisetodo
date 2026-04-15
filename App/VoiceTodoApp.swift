import SwiftUI
import SwiftData

@main
struct VoiceTodoApp: App {
    // MARK: - SwiftData

    /// SwiftData ModelContainer
    let modelContainer: ModelContainer

    // MARK: - State

    @StateObject private var coordinator: AppCoordinator
    @StateObject private var todoStore: TodoStore
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    /// 标记是否应该自动开始录音（从 Action Button 启动）
    @State private var shouldAutoStartRecording = false

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        let schema = Schema([TodoItem.self])

        // 配置 SwiftData ModelContainer（使用 App Group）
        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                groupContainer: .identifier(AppGroupConfig.identifier)
            )
            container = try ModelContainer(
                for: schema,
                configurations: configuration
            )
        } catch {
            // 降级：使用内存容器，数据不会持久化但 App 能正常启动
            #if DEBUG
            print("Failed to create persistent ModelContainer: \(error). Falling back to in-memory.")
            #endif
            do {
                let fallbackConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
                container = try ModelContainer(
                    for: schema,
                    configurations: fallbackConfig
                )
            } catch {
                fatalError("Failed to create even in-memory ModelContainer: \(error)")
            }
        }
        modelContainer = container

        // 初始化依赖
        let voiceInput = VoiceInputManager()
        let extractor = TodoExtractorService()
        let store = TodoStore(modelContext: container.mainContext)

        // 独立持有 Store（同时共享给 Coordinator 和 HomeView）
        _todoStore = StateObject(wrappedValue: store)

        // 初始化 Coordinator
        _coordinator = StateObject(wrappedValue: AppCoordinator(
            voiceInput: voiceInput,
            extractor: extractor,
            store: store
        ))
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
                // ✅ 处理 URL Scheme（Action Button 触发）
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(permissionManager: permissionManager, hasCompletedOnboarding: $hasCompletedOnboarding)
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
            HomeView(store: todoStore)
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
                // ✅ 当 shouldAutoStartRecording 为 true 时自动开始录音
                .onChange(of: shouldAutoStartRecording) { _, newValue in
                    if newValue {
                        shouldAutoStartRecording = false
                        Task {
                            await coordinator.handleActionButtonLaunch()
                        }
                    }
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
        // Action Button 冷启动场景通过 .onOpenURL 检测
        // 此处仅处理需要启动时执行的逻辑
    }

    /// 处理场景状态变化
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // App 进入前台，重启网络监测并检查待处理项
            NetworkMonitor.shared.restartIfNeeded()
            Task {
                await coordinator.handleAppForeground()
            }
        case .inactive, .background:
            break
        @unknown default:
            break
        }
    }

    // MARK: - URL Scheme Handling

    /// 处理 URL 打开（Action Button 或其他外部调用）
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "voicetodo" else { return }

        switch url.host {
        case "record":
            handleActionButtonLaunch()
        default:
            break
        }
    }

    // MARK: - Action Button Handling

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        // 确保已完成引导
        guard hasCompletedOnboarding else {
            #if DEBUG
            print("Onboarding not completed, skipping auto-record")
            #endif
            return
        }

        // 重新检查当前权限状态（用户可能在系统设置中撤销了权限）
        permissionManager.checkCurrentStatus()

        guard permissionManager.micGranted && permissionManager.speechGranted else {
            #if DEBUG
            print("Permissions not granted, showing toast")
            #endif
            coordinator.showToast(
                message: ErrorMessages.permissionsRequired,
                style: .warning
            )
            return
        }

        // 设置标记，触发自动录音
        // 使用 DispatchQueue 延迟一帧，确保 UI 已准备就绪
        DispatchQueue.main.async {
            shouldAutoStartRecording = true
        }
    }
}

// MARK: - AppCoordinator Toast Extension

extension AppCoordinator {
    /// 显示 Toast 提示（供外部调用）
    func showToast(message: String, style: ToastStyle) {
        toastMessage = message
        toastStyle = style
        showToast = true
    }
}
