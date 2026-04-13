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

    /// 标记是否应该自动开始录音（从 Action Button 启动）
    @State private var shouldAutoStartRecording = false

    /// Widget 点击跳转状态
    @State private var showTodoDetailFromWidget = false
    @State private var todoFromWidget: TodoItemData?

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Constants

    /// Action Button 触发的 URL Scheme
    private let actionButtonURLScheme = "voicetodo://record"

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
                groupContainer: .identifier("group.com.voicetodo.shared")
            )
            container = try ModelContainer(
                for: schema,
                configurations: configuration
            )
        } catch {
            // 降级：使用内存容器，数据不会持久化但 App 能正常启动
            print("Failed to create persistent ModelContainer: \(error). Falling back to in-memory.")
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
            HomeView(store: coordinator.store)
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
        // 检查是否从 Action Button 启动（冷启动场景）
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

    // MARK: - URL Scheme Handling

    /// 处理 URL 打开（Action Button 或其他外部调用）
    private func handleOpenURL(_ url: URL) {
        print("Received URL: \(url.absoluteString)")

        // 检查是否是录音 URL
        if url.absoluteString == actionButtonURLScheme {
            print("Action Button triggered via URL Scheme")
            handleActionButtonLaunch()
        }
    }

    // MARK: - Action Button Handling

    /// 检查是否从 Action Button 启动
    /// - Returns: 是否从 Action Button 启动
    private func isLaunchedFromActionButton() -> Bool {
        // 方法1: 检查 launch options（通过 AppDelegate）
        // 方法2: 检查是否通过特定的 User Activity 启动
        // 方法3: 检查最近的前台切换时间（如果 App 刚从后台恢复，可能是 Action Button）

        // V1 简单实现：检查是否是通过快捷指令触发
        // 用户设置 Action Button → 快捷指令 → 打开 URL → voicetodo://record

        // 由于 SwiftUI App 没有 AppDelegate，我们依赖 .onOpenURL 来检测
        // 这里返回 false，实际检测在 handleOpenURL 中完成
        return false
    }

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        // 确保已完成引导
        guard hasCompletedOnboarding else {
            print("Onboarding not completed, skipping auto-record")
            return
        }

        // 检查权限
        guard permissionManager.micGranted && permissionManager.speechGranted else {
            print("Permissions not granted, showing toast")
            coordinator.showToast(
                message: "请先授予麦克风和语音识别权限",
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
