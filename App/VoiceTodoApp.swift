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
    @StateObject private var historyStore: VoiceCaptureHistoryStore
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    /// 标记是否应该自动开始录音（从 Action Button 启动）
    @State private var shouldAutoStartRecording = false
    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        let appStart = Date()
        let uiTestOptions = UITestLaunchOptions.current
        VoiceTodoLog.app.info("app.init.start isUITesting=\(uiTestOptions.isUITesting) resetUserData=\(uiTestOptions.resetUserData) skipOnboarding=\(uiTestOptions.skipOnboarding)")

        if uiTestOptions.resetUserData {
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
            VoiceTodoLog.app.warning("app.init.reset_user_data")
        }

        if uiTestOptions.skipOnboarding {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }

        let schema = VoiceTodoSchema.schema

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
            VoiceTodoLog.app.error("app.storage.shared_container_missing blocking=true isUITesting=\(uiTestOptions.isUITesting)")
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
                VoiceTodoLog.app.critical("app.storage.startup_error_container_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
                VoiceTodoLog.app.info("app.storage.container_created shared=\(shouldUseSharedContainer) inMemory=\(uiTestOptions.isUITesting)")
            } catch {
                let allowsFallback = ModelContainerStartupPolicy.allowsLocalFallback(
                    isUITesting: uiTestOptions.isUITesting,
                    attemptedSharedContainer: shouldUseSharedContainer,
                    sharedContainerAvailable: sharedContainerAvailable
                )
                VoiceTodoLog.app.error("app.storage.primary_container_failed shared=\(shouldUseSharedContainer) allowsFallback=\(allowsFallback) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
                    VoiceTodoLog.app.info("app.storage.fallback_container_created allowsFallback=\(allowsFallback) inMemory=\(uiTestOptions.isUITesting || !allowsFallback)")
                } catch {
                    VoiceTodoLog.app.critical("app.storage.fallback_container_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    fatalError("Failed to create even in-memory ModelContainer: \(error)")
                }
            }
        }
        modelContainer = container
        startupStorageError = storageError

        let store = TodoStore(modelContext: container.mainContext)
        let voiceHistoryStore = VoiceCaptureHistoryStore(modelContext: container.mainContext)

        if uiTestOptions.resetUserData {
            do {
                try store.resetForUITests()
            } catch {
                VoiceTodoLog.app.error("app.ui_test.reset_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
        if !uiTestOptions.presetTodos.isEmpty {
            do {
                try store.seedForUITests(uiTestOptions.presetTodos)
            } catch {
                VoiceTodoLog.app.error("app.ui_test.seed_failed count=\(uiTestOptions.presetTodos.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }

        // 初始化依赖
        let voiceInput: any VoiceInputProtocol = uiTestOptions.isUITesting ? UITestVoiceInputManager(options: uiTestOptions) : VoiceInputManager()
        let extractor: any TodoExtractorProtocol = uiTestOptions.isUITesting ? UITestTodoExtractor() : TodoExtractorService()

        // 独立持有 Store（同时共享给 Coordinator 和 HomeView）
        _todoStore = StateObject(wrappedValue: store)
        _historyStore = StateObject(wrappedValue: voiceHistoryStore)

        // 初始化 Coordinator
        _coordinator = StateObject(wrappedValue: AppCoordinator(
            voiceInput: voiceInput,
            extractor: extractor,
            store: store,
            historyStore: voiceHistoryStore
        ))
        // BGTask 必须在 App 启动早期同步注册（before scene starts）
        TelemetryUploader.shared.registerBackgroundTask()
        TelemetryUploader.shared.scheduleNextRun()
        VoiceTodoLog.app.info("app.init.finished durationMS=\(VoiceTodoLog.durationMS(since: appStart)) storageError=\(storageError != nil)")
        // app_launch 遥测：coldLaunch 区分靠 scenePhase（此处视为冷启动，热启动不重新 init）
        Telemetry.record(.appLaunch(coldLaunch: true, hasCompletedOnboarding: hasCompletedOnboarding))
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
                // 引导完成后主动关闭 sheet，避免它继续盖在主界面之上
                .onChange(of: hasCompletedOnboarding) { _, completed in
                    if completed {
                        showOnboarding = false
                    }
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
            RootTabView(todoStore: todoStore, historyStore: historyStore)
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
                .accessibilityIdentifier("RootTabView")
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
        VoiceTodoLog.app.info("app.launch hasCompletedOnboarding=\(hasCompletedOnboarding) startupStorageError=\(startupStorageError != nil)")
        guard startupStorageError == nil else { return }
        coordinator.cleanupExpiredVoiceHistory()
    }

    /// 处理场景状态变化
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        VoiceTodoLog.app.info("app.scene_phase.changed phase=\(String(describing: phase), privacy: .public) startupStorageError=\(startupStorageError != nil)")
        switch phase {
        case .active:
            guard startupStorageError == nil else { return }
            // App 进入前台，同步 Widget Extension 可能做的修改（如打勾完成）
            refreshStoreIfNeededFromExternalChanges(force: true)
            NetworkMonitor.shared.restartIfNeeded()
            // 节流清理过期语音历史：launch 时已清一次，此处兜底长时间热启动场景。
            // 异步执行避免阻塞 UI 主线程（fetch + delete 可能涉及大量记录）。
            Task { @MainActor in
                coordinator.cleanupExpiredVoiceHistoryIfNeeded()
            }
            Task {
                await coordinator.handleAppForeground()
            }
        case .inactive:
            break
        case .background:
            coordinator.cancelRecordingDueToInterruption()
            // 调度遥测批量上报（系统会在「充电 + 网络」满足时触发）
            TelemetryUploader.shared.scheduleNextRun()
        @unknown default:
            break
        }
    }

    private func refreshStoreIfNeededFromExternalChanges(force: Bool = false) {
        // P6: 失效逻辑统一收口到 TodoStore.refreshIfStale，App 仅触发
        todoStore.refreshIfStale(force: force)
    }

    // MARK: - URL Scheme Handling

    /// 处理 URL 打开（Action Button、Widget 深链等）
    private func handleOpenURL(_ url: URL) {
        VoiceTodoLog.app.info("app.open_url received scheme=\(url.scheme ?? "nil", privacy: .public) host=\(url.host ?? "nil", privacy: .public) path=\(url.path, privacy: .public)")
        guard startupStorageError == nil else {
            VoiceTodoLog.app.warning("app.open_url.ignored reason=startup_storage_error")
            return
        }
        guard url.scheme?.caseInsensitiveCompare("voicetodo") == .orderedSame else {
            VoiceTodoLog.app.warning("app.open_url.ignored reason=unsupported_scheme scheme=\(url.scheme ?? "nil", privacy: .public)")
            return
        }

        switch url.host?.lowercased() {
        case "record":
            VoiceTodoLog.app.info("app.open_url.record")
            handleActionButtonLaunch()
        case "todo":
            if let todoId = VoiceTodoDeepLink.parseTodoUUID(from: url) {
                coordinator.deepLinkTodoId = todoId
                VoiceTodoLog.app.info("app.open_url.todo todoID=\(todoId.uuidString, privacy: .public)")
            } else {
                VoiceTodoLog.app.warning("app.open_url.todo_invalid path=\(url.path, privacy: .public)")
            }
        case "home":
            // Siri 结果卡片跳转回 App 主页，数据同步由 scenePhase .active 处理
            VoiceTodoLog.app.info("app.open_url.home")
            break
        default:
            VoiceTodoLog.app.warning("app.open_url.ignored reason=unknown_host host=\(url.host ?? "nil", privacy: .public)")
            break
        }
    }

    // MARK: - Action Button Handling

    /// 处理 Action Button 启动
    private func handleActionButtonLaunch() {
        guard startupStorageError == nil else {
            VoiceTodoLog.app.warning("app.action_button.ignored reason=startup_storage_error")
            return
        }

        // 确保已完成引导
        guard hasCompletedOnboarding else {
            VoiceTodoLog.app.warning("app.action_button.ignored reason=onboarding_incomplete")
            coordinator.showToast(message: ErrorMessages.finishOnboardingFirst, style: .info)
            return
        }

        Task {
            let readiness = await permissionManager.ensureVoicePermissionsBeforeRecording()
            guard readiness == .granted else {
                VoiceTodoLog.app.warning("app.action_button.permission_blocked readiness=\(String(describing: readiness), privacy: .public)")
                coordinator.showVoicePermissionRequiredToast()
                return
            }

            // 设置标记，触发自动录音
            // 使用 DispatchQueue 延迟一帧，确保 UI 已准备就绪
            DispatchQueue.main.async {
                VoiceTodoLog.app.info("app.action_button.ready_to_start")
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
