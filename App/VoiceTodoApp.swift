import SwiftUI
import SwiftData

@main
struct VoiceTodoApp: App {
    // MARK: - SwiftData

    /// SwiftData ModelContainer
    let modelContainer: ModelContainer?

    // MARK: - State

    @StateObject private var coordinator: AppCoordinator?
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    // P1 修复: 错误状态
    @State private var initializationError: Error?
    @State private var showError = false

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        // 配置 SwiftData ModelContainer（使用 App Group）
        // P1 修复: 优雅处理初始化错误，不使用 fatalError
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
            // 初始化失败，记录错误但不 crash
            print("Failed to initialize VoiceTodo: \(error)")
            modelContainer = nil
            _coordinator = StateObject(wrappedValue: nil as AppCoordinator?)
            _initializationError = State(initialValue: error)
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
                .alert("初始化失败", isPresented: $showError) {
                    Button("重试") {
                        // 重试逻辑：重启 App
                        fatalError("Restart app to retry initialization")
                    }
                    Button("退出") {
                        exit(1)
                    }
                } message: {
                    if let error = initializationError {
                        Text("应用初始化失败：\(error.localizedDescription)")
                    } else {
                        Text("未知错误")
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Main View

    @ViewBuilder
    private var mainView: some View {
        if let error = initializationError {
            // P1 修复: 显示错误界面而非 crash
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 60))
                    .foregroundColor(.red)

                Text("初始化失败")
                    .font(.title)
                    .bold()

                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("重试") {
                    // 重试需要重启 App
                    showError = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let coordinator = coordinator {
            // 正常流程
            if hasCompletedOnboarding {
                // 已完成引导，显示主界面
                HomeView(store: TodoStore(modelContext: modelContainer!.mainContext))
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
        } else {
            // 未知状态，显示加载中
            ProgressView("正在初始化...")
        }
    }

    // MARK: - Lifecycle Handling

    /// 处理 App 启动
    private func handleAppLaunch() {
        // 检查初始化错误
        if initializationError != nil {
            showError = true
            return
        }

        // 检查是否从 Action Button 启动
        if isLaunchedFromActionButton() {
            handleActionButtonLaunch()
        }
    }

    /// 处理场景状态变化
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard let coordinator = coordinator else { return }

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
        // 这里使用 UserDefaults 标记作为示例

        // 未来可以通过 URL Scheme 或 User Activity 判断
        return false
    }

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        guard hasCompletedOnboarding, let coordinator = coordinator else { return }

        Task {
            await coordinator.handleActionButtonLaunch()
        }
    }
}

// MARK: - Preview

#Preview {
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TodoItem.self, configurations: config)

        return VoiceTodoApp()
            .modelContainer(container)
    } catch {
        return Text("Failed to create preview: \(error.localizedDescription)")
    }
}
