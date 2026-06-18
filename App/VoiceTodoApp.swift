import SwiftUI
import SwiftData

@main
struct VoiceTodoApp: App {
    // MARK: - SwiftData

    /// SwiftData ModelContainer
    let modelContainer: ModelContainer
    let startupStorageError: String?

    // MARK: - State

    @StateObject private var coordinator: AppCoordinator
    @StateObject private var todoStore: TodoStore
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    /// 标记是否应该自动开始录音（从 Action Button 启动）
    @State private var shouldAutoStartRecording = false
    @State private var lastObservedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()
    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        let uiTestOptions = UITestLaunchOptions.current

        if uiTestOptions.resetUserData {
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }

        if uiTestOptions.skipOnboarding {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }

        let schema = Schema([TodoItem.self, TodoOccurrenceCompletion.self])

        let sharedContainerAvailable = AppGroupConfig.sharedContainerURL != nil
        let shouldUseSharedContainer = !uiTestOptions.isUITesting && sharedContainerAvailable
        let shouldBlockForMissingSharedContainer = ModelContainerStartupPolicy.shouldBlockForMissingSharedContainer(
            isUITesting: uiTestOptions.isUITesting,
            sharedContainerAvailable: sharedContainerAvailable
        )

        // 配置 SwiftData ModelContainer。UI 测试和 DEBUG 无 entitlement 环境允许本地 fallback。
        let container: ModelContainer
        let storageError: String?
        if shouldBlockForMissingSharedContainer {
            do {
                let configuration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    allowsSave: true
                )
                container = try ModelContainer(
                    for: schema,
                    configurations: configuration
                )
                storageError = ErrorMessages.sharedStorageUnavailable
            } catch {
                fatalError("Failed to create startup error ModelContainer: \(error)")
            }
        } else {
            do {
                let configuration: ModelConfiguration
                if shouldUseSharedContainer {
                    configuration = ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: false,
                        allowsSave: true,
                        groupContainer: .identifier(AppGroupConfig.identifier)
                    )
                } else {
                    configuration = ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: uiTestOptions.isUITesting,
                        allowsSave: true
                    )
                }
                container = try ModelContainer(
                    for: schema,
                    configurations: configuration
                )
                storageError = nil
            } catch {
                let allowsFallback = ModelContainerStartupPolicy.allowsLocalFallback(
                    isUITesting: uiTestOptions.isUITesting,
                    attemptedSharedContainer: shouldUseSharedContainer,
                    sharedContainerAvailable: sharedContainerAvailable
                )
                #if DEBUG
                print("Failed to create primary ModelContainer: \(error). allowsFallback=\(allowsFallback)")
                #endif
                do {
                    let fallbackConfig = ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: uiTestOptions.isUITesting || !allowsFallback
                    )
                    container = try ModelContainer(
                        for: schema,
                        configurations: fallbackConfig
                    )
                    storageError = allowsFallback ? nil : ErrorMessages.sharedStorageUnavailable
                } catch {
                    fatalError("Failed to create even in-memory ModelContainer: \(error)")
                }
            }
        }
        modelContainer = container
        startupStorageError = storageError

        let store = TodoStore(modelContext: container.mainContext)

        if uiTestOptions.resetUserData {
            try? store.resetForUITests()
        }
        if !uiTestOptions.presetTodos.isEmpty {
            try? store.seedForUITests(uiTestOptions.presetTodos)
        }

        // 初始化依赖
        let voiceInput: any VoiceInputProtocol = uiTestOptions.isUITesting ? UITestVoiceInputManager(options: uiTestOptions) : VoiceInputManager()
        let extractor: any TodoExtractorProtocol = uiTestOptions.isUITesting ? UITestTodoExtractor() : TodoExtractorService()

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
                .environmentObject(coordinator)
                .environmentObject(permissionManager)
                .toast(
                    message: coordinator.toastMessage,
                    style: coordinator.toastStyle,
                    isPresented: $coordinator.showToast,
                    actionTitle: coordinator.toastActionTitle,
                    action: coordinator.toastAction
                )
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
        if let startupStorageError {
            StartupStorageErrorView(message: startupStorageError)
                .accessibilityIdentifier("StartupStorageErrorView")
        } else if hasCompletedOnboarding {
            // 已完成引导，显示主界面
            HomeView(store: todoStore)
                .sheet(isPresented: $coordinator.showConfirmSheet) {
                    ConfirmSheetView(
                        transcript: coordinator.confirmSheetTranscript,
                        todos: $coordinator.extractedTodos,
                        isStreaming: coordinator.isExtracting,
                        onConfirm: { todos in
                            coordinator.confirmTodos(todos)
                        },
                        onCancel: {
                            coordinator.cancelTodos()
                        }
                    )
                }
                .accessibilityIdentifier("HomeView")
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
                .accessibilityIdentifier("HomeView")
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
            guard startupStorageError == nil else { return }
            // App 进入前台，同步 Widget Extension 可能做的修改（如打勾完成）
            refreshStoreIfNeededFromExternalChanges(force: true)
            NetworkMonitor.shared.restartIfNeeded()
            Task {
                await coordinator.handleAppForeground()
            }
        case .inactive:
            break
        case .background:
            coordinator.cancelRecordingDueToInterruption()
        @unknown default:
            break
        }
    }

    private func refreshStoreIfNeededFromExternalChanges(force: Bool = false) {
        let version = AppGroupConfig.currentExternalChangeVersion()
        if force || version != lastObservedExternalChangeVersion {
            todoStore.refreshTodos()
            lastObservedExternalChangeVersion = version
        }
    }

    // MARK: - URL Scheme Handling

    /// 处理 URL 打开（Action Button、Widget 深链等）
    private func handleOpenURL(_ url: URL) {
        guard startupStorageError == nil else { return }
        guard url.scheme?.caseInsensitiveCompare("voicetodo") == .orderedSame else { return }

        switch url.host?.lowercased() {
        case "record":
            handleActionButtonLaunch()
        case "todo":
            if let todoId = VoiceTodoDeepLink.parseTodoUUID(from: url) {
                coordinator.deepLinkTodoId = todoId
            }
        case "home":
            // Siri 结果卡片跳转回 App 主页，数据同步由 scenePhase .active 处理
            break
        default:
            break
        }
    }

    // MARK: - Action Button Handling

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        guard startupStorageError == nil else { return }

        // 确保已完成引导
        guard hasCompletedOnboarding else {
            coordinator.showToast(message: ErrorMessages.finishOnboardingFirst, style: .info)
            return
        }

        Task {
            let readiness = await permissionManager.ensureVoicePermissionsBeforeRecording()
            guard readiness == .granted else {
                #if DEBUG
                print("Permissions not granted, showing toast")
                #endif
                coordinator.showVoicePermissionRequiredToast()
                return
            }

            // 设置标记，触发自动录音
            // 使用 DispatchQueue 延迟一帧，确保 UI 已准备就绪
            DispatchQueue.main.async {
                shouldAutoStartRecording = true
            }
        }
    }
}

enum ModelContainerStartupPolicy {
    static func allowsLocalFallback(
        isUITesting: Bool,
        attemptedSharedContainer: Bool,
        sharedContainerAvailable: Bool,
        isDebugBuild: Bool = defaultIsDebugBuild
    ) -> Bool {
        isUITesting || (!attemptedSharedContainer && !sharedContainerAvailable && isDebugBuild)
    }

    static func shouldBlockForMissingSharedContainer(
        isUITesting: Bool,
        sharedContainerAvailable: Bool,
        isDebugBuild: Bool = defaultIsDebugBuild
    ) -> Bool {
        !isUITesting && !sharedContainerAvailable && !isDebugBuild
    }

    static var defaultIsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

private struct StartupStorageErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(WarmTheme.warning)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(String(localized: "startup.storage_error.title"))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(WarmTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WarmTheme.background.ignoresSafeArea())
    }
}

// MARK: - Deep Link Parsing

private enum VoiceTodoDeepLink {
    /// Resolves UUID from `voicetodo://todo/<uuid>` and tolerant variants (slashes, query `id=`).
    static func parseTodoUUID(from url: URL) -> UUID? {
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedPath.isEmpty {
            if let id = UUID(uuidString: trimmedPath) { return id }
            for segment in trimmedPath.split(separator: "/") {
                if let id = UUID(uuidString: String(segment)) { return id }
            }
        }
        for component in url.pathComponents where component != "/" {
            if let id = UUID(uuidString: component) { return id }
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.name.caseInsensitiveCompare("id") == .orderedSame {
                if let value = item.value, let id = UUID(uuidString: value) { return id }
            }
        }
        return nil
    }
}
