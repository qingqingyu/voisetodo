import SwiftUI
import Foundation
import Combine
import WidgetKit

/// App 协调器
/// 负责编排完整的语音录入流程
/// 使用协议类型保持依赖反转原则 (DIP)
@MainActor
final class AppCoordinator: ObservableObject {
    // MARK: - Dependencies

    private let voiceInput: any VoiceInputProtocol
    private let store: any AppCoordinatorTodoStore
    /// 用于「没能识别」分组的「重新解析」入口(`reextract(todoID:)`)。
    /// transcriptProcessingFlow / pendingRecoveryFlow 内部各自持有 extractor;
    /// 这里独立保留一个 reference 是因为 reextract 不走那两个 flow 的状态机,而是同步触发单次提取。
    private let extractor: any TodoExtractorProtocol
    /// 订阅状态(判断 isPro 跳过付费墙自动引导)。@MainActor 注入,init 后只读 isPro。
    private let entitlement: EntitlementManager
    private let calendarWriteModeProvider: () -> CalendarWriteMode
    private let vocabularyStore: UserVocabularyStore
    private let correctionTracker = CorrectionTracker.shared
    /// 系统日历读取器,用于场景 1「撞车检测」。nil = 当前未注入(测试场景),
    /// 跳过撞车检测。
    private let calendarReader: (any SystemCalendarReadingProtocol)?
    private let calendarSyncService: CalendarSyncService
    private let pendingRecoveryFlow: PendingRecoveryFlow
    private let transcriptProcessingFlow: TranscriptProcessingFlow
    /// 额度模型（用于离线补处理后的透明用量提示）。nil 时跳过额度相关 toast。
    private weak var quotaUsage: QuotaUsage?

    // MARK: - Published State

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var extractedTodos: [ExtractedTodo] = []
    @Published var showConfirmSheet = false
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastStyle: ToastStyle = .info
    @Published var toastActionTitle: String?
    @Published var toastAction: (() -> Void)?
    @Published var deepLinkTodoId: UUID?
    @Published var isExtracting = false
    /// 「没能识别」分组正在重新解析的 todo id 集合。
    /// `reextract(todoID:)` 加入 → 完成/失败移除。UI(HomeView → UnparsedTodoCard)
    /// 用它驱动按钮 disabled + ProgressView,防止用户连点触发并发提取。
    @Published var reextractingTodoIDs: Set<UUID> = []
    /// 静音自动提交信号（true = 语音识别检测到说话后静音，已自动 finishRecording，
    /// UI 应触发 handlePanelSend 进入处理流程）。UI 消费后复位为 false。
    @Published var didAutoFinishDueToSilence = false
    /// 当前音频电平 (0...1)，驱动波形动画
    @Published var audioLevel: Float = 0
    /// 配额耗尽或用户手动进入时弹出订阅页。
    @Published var showPaywall = false
    /// 语音输入不可用（识别器初始化失败 / 资源缺失）时设为 true，通知 UI 自动切键盘模式。
    /// UI 监听到 true 后应 switchInputPanelMode(toKeyboard: true) 并复位为 false。
    @Published var voiceInputFallbackToKeyboard = false
    /// A2 自动学习:当用户反复把同一说法改成同一结果时,弹出建议写入 glossary。nil = 无建议。
    @Published var glossarySuggestion: GlossarySuggestion?
    /// 回顾通知深链:通知点击后设 true,HomeView 监听后弹出 ReviewView。
    @Published var showReviewFromNotification = false
    /// 撞车警告:todo.id → 同时段冲突的日历事件列表。
    /// 流式 .success 后由 `detectConflicts()` 异步填充;sheet 关闭/取消时清空。
    /// 第一版本只做"提示",不阻断确认。
    @Published var conflictWarnings: [UUID: [ExternalCalendarEvent]] = [:]
    /// Intent (Spotlight/Action Button) 触发录音时,HomeView 需要先展开 BottomInputPanel 再启动录音。
    /// 由 VoiceTodoApp.handleActionButtonLaunch 设 true,HomeView onChange 消费后清回 false。
    @Published var pendingIntentRecordingLaunch = false
    /// detectConflicts 的 Task 引用,cancelTodos / confirmTodos 时显式 cancel,
    /// 避免用户已离开 ConfirmSheet 后台仍在串行 await 日历访问。
    private var conflictDetectionTask: Task<Void, Never>?

    /// 给 CalendarImportView 用的日历读取器。
    /// nil 表示未注入(测试场景),UI 应该不显示导入入口或显示空 sheet。
    var importReader: (any SystemCalendarReadingProtocol)? { calendarReader }

    /// 确认页应显示的语音原文（pending 场景使用合并的原始转写）
    var confirmSheetTranscript: String {
        combinedRawTranscript ?? activeInputTranscript ?? transcript
    }

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var isProcessingPending = false
    private var isProcessingTranscript = false
    private var extractionTask: Task<Void, Never>?

    /// 标记是否正在自动处理（Action Button 启动的录音流程）
    private var isAutoProcessing = false

    /// 离线待处理条目 ID 列表（用于网络恢复后替换）
    private var pendingItemIds: [UUID] = []
    private var pendingGeneratedTodoIdsByPendingId: [UUID: [UUID]] = [:]

    /// 本次 session 中已跳过恢复弹窗的 pending ID（用户取消或展示状态冲突时避免重复弹窗/重复请求）
    private var dismissedPendingIds: Set<UUID> = []

    /// 合并的原始转写文本（多个 pending 的 rawTranscript 合并，避免丢失）
    private var combinedRawTranscript: String?

    /// 当前待确认流程的输入原文（支持语音转写和手动输入共用确认页）
    private var activeInputTranscript: String?
    private var activeInputLocaleIdentifier: String?

    // MARK: - Initialization

    init(
        voiceInput: any VoiceInputProtocol,
        extractor: any TodoExtractorProtocol,
        store: any AppCoordinatorTodoStore & PendingRecoveryTodoStore & PendingTranscriptCreating & CalendarSyncTodoStore,
        entitlement: EntitlementManager? = nil,
        systemCalendarWriter: any SystemCalendarWritingProtocol = SystemCalendarWriter(),
        calendarReader: (any SystemCalendarReadingProtocol)? = SystemCalendarReader(),
        calendarWriteModeProvider: @escaping () -> CalendarWriteMode = { CalendarWriteMode.current },
        networkIsConnectedProvider: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
        vocabularyStore: UserVocabularyStore = .shared,
        quotaUsage: QuotaUsage? = nil
    ) {
        self.voiceInput = voiceInput
        self.store = store
        self.extractor = extractor
        // nil 兜底:测试调用方不传时,创建不监听 Transaction.updates 的轻量实例,
        // 避免在测试环境启动常驻 Task 监听 StoreKit2 异步流
        self.entitlement = entitlement ?? EntitlementManager(enableTransactionListener: false)
        self.calendarReader = calendarReader
        self.calendarWriteModeProvider = calendarWriteModeProvider
        self.vocabularyStore = vocabularyStore
        self.quotaUsage = quotaUsage
        self.calendarSyncService = CalendarSyncService(store: store, writer: systemCalendarWriter)
        self.pendingRecoveryFlow = PendingRecoveryFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: networkIsConnectedProvider
        )
        self.transcriptProcessingFlow = TranscriptProcessingFlow(
            store: store,
            extractor: extractor,
            networkIsConnectedProvider: networkIsConnectedProvider
        )

        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // 监听录音状态（通过协议定义的 Publisher）
        voiceInput.isRecordingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        // 监听转写文本
        voiceInput.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$transcript)

        // 监听识别错误（识别过程中的错误，非 startRecording 抛出的）
        voiceInput.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.handleError(error)
                }
            }
            .store(in: &cancellables)

        // 监听静音自动提交信号——转发给 UI 层触发 handlePanelSend
        voiceInput.didAutoFinishDueToSilencePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$didAutoFinishDueToSilence)

        // 监听音频电平——驱动波形动画。
        // throttle 到 30Hz 对齐 WaveformView 的 TimelineView(.animation) 帧率，
        // 避免 43Hz tap 回调全量触发 SwiftUI body 重算。
        voiceInput.audioLevelPublisher
            .throttle(for: .seconds(1.0 / 30.0), scheduler: DispatchQueue.main, latest: true)
            .assign(to: &$audioLevel)

        // 监听录音成功完成(语音识别 isFinal + 有 transcript),用于"第 5 次录音后引导付费"。
        // 与 isRecordingPublisher 的下降沿不同:后者失败也会下降,这里只在成功路径发射。
        voiceInput.recordingSuccessPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleRecordingSuccess() }
            .store(in: &cancellables)
    }

    // MARK: - Paywall Auto-Trigger

    /// 累计录音成功次数(UserDefaults 持久化,跨启动累积,永不重置)。
    /// 用户答到 5 次后,首次触发付费墙引导。已 Pro 用户不触发。
    private let recordingSuccessCountKey = "co.voicetodo.paywall.recordingSuccessCount"
    /// 上次自动弹付费墙的时间戳(timeIntervalSince1970)。0 = 从未弹过。
    /// 用于 14 天冷却——拒绝后 14 天内不再弹。
    private let lastPaywallAutoShownAtKey = "co.voicetodo.paywall.lastAutoShownAt"
    /// 触发阈值:累计录音成功到这个次数后开始检查是否引导。
    private let paywallTriggerThreshold = 5
    /// 冷却时长:用户拒绝后 14 天内不再主动弹。
    private let paywallCooldown: TimeInterval = 14 * 24 * 3600

    private func handleRecordingSuccess() {
        let defaults = UserDefaults.standard
        let newCount = defaults.integer(forKey: recordingSuccessCountKey) + 1
        defaults.set(newCount, forKey: recordingSuccessCountKey)

        // 未达阈值:继续累积,不弹
        guard newCount >= paywallTriggerThreshold else { return }
        // 已付费:不骚扰
        guard !entitlement.isPro else { return }
        // 14 天冷却:上次弹过且未到期,跳过
        let lastShown = defaults.double(forKey: lastPaywallAutoShownAtKey)
        let now = Date().timeIntervalSince1970
        if lastShown > 0, now - lastShown < paywallCooldown {
            return
        }
        // paywall 已经在展示(例如配额耗尽刚弹过):不重复弹、不重置冷却,
        // 否则用户在 sheet 已展示时录第 5 次音会刷新 lastPaywallAutoShownAt,
        // 导致实际间隔远大于 14 天。
        guard !showPaywall else { return }

        defaults.set(now, forKey: lastPaywallAutoShownAtKey)
        showPaywall = true
        let cooldownDays = Int(paywallCooldown / 86400)
        VoiceTodoLog.coordinator.info("coordinator.paywall.auto_trigger reason=recording_count count=\(newCount) cooldownDays=\(cooldownDays)")
    }

    // MARK: - Public Methods

    /// 启动录音流程。
    ///
    /// 返回值：录音是否真正处于活跃状态。调用方（尤其 UI 层）应以此返回值为准，
    /// 不要在 `await` 后立刻读 `coordinator.isRecording`：那是 Combine 绑定
    /// (`.receive(on: .main).assign`)，值要等下一个 runloop 才到，会触发误判
    /// （参见 `home.input_panel.start_recording_no_op fallback=keyboard` 竞态）。
    @discardableResult
    func startRecording() async -> Bool {
        guard !voiceInput.isRecording else {
            VoiceTodoLog.coordinator.warning("coordinator.recording.start_ignored reason=already_recording")
            return false
        }
        let flowID = VoiceTodoLog.makeID("coord-record")
        let startedAt = Date()
        // source 推断：actionButton 路径在 handleActionButtonLaunch 里 isAutoProcessing=true 后才调 startRecording
        let source: RecordingSource = isAutoProcessing ? .actionButton : .button
        VoiceTodoLog.coordinator.info("coordinator.recording.start id=\(flowID, privacy: .public) source=\(source.rawValue, privacy: .public)")
        do {
            try await voiceInput.startRecording()
            VoiceTodoLog.coordinator.info("coordinator.recording.started id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            Telemetry.record(.recordingStarted(source: source))
            return true
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.recording.start_failed id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.recordingFailed(reason: Telemetry.reason(for: error), errorCode: nil))
            handleError(error)
            return false
        }
    }

    /// 真机音频中断或 App 退到非活跃态时，明确取消本次录音
    func cancelRecordingDueToInterruption() {
        guard voiceInput.isRecording else {
            VoiceTodoLog.coordinator.debug("coordinator.recording.interruption_ignored reason=not_recording")
            return
        }
        VoiceTodoLog.coordinator.warning("coordinator.recording.interrupted transcriptChars=\(self.transcript.count)")
        voiceInput.cancelRecordingDueToInterruption()
        isAutoProcessing = false
        isProcessingTranscript = false
        isExtracting = false
    }

    /// 用户主动取消当前录音，不将其作为音频中断错误上报给 UI。
    func cancelRecording() {
        let flowID = VoiceTodoLog.makeID("coord-cancel")
        guard voiceInput.isRecording else {
            VoiceTodoLog.coordinator.debug("coordinator.recording.cancel_ignored id=\(flowID, privacy: .public) reason=not_recording")
            return
        }
        VoiceTodoLog.coordinator.info("coordinator.recording.cancelled id=\(flowID, privacy: .public) transcriptChars=\(self.transcript.count)")
        // 委托给 voiceInput.cancelRecordingByUser() —— Telemetry/duration 由其内部记录（与
        // cancelRecordingDueToInterruption 对称），coordinator 这里只重置编排状态。
        voiceInput.cancelRecordingByUser()
        isAutoProcessing = false
        isProcessingTranscript = false
        isExtracting = false
    }

    /// 停止录音并处理结果
    func stopRecordingAndProcess() async {
        let flowID = VoiceTodoLog.makeID("stop-process")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.stop_and_process.start id=\(flowID, privacy: .public) transcriptChars=\(self.transcript.count)")

        // 取消自动处理（用户手动点击停止）
        isAutoProcessing = false

        // 使用 finishRecording() 让识别器自然完成，确保获取最终识别结果
        voiceInput.finishRecording()

        // 等待转写完成（isRecording 变为 false 表示识别结果已就绪）
        await waitForRecordingToFinish()

        // 兜底：若识别回调未及时结束，强制收敛录音状态，避免后续无法再次启动录音
        if voiceInput.isRecording {
            VoiceTodoLog.coordinator.warning("coordinator.stop_and_process.force_stop id=\(flowID, privacy: .public)")
            voiceInput.stopRecording()
        }

        // 处理转写结果
        await processTranscript(voiceInput.transcript)
        VoiceTodoLog.coordinator.info("coordinator.stop_and_process.finished id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) finalTranscriptChars=\(self.transcript.count)")
    }

    /// 等待录音结束，最多等 3 秒
    private func waitForRecordingToFinish() async {
        guard voiceInput.isRecording else { return }
        let waitID = VoiceTodoLog.makeID("wait-final")
        let startedAt = Date()
        VoiceTodoLog.coordinator.debug("coordinator.wait_recording.start id=\(waitID, privacy: .public) timeoutSeconds=3")
        let recordingValues = voiceInput.isRecordingPublisher.values

        await withTaskGroup(of: Void.self) { group in
            // 任务 1：通过 Publisher.values (AsyncSequence) 等待 isRecording 变为 false
            // Task 被 cancel 时 .values 迭代自动终止，无 continuation 泄漏风险
            group.addTask {
                for await value in recordingValues {
                    if !value { break }
                }
            }

            // 任务 2：超时保护 3 秒
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            // 取最先完成的，取消另一个
            _ = await group.next()
            group.cancelAll()
        }
        VoiceTodoLog.coordinator.debug("coordinator.wait_recording.finished id=\(waitID, privacy: .public) stillRecording=\(self.voiceInput.isRecording) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 等待自然停录（静音检测触发），最多等 60 秒
    private func waitForAutoStop() async {
        guard voiceInput.isRecording else { return }
        let waitID = VoiceTodoLog.makeID("wait-auto")
        let startedAt = Date()
        VoiceTodoLog.coordinator.debug("coordinator.wait_auto_stop.start id=\(waitID, privacy: .public) timeoutSeconds=60")
        let recordingValues = voiceInput.isRecordingPublisher.values

        await withTaskGroup(of: Void.self) { group in
            // 任务 1：通过 Publisher.values (AsyncSequence) 等待 isRecording 变为 false
            // Task 被 cancel 时 .values 迭代自动终止，无 continuation 泄漏风险
            group.addTask {
                for await value in recordingValues {
                    if !value { break }
                }
            }

            // 任务 2：超时保护 60 秒（足够长的录音窗口）
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }

            // 取最先完成的，取消另一个
            _ = await group.next()
            group.cancelAll()
        }
        VoiceTodoLog.coordinator.debug("coordinator.wait_auto_stop.finished id=\(waitID, privacy: .public) stillRecording=\(self.voiceInput.isRecording) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 手动触发录音处理（用于 Action Button 启动）
    func handleActionButtonLaunch() async {
        // 确认页打开时不启动新录音，避免覆盖待确认的待办
        guard !showConfirmSheet else {
            VoiceTodoLog.coordinator.warning("coordinator.action_button.ignored reason=confirm_sheet_visible")
            return
        }

        let flowID = VoiceTodoLog.makeID("action")
        let startedAt = Date()
        isAutoProcessing = true
        VoiceTodoLog.coordinator.info("coordinator.action_button.start id=\(flowID, privacy: .public)")

        let didStart = await startRecording()

        // 录音未成功启动（权限错误等），直接返回
        guard didStart else {
            isAutoProcessing = false
            VoiceTodoLog.coordinator.warning("coordinator.action_button.recording_not_started id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }

        // 等待自然停录（静音检测自动停止）
        await waitForAutoStop()

        // 60 秒超时后若仍在录音，主动结束输入并等待最终识别结果
        if voiceInput.isRecording {
            VoiceTodoLog.coordinator.warning("coordinator.action_button.auto_timeout id=\(flowID, privacy: .public)")
            voiceInput.finishRecording()
            await waitForRecordingToFinish()
        }
        // 兜底收敛
        if voiceInput.isRecording {
            VoiceTodoLog.coordinator.warning("coordinator.action_button.force_stop id=\(flowID, privacy: .public)")
            voiceInput.stopRecording()
        }

        // 检查是否被手动停止取消
        guard isAutoProcessing else {
            VoiceTodoLog.coordinator.info("coordinator.action_button.cancelled id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }
        isAutoProcessing = false

        // 自动处理转写结果
        await processTranscript(voiceInput.transcript)
        VoiceTodoLog.coordinator.info("coordinator.action_button.finished id=\(flowID, privacy: .public) transcriptChars=\(self.transcript.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 处理手动输入文本并提取待办
    func processManualInput(_ text: String) async {
        guard !isRecording, !isAutoProcessing, !showConfirmSheet, !isProcessingTranscript else {
            VoiceTodoLog.coordinator.warning("coordinator.manual_input.ignored isRecording=\(self.isRecording) isAutoProcessing=\(self.isAutoProcessing) showConfirmSheet=\(self.showConfirmSheet) isProcessingTranscript=\(self.isProcessingTranscript)")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceTodoLog.coordinator.info("coordinator.manual_input.start \(VoiceTodoLog.textSummary(trimmed), privacy: .public)")
        activeInputTranscript = trimmed
        await processTranscript(trimmed, locale: .current)
    }

    /// App 进入前台时处理待处理项（并发）
    func handleAppForeground() async {
        guard !isProcessingPending else {
            VoiceTodoLog.coordinator.debug("coordinator.foreground.ignored reason=already_processing_pending")
            return
        }
        guard !isRecording, !isAutoProcessing, !isProcessingTranscript, !showConfirmSheet else {
            VoiceTodoLog.coordinator.debug("coordinator.foreground.ignored isRecording=\(self.isRecording) isAutoProcessing=\(self.isAutoProcessing) isProcessingTranscript=\(self.isProcessingTranscript) showConfirmSheet=\(self.showConfirmSheet)")
            return
        }

        let flowID = VoiceTodoLog.makeID("pending")
        let startedAt = Date()
        isProcessingPending = true
        defer { isProcessingPending = false }

        let result = await pendingRecoveryFlow.recover(
            dismissedPendingIds: dismissedPendingIds,
            locale: voiceInput.currentLocale,
            flowID: flowID
        )
        for failure in result.failedPendingRecoveries {
            handleError(failure.error)
        }
        result.deletionErrors.forEach(handleError)
        if let pendingReadError = result.pendingReadError {
            // 不走通用 handleError（那只能弹纯文案 toast），
            // 改用带「重试」按钮的 toast —— 用户点了直接重跑 handleAppForeground，
            // 走完同样的 pending 读取 + 恢复流程。
            VoiceTodoLog.coordinator.warning("coordinator.foreground.pending_read_error_surfacable action=retry_available error=\(VoiceTodoLog.errorSummary(pendingReadError), privacy: .public)")
            showToast(
                message: ErrorMessages.storageError,
                style: .warning,
                actionTitle: String(localized: "common.retry"),
                action: { [weak self] in
                    // 双重 [weak self]：外层防 toast 显示期间 AppCoordinator 无法释放；
                    // 内层 Task 跑完前也不能强引用 self（handleAppForeground 是 transient，
                    // 但严格并发语义下仍要避免 Task 闭包强持有 self）。
                    Task { @MainActor [weak self] in
                        await self?.handleAppForeground()
                    }
                }
            )
        }
        guard result.hasPending else { return }

        completeNoTodoPendingRecoveries(result.processedWithoutTodosIds)

        if !result.extractedTodos.isEmpty {
            guard !isRecording, !isAutoProcessing, !isProcessingTranscript, !showConfirmSheet else {
                VoiceTodoLog.coordinator.warning("coordinator.foreground.results_deferred id=\(flowID, privacy: .public) extractedCount=\(result.extractedTodos.count) isRecording=\(self.isRecording) isAutoProcessing=\(self.isAutoProcessing) isProcessingTranscript=\(self.isProcessingTranscript) showConfirmSheet=\(self.showConfirmSheet)")
                skipPendingForCurrentSession(result.processedWithTodosIds, reason: "presentation_busy", flowID: flowID)
                return
            }

            pendingGeneratedTodoIdsByPendingId = result.extractedTodoIdsByPendingId
            pendingItemIds = result.processedWithTodosIds
            combinedRawTranscript = result.mergedRawTranscript
            extractedTodos = result.extractedTodos
            showConfirmSheet = true
            VoiceTodoLog.coordinator.info("coordinator.foreground.pending_success id=\(flowID, privacy: .public) extractedCount=\(result.extractedTodos.count) processedWithTodos=\(result.processedWithTodosIds.count) processedWithoutTodos=\(result.processedWithoutTodosIds.count) failed=\(result.failedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } else {
            for pendingId in result.processedWithTodosIds {
                deleteProcessedPending(id: pendingId)
            }
            pendingItemIds = []
            pendingGeneratedTodoIdsByPendingId = [:]
            combinedRawTranscript = nil
            VoiceTodoLog.coordinator.info("coordinator.foreground.pending_finished_empty id=\(flowID, privacy: .public) processed=\(result.processedWithTodosIds.count + result.processedWithoutTodosIds.count) failed=\(result.failedCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        }

        // 透明提示：本次离线补处理消耗了额度（每条 pending 经代理调用自然计入当日额度）。
        let recoveryCount = result.processedWithTodosIds.count + result.processedWithoutTodosIds.count
        showRecoveryQuotaToast(recoveryCount: recoveryCount)
    }

    /// 离线补处理完成后的用量透明提示。数据源：代理 X-Quota-*（权威）+ 本次计数 Y。
    /// 非权威态（极端：代理未回额度头）用本地估算并标「估算」。
    private func showRecoveryQuotaToast(recoveryCount: Int) {
        guard recoveryCount > 0, let quotaUsage else { return }
        quotaUsage.rolloverLocalEstimateIfNeeded()
        if !quotaUsage.isAuthoritative {
            // 代理未回额度头：本地估算累加本次补处理条数（标非权威）。
            for _ in 0..<recoveryCount { quotaUsage.recordLocalUsageIncrement(background: true) }
        }
        // Pro 档也是有限额度，两档统一显示「已用 used/limit」。
        let used = quotaUsage.used
        var message = String(format: String(localized: "quota.today_used"), used, quotaUsage.limit)
        if recoveryCount > 0 {
            message += " " + String(format: String(localized: "quota.including_background"), recoveryCount)
        }
        if !quotaUsage.isAuthoritative {
            message += " " + String(localized: "quota.non_authoritative")
        }
        showToast(message: message, style: .info)
    }

    private func completeNoTodoPendingRecoveries(_ pendingIds: [UUID]) {
        for pendingId in pendingIds {
            _ = deleteProcessedPending(id: pendingId)
        }
    }

    /// 确认添加待办
    /// - Returns: 是否保存成功
    func confirmTodos(_ todos: [ExtractedTodo]) -> Bool {
        let confirmID = VoiceTodoLog.makeID("confirm")
        let startedAt = Date()
        let wasExtracting = isExtracting || isProcessingTranscript
        VoiceTodoLog.coordinator.info("coordinator.confirm.start id=\(confirmID, privacy: .public) todoCount=\(todos.count) availableCount=\(self.extractedTodos.count) pendingCount=\(self.pendingItemIds.count) isExtracting=\(self.isExtracting) calendarMode=\(self.calendarWriteModeProvider().rawValue, privacy: .public)")
        do {
            let confirmedIds = Set(todos.map(\.id))
            // 如果有 pending 条目，使用替换逻辑
            if !pendingItemIds.isEmpty {
                try store.replacePendingBatchWithExtracted(pendingItemIds, todos, rawTranscript: combinedRawTranscript)
                VoiceTodoLog.coordinator.info("coordinator.confirm.replaced_pending id=\(confirmID, privacy: .public) pending=\(VoiceTodoLog.idsSummary(self.pendingItemIds), privacy: .public) todoCount=\(todos.count)")

                // 成功确认后清理 dismissed 记录（先移除再清空列表）
                dismissedPendingIds.subtract(pendingItemIds)
                pendingItemIds = []
                pendingGeneratedTodoIdsByPendingId = [:]
                combinedRawTranscript = nil
                activeInputTranscript = nil
            } else {
                // 正常在线流程：直接添加
                try store.addBatch(todos, localeIdentifier: activeInputLocaleIdentifier)
                VoiceTodoLog.coordinator.info("coordinator.confirm.added_batch id=\(confirmID, privacy: .public) todoCount=\(todos.count)")
                activeInputTranscript = nil
            }

            if wasExtracting {
                stopExtractionAfterSuccessfulConfirm(confirmID: confirmID, confirmedCount: todos.count)
            }

            let fallbackLearningLocaleIdentifier = activeInputLocaleIdentifier ?? voiceInput.currentLocale.identifier
            let learningTodosByLocale = Dictionary(grouping: todos) { todo in
                todo.localeIdentifier ?? fallbackLearningLocaleIdentifier
            }
            Task.detached(priority: .utility) { [vocabularyStore, learningTodosByLocale] in
                for (localeIdentifier, localizedTodos) in learningTodosByLocale {
                    vocabularyStore.learn(
                        from: localizedTodos,
                        localeIdentifier: localeIdentifier,
                        source: .confirmedTodo
                    )
                }
            }
            activeInputLocaleIdentifier = nil

            // A2: 自动学习——diff 原始提取 title vs 确认后 title,累计频次,达阈值弹建议
            let originalTodos = self.extractedTodos
            Task { [correctionTracker] in
                for confirmed in todos {
                    guard let original = originalTodos.first(where: { $0.id == confirmed.id }) else { continue }
                    if original.title != confirmed.title,
                       let diff = TitleCorrection.extractPhraseDiff(original: original.title, confirmed: confirmed.title) {
                        correctionTracker.record(
                            original: diff.phrase,
                            confirmed: diff.expansion,
                            localeIdentifier: confirmed.localeIdentifier ?? fallbackLearningLocaleIdentifier
                        )
                    }
                }
                if let first = correctionTracker.suggestions().first, self.glossarySuggestion == nil {
                    self.glossarySuggestion = GlossarySuggestion(correction: first)
                }
            }

            let shouldSyncSystemCalendar = calendarWriteModeProvider() == .appAndSystemCalendar
            if shouldSyncSystemCalendar {
                let current = store.todos.filter { confirmedIds.contains($0.id) }
                if current.isEmpty {
                    VoiceTodoLog.coordinator.warning("coordinator.confirm.calendar_skipped id=\(confirmID, privacy: .public) reason=confirmed_items_missing")
                } else {
                    observeCalendarSync(
                        calendarSyncService.enqueueWrite(todos: current, sourceID: confirmID)
                    )
                }
            }

            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.coordinator.info("coordinator.confirm.success id=\(confirmID, privacy: .public) todoCount=\(todos.count) shouldSyncCalendar=\(shouldSyncSystemCalendar) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return true
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.confirm.failed id=\(confirmID, privacy: .public) todoCount=\(todos.count) pendingCount=\(self.pendingItemIds.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
            return false
        }
    }

    /// 成功保存流式 partial 后停止剩余解析，但保留当前结果供成功动画和学习逻辑使用。
    private func stopExtractionAfterSuccessfulConfirm(confirmID: String, confirmedCount: Int) {
        VoiceTodoLog.coordinator.info("coordinator.confirm.streaming_stopped id=\(confirmID, privacy: .public) confirmedCount=\(confirmedCount) availableCount=\(self.extractedTodos.count) isExtracting=\(self.isExtracting)")
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
        isProcessingTranscript = false
    }

    /// 「没能识别」分组「重新解析」入口:把 todo.rawTranscript 再喂一次 extractor,
    /// 成功 → 调 store.replaceTodo 替换为 .parsed 条目;失败 → 保留原 todo + toast 不打断。
    /// 不复用 TranscriptProcessingFlow 状态机:那个 flow 是给"录入→确认"流程用的,
    /// reextract 是"已落库的原文 → 重新提取",状态机不匹配。
    func reextract(todoID: UUID) {
        // 并发守卫:同一条 todo 正在重新解析时直接拒,避免连点触发多个 Task。
        if reextractingTodoIDs.contains(todoID) {
            VoiceTodoLog.coordinator.warning("coordinator.reextract.duplicate_skipped todoId=\(todoID.uuidString, privacy: .public)")
            return
        }
        let reextractID = VoiceTodoLog.makeID("reextract")
        VoiceTodoLog.coordinator.info("coordinator.reextract.start id=\(reextractID, privacy: .public) todoId=\(todoID.uuidString, privacy: .public)")
        reextractingTodoIDs.insert(todoID)
        Task {
            defer { reextractingTodoIDs.remove(todoID) }
            guard let todo = store.todos.first(where: { $0.id == todoID }),
                  let transcript = todo.rawTranscript else {
                VoiceTodoLog.coordinator.warning("coordinator.reextract.skipped id=\(reextractID, privacy: .public) reason=no_raw_transcript todoId=\(todoID.uuidString, privacy: .public)")
                return
            }
            let localeIdentifier = todo.localeIdentifier ?? voiceInput.currentLocale.identifier
            let locale = Locale(identifier: localeIdentifier)
            do {
                let result = try await VoiceTodoLog.$requestPath.withValue("reextract") {
                    try await extractor.extract(from: transcript, locale: locale)
                }
                if result.todos.isEmpty {
                    VoiceTodoLog.coordinator.info("coordinator.reextract.empty id=\(reextractID, privacy: .public)")
                    showToast(message: ErrorMessages.reextractStillEmpty, style: .info)
                    return
                }
                try store.replaceTodo(id: todoID, with: result.todos, rawTranscript: transcript)
                WidgetCenter.shared.reloadAllTimelines()
                VoiceTodoLog.coordinator.info("coordinator.reextract.success id=\(reextractID, privacy: .public) todoId=\(todoID.uuidString, privacy: .public) newCount=\(result.todos.count)")
            } catch VoiceTodoError.todoNotFound {
                // 重新提取期间原 todo 被并发删除(用户在别处删了)。
                // 原 todo 已不在,replaceTodo 无法替换——不打扰用户(他们已主动删除,无需感知)。
                // 仅记 warning 用于调试。
                VoiceTodoLog.coordinator.warning("coordinator.reextract.todo_vanished id=\(reextractID, privacy: .public) todoId=\(todoID.uuidString, privacy: .public)")
            } catch {
                VoiceTodoLog.coordinator.error("coordinator.reextract.failed id=\(reextractID, privacy: .public) todoId=\(todoID.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                handleError(error)
            }
        }
    }

    /// 从系统日历事件导入待办(场景 3)。
    /// 把选中的日历事件转 TodoItemData(source = .calendarImport)后批量入库。
    /// 失败走通用 handleError。
    func importCalendarEvents(_ events: [ExternalCalendarEvent]) {
        let importID = VoiceTodoLog.makeID("cal-import")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.calendar_import.start id=\(importID, privacy: .public) eventCount=\(events.count)")

        let todos = events.compactMap { SystemCalendarEventImporter.todo(from: $0) }
        guard !todos.isEmpty else {
            // 用户选了事件但全部因为空标题被过滤——显式提示,而不是静默什么都不做。
            VoiceTodoLog.coordinator.warning("coordinator.calendar_import.skipped id=\(importID, privacy: .public) reason=no_valid_events selectedCount=\(events.count)")
            showToast(message: String(localized: "calendar_import.no_valid_events"), style: .warning)
            return
        }

        do {
            try store.addImportedBatch(todos)
            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.coordinator.info("coordinator.calendar_import.success id=\(importID, privacy: .public) importedCount=\(todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            showToast(message: String(format: String(localized: "calendar_import.success_count"), todos.count), style: .success)
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.calendar_import.failed id=\(importID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
        }
    }

    /// 取消确认
    func cancelTodos() {
        VoiceTodoLog.coordinator.info("coordinator.confirm.cancel pendingCount=\(self.pendingItemIds.count) extractedCount=\(self.extractedTodos.count) isExtracting=\(self.isExtracting)")
        extractionTask?.cancel()
        extractionTask = nil
        // 撞车检测在后台跑时也要取消,避免用户已离开 sheet 后仍在串行 await 日历访问。
        conflictDetectionTask?.cancel()
        conflictDetectionTask = nil

        // 记录已取消的 pending ID，避免本次 session 重复弹窗
        // 不删除 pending 条目，保留离线转写数据
        skipPendingForCurrentSession(pendingItemIds, reason: "confirm_cancelled", flowID: nil)

        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
        conflictWarnings = [:]
        showConfirmSheet = false
        pendingItemIds = []
        pendingGeneratedTodoIdsByPendingId = [:]
        combinedRawTranscript = nil
        activeInputTranscript = nil
        activeInputLocaleIdentifier = nil
        isAutoProcessing = false
    }

    /// 删除待办（含系统日历清理）。
    /// 无论当前 calendarWriteMode 设置如何，只要待办存在系统日历事件标识就会尝试删除，
    /// 确保切换回"仅 App"模式后历史孤立事件也能被清理。
    /// - Parameter id: 待办 ID
    func deleteTodo(_ id: UUID) throws {
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.todo.delete.start id=\(id.uuidString, privacy: .public)")
        let todo = store.todos.first { $0.id == id }
        try store.delete(id)

        if let eventIdentifier = todo?.systemCalendarEventIdentifier {
            observeCalendarSync(
                calendarSyncService.enqueueDelete(todoID: id, eventIdentifier: eventIdentifier)
            )
        }

        WidgetCenter.shared.reloadAllTimelines()
        VoiceTodoLog.coordinator.info("coordinator.todo.delete.success id=\(id.uuidString, privacy: .public) hadCalendarEvent=\(todo?.systemCalendarEventIdentifier != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 切换完成状态（详情页 "Mark as Done" 用）
    func toggleTodo(_ id: UUID) {
        do {
            try store.toggleComplete(id)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            VoiceTodoLog.store.error("coordinator.toggle_failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }

    /// 重新排序（拖拽排序后调用）。委托给 store.reorder 做局部重排，
    /// 错误向上抛由调用方 catch + toast。
    /// - Parameter ids: 按新顺序排列的待办 ID 数组（子集或全集）
    func reorderTodos(ids: [UUID]) throws {
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.todo.reorder.start count=\(ids.count, privacy: .public)")
        try store.reorder(ids: ids)
        WidgetCenter.shared.reloadAllTimelines()
        VoiceTodoLog.coordinator.info("coordinator.todo.reorder.success count=\(ids.count, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 详情页完整更新——支持 dueDate、模糊时段和 detail。
    func updateTodoDetail(_ id: UUID, update: TodoDetailUpdate) throws {
        let startedAt = Date()
        let oldTodo = store.todos.first { $0.id == id }
        try store.updateFull(id, update: update)
        VoiceTodoLog.coordinator.info("coordinator.todo.update_detail.saved id=\(id.uuidString, privacy: .public) hasDueDate=\(update.dueDate != nil) explicitTimeBucket=\(update.timeBucket?.rawValue ?? "nil", privacy: .public) hasDetail=\(update.detail != nil) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

        let shouldSyncSystemCalendar = calendarWriteModeProvider() == .appAndSystemCalendar
        if oldTodo?.systemCalendarEventIdentifier != nil || shouldSyncSystemCalendar {
            observeCalendarSync(
                calendarSyncService.enqueueReplace(
                    todoID: id,
                    oldEventIdentifier: oldTodo?.systemCalendarEventIdentifier,
                    shouldWriteNewEvent: shouldSyncSystemCalendar,
                    sourceID: id.uuidString
                )
            )
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Private Methods

    /// 取消正在进行的 AI 提取
    func cancelExtraction() {
        VoiceTodoLog.coordinator.info("coordinator.extraction.cancel isExtracting=\(self.isExtracting) extractedCount=\(self.extractedTodos.count)")
        extractionTask?.cancel()
        extractionTask = nil
        conflictDetectionTask?.cancel()
        conflictDetectionTask = nil
        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
        conflictWarnings = [:]
        showConfirmSheet = false
        pendingGeneratedTodoIdsByPendingId = [:]
        activeInputTranscript = nil
        activeInputLocaleIdentifier = nil
    }

    private func observeCalendarSync(_ task: Task<CalendarSyncResult, Never>) {
        Task { [weak self] in
            let result = await task.value
            guard let self else {
                if result.shouldShowFailureToast {
                    VoiceTodoLog.calendar.error("calendar.sync.result_dropped reason=coordinator_deallocated operation=\(String(describing: result.operation), privacy: .public) status=\(String(describing: result.status), privacy: .public)")
                }
                return
            }
            self.handleCalendarSyncResult(result)
        }
    }

    private func handleCalendarSyncResult(_ result: CalendarSyncResult) {
        if result.shouldShowFailureToast {
            showToast(message: ErrorMessages.systemCalendarSyncFailed, style: .warning)
        }
    }

    /// 处理转写文本（流式）
    private func processTranscript(_ text: String, locale: Locale? = nil) async {
        guard !isProcessingTranscript else {
            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.ignored reason=already_processing \(VoiceTodoLog.textSummary(text), privacy: .public)")
            return
        }
        let flowID = VoiceTodoLog.makeID("process")
        let extractID = VoiceTodoLog.makeID("extract")
        isProcessingTranscript = true
        isExtracting = true

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLocale = locale ?? voiceInput.currentLocale
        activeInputTranscript = trimmed
        activeInputLocaleIdentifier = effectiveLocale.identifier

        // 弹层录音结束即升起:transcript 已就绪,弹层带着空列表 + 「还在识别...」出现,
        // todo 一条条流式插入。避免「全屏 loading → 弹层 loading」双转圈。
        // 失败兜底由 .noTodos / .failed case 调 clearExtractionPresentation() 关闭弹层。
        //
        // 这里同时清空 extractedTodos:防御 cancel 与 partial 竞态——上一次录音被用户快速
        // cancel 后,若 cancel 信号送达前已有 .partial 到达并写了 extractedTodos,
        // showConfirmSheet 已被 cancelExtraction 关为 false,残留数据不会被清理。
        // 下次录音开始若不在此清空,sheet 升起瞬间会闪现上一批 todo。
        if !showConfirmSheet {
            if !extractedTodos.isEmpty {
                VoiceTodoLog.coordinator.warning("coordinator.process_transcript.stale_extracted_cleared count=\(self.extractedTodos.count)")
                extractedTodos = []
            }
            showConfirmSheet = true
            VoiceTodoLog.coordinator.info("coordinator.process_transcript.confirm_sheet_early id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public)")
        }

        extractionTask = Task {
            let events = transcriptProcessingFlow.process(
                text: text,
                locale: effectiveLocale,
                flowID: flowID,
                extractID: extractID
            )
            for await event in events {
                guard !Task.isCancelled else { return }
                handleTranscriptFlowEvent(event, flowID: flowID, extractID: extractID)
            }

            isExtracting = false
            isProcessingTranscript = false
        }

        await extractionTask?.value
    }

    private func handleTranscriptFlowEvent(
        _ event: TranscriptFlowEvent,
        flowID: String,
        extractID: String
    ) {
        switch event {
        case .empty:
            // 弹层已在 processTranscript 开头升起,.empty 是「识别为空」的短路路径,
            // 必须显式关闭,否则弹层卡在「空列表 + 还在识别」永不消失。
            clearExtractionPresentation()
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.noTodosFound, style: .info)
        case .partial(let result):
            guard !result.todos.isEmpty else {
                VoiceTodoLog.coordinator.debug("coordinator.process_transcript.empty_partial_ignored id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public)")
                break
            }
            extractedTodos = result.todos
        case .success:
            // 流式稳定后异步触发撞车检测;失败不阻断,只记日志。
            // 保存 Task 引用,便于 cancelTodos 时显式取消(避免 sheet 关闭后仍在后台跑)。
            conflictDetectionTask?.cancel()
            conflictDetectionTask = Task { await detectConflicts() }
        case .noTodos:
            // 弹层已在 processTranscript 开头升起,识别为空必须显式关闭,
            // 否则弹层会卡在「空列表 + 还在识别」永远不消失。
            clearExtractionPresentation()
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.noTodosFound, style: .info)
        case .offlineSaved:
            // 弹层已升起,离线短路必须显式关闭,否则卡死。
            clearExtractionPresentation()
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.savedOffline, style: .info)
        case .offlineSaveFailed(let error):
            // 弹层已升起,离线保存失败也必须关闭,否则卡死。
            clearExtractionPresentation()
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            handleError(error)
        case .fallbackSaved(_, let reason):
            handleOfflineFallbackSaved(triggerPaywall: false, reason: reason)
        case .quotaFallbackSaved:
            handleOfflineFallbackSaved(triggerPaywall: true, reason: nil)
        case .networkFallbackSaveFailed(let error):
            clearExtractionPresentation()
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            handleError(error)
        case .failed(let error):
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            clearExtractionPresentation()
            handleError(error)
        }
    }

    private func skipPendingForCurrentSession(_ pendingIds: [UUID], reason: String, flowID: String?) {
        guard !pendingIds.isEmpty else { return }
        dismissedPendingIds.formUnion(pendingIds)
        VoiceTodoLog.coordinator.info("coordinator.pending.skip_session reason=\(reason, privacy: .public) flowID=\(flowID ?? "none", privacy: .public) pending=\(VoiceTodoLog.idsSummary(pendingIds), privacy: .public)")
    }

    private func clearExtractionPresentation() {
        if showConfirmSheet || !extractedTodos.isEmpty {
            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.clear_partial_results shown=\(self.showConfirmSheet) partialCount=\(self.extractedTodos.count)")
        }
        conflictDetectionTask?.cancel()
        conflictDetectionTask = nil
        extractedTodos = []
        conflictWarnings = [:]
        showConfirmSheet = false
    }

    /// 流式结束后异步检测每条 ExtractedTodo 是否跟系统日历事件撞车。
    /// 结果写入 `conflictWarnings`,ConfirmSheet 据此显示警告 banner。
    /// 失败不抛错——撞车检测是 nice-to-have,不应让用户感知。
    /// reader 未注入(测试场景)时直接跳过。
    /// 并发:用 TaskGroup 并行查每条 todo 的撞车(避免串行 await N 次 reader)。
    /// 取消语义:cancelTodos 后新进来的取消会让后续子任务短路、`for await` 也 break,
    /// 但**已进入 `reader.findConflicts` 的子任务无法中途退出**(EventKit 的
    /// `eventStore.events(matching:)` 是同步阻塞调用,没有 cancellation point)。
    /// 结果会被最后的 guard 丢弃,功能上无害,只是后台会跑完那几个查询。
    private func detectConflicts() async {
        guard let reader = calendarReader else { return }
        guard !extractedTodos.isEmpty else { return }
        // 快照当前 extractedTodos——避免循环中 sheet 被关掉、extractedTodos 清空后
        // 还在跑已经无意义的检测。
        let snapshot = extractedTodos
        let candidates = snapshot.filter { $0.dueDate != nil }
        guard !candidates.isEmpty else { return }

        var newWarnings: [UUID: [ExternalCalendarEvent]] = [:]
        // 并发查每条 todo 的撞车;用 task group 把 N 条 reader 调用并行起来。
        // 取消传播:子任务进入 findConflicts 前查 Task.isCancelled(短路);
        // 父任务 for await 循环里也查,中途取消就 break。
        // reader 不加 weak —— 协议非 class-bound 无法 [weak reader];Task 闭包隐式
        // 捕获 self(@MainActor class),但 cancelTodos/clearExtractionPresentation 都会
        // 显式 cancel 并置 nil,且 AppCoordinator 是 App 级生命周期,不会真泄漏。
        await withTaskGroup(of: (UUID, [ExternalCalendarEvent]?).self) { group in
            for todo in candidates {
                group.addTask {
                    // 子任务取消时尽快返回 nil(让父任务 break)。
                    if Task.isCancelled { return (todo.id, nil) }
                    do {
                        let conflicts = try await reader.findConflicts(for: todo)
                        return (todo.id, conflicts.isEmpty ? nil : conflicts)
                    } catch {
                        VoiceTodoLog.coordinator.warning("coordinator.conflict.detect_failed todoId=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        return (todo.id, nil)
                    }
                }
            }
            for await (todoID, conflicts) in group {
                if Task.isCancelled { break }
                if let conflicts { newWarnings[todoID] = conflicts }
            }
        }
        // 只在 sheet 仍打开 + 任务没被取消时写入,避免覆盖已被 cancel 的状态
        guard !Task.isCancelled, showConfirmSheet else { return }
        conflictWarnings = newWarnings
    }

    /// 外部调用失败（含配额耗尽）后离线兜底成功的统一处理。
    /// 普通失败保留原始原因并显示准确提示；配额耗尽继续走 paywall。
    /// `triggerPaywall=true` 时额外弹出订阅页（仅配额耗尽场景）。
    private func handleOfflineFallbackSaved(triggerPaywall: Bool, reason: VoiceTodoError?) {
        clearExtractionPresentation()
        activeInputTranscript = nil
        activeInputLocaleIdentifier = nil
        if let reason {
            showToast(
                message: reason.errorDescription ?? ErrorMessages.unexpectedError,
                style: .warning
            )
        } else {
            showToast(message: ErrorMessages.savedOffline, style: .info)
        }
        if triggerPaywall {
            VoiceTodoLog.coordinator.info("coordinator.paywall.trigger reason=quota_exhausted")
            showPaywall = true
        }
    }

    /// 显示 Toast
    func showToast(message: String, style: ToastStyle, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toastMessage = message
        toastStyle = style
        toastActionTitle = actionTitle
        toastAction = action
        showToast = true
    }

    /// 显示语音权限缺失提示
    func showVoicePermissionRequiredToast() {
        showToast(
            message: ErrorMessages.permissionsRequired,
            style: .warning,
            actionTitle: String(localized: "toast.open_settings"),
            action: { PermissionManager.openAppSettings() }
        )
    }

    @discardableResult
    private func deleteProcessedPending(id: UUID) -> Bool {
        do {
            try store.delete(id)
            VoiceTodoLog.coordinator.info("coordinator.pending.delete_processed id=\(id.uuidString, privacy: .public)")
            return true
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.pending.delete_processed_failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
            return false
        }
    }

    /// 统一错误处理
    private func handleError(_ error: Error) {
        VoiceTodoLog.coordinator.error("coordinator.error_handled error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        if let voiceError = error as? VoiceTodoError {
            let settingsAction: () -> Void = { PermissionManager.openAppSettings() }
            let settingsTitle = String(localized: "toast.open_settings")

            switch voiceError {
            case .microphonePermissionDenied:
                // 权限被拒：切键盘让用户继续输入 + 引导去设置开权限
                voiceInputFallbackToKeyboard = true
                showToast(message: ErrorMessages.micDenied, style: .warning, actionTitle: settingsTitle, action: settingsAction)
            case .speechRecognitionPermissionDenied:
                voiceInputFallbackToKeyboard = true
                showToast(message: ErrorMessages.speechDenied, style: .warning, actionTitle: settingsTitle, action: settingsAction)
            case .speechRecognitionUnavailable:
                // 识别器初始化失败 / 资源缺失 / isAvailable=false 都走这里。
                // "去设置"按钮对这类环境故障没用（设置里没有可恢复的开关），
                // 改为触发键盘 fallback：UI 收到信号后自动 switchInputPanelMode(toKeyboard: true)，
                // 让用户继续输入而不是干瞪眼看 toast。
                voiceInputFallbackToKeyboard = true
                showToast(message: ErrorMessages.speechUnavailable, style: .info)
            case .audioSessionInterrupted:
                // 音频会话被中断（来电 / 闹钟 / 其他 app 抢音频）：切键盘让用户继续输入
                voiceInputFallbackToKeyboard = true
                showToast(message: ErrorMessages.audioSessionInterrupted, style: .warning)
            case .recordingFailed:
                // 录音失败（音频引擎启动失败、识别过程其他错误等）：切键盘让用户继续输入。
                // 注意：这条路径是兜底，特定识别错误（kLSRErrorDomain Code=300）已在
                // VoiceInputManager 里映射为 .speechRecognitionUnavailable 走更友好的文案。
                // detail 仅入日志(见 VoiceInputManager 里的 error.localizedDescription),
                // UI 走通用文案——与 VoiceTodoError.errorDescription 口径一致。
                voiceInputFallbackToKeyboard = true
                showToast(message: ErrorMessages.recordingFailedMessage, style: .warning)
            case .networkUnavailable:
                showToast(message: ErrorMessages.networkError, style: .warning)
            case .circuitOpen:
                showToast(message: ErrorMessages.circuitOpen, style: .warning)
            case .quotaExhausted:
                // 配额耗尽：开 paywall 引导升级，不弹普通失败 toast。
                VoiceTodoLog.coordinator.info("coordinator.paywall.trigger reason=quota_exhausted_handled")
                showPaywall = true
            case .rateLimited:
                showToast(message: ErrorMessages.rateLimited, style: .warning)
            case .ipRateLimited:
                showToast(message: ErrorMessages.ipRateLimited, style: .warning)
            case .serviceUnavailable:
                showToast(message: ErrorMessages.serviceBusy, style: .warning)
            case .storageReadFailed, .storageWriteFailed:
                showToast(message: ErrorMessages.storageError, style: .warning)
            case .apiTimeout:
                showToast(message: ErrorMessages.apiTimeout, style: .warning)
            case .apiServerError:
                showToast(message: ErrorMessages.apiError, style: .warning)
            case .apiResponseInvalid:
                showToast(message: ErrorMessages.apiResponseInvalidMessage, style: .warning)
            case .jsonParsingFailed:
                showToast(message: ErrorMessages.jsonParsingFailed, style: .warning)
            case .transcriptTooLong:
                showToast(message: ErrorMessages.transcriptTooLong, style: .warning)
            default:
                // 未明确归类的 VoiceTodoError case——走通用兜底文案(与 else 分支口径一致),
                // 以防未来新增 case 忘记加分支时暴露 LocalizedError 默认的程序员向文案。
                // 原始 case 已在第 851 行入日志。
                // ⚠️ 新增 VoiceTodoError case 时**必须**在此 switch 补显式分支或在
                // VoiceTodoError.errorDescription 里返回 ErrorMessages.<name>,否则 toast 上看不到
                // 针对该 case 的人性化文案。
                showToast(message: ErrorMessages.unexpectedError, style: .warning)
            }
        } else {
            // 非 VoiceTodoError 类型的错误(URLError / SwiftDataError / 第三方库原生 NSError 等):
            // 一律走通用文案,**绝不暴露 .localizedDescription 的英文/程序员向描述**。
            // 原始 error 已在第 851 行 `coordinator.error_handled` 入 VoiceTodoLog,诊断信息不丢。
            showToast(message: ErrorMessages.unexpectedError, style: .warning)
        }
    }
}
