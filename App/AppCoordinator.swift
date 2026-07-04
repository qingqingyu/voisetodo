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
    private let calendarWriteModeProvider: () -> CalendarWriteMode
    private let vocabularyStore: UserVocabularyStore
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
    /// 配额耗尽或用户手动进入时弹出订阅页。
    @Published var showPaywall = false

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
        systemCalendarWriter: any SystemCalendarWritingProtocol = SystemCalendarWriter(),
        calendarWriteModeProvider: @escaping () -> CalendarWriteMode = { CalendarWriteMode.current },
        networkIsConnectedProvider: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
        vocabularyStore: UserVocabularyStore = .shared,
        quotaUsage: QuotaUsage? = nil
    ) {
        self.voiceInput = voiceInput
        self.store = store
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
    }

    // MARK: - Public Methods

    /// 启动录音流程
    func startRecording() async {
        guard !voiceInput.isRecording else {
            VoiceTodoLog.coordinator.warning("coordinator.recording.start_ignored reason=already_recording")
            return
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
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.recording.start_failed id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.recordingFailed(reason: Telemetry.reason(for: error), errorCode: nil))
            handleError(error)
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

        await startRecording()

        // 录音未成功启动（权限错误等），直接返回
        guard voiceInput.isRecording else {
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
                actionTitle: String(localized: "history.retry"),
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
        let used = quotaUsage.used
        var message = quotaUsage.showsUnlimited
            ? "\(String(localized: "quota.unlimited")) · \(String(format: String(localized: "quota.used_only"), used))"
            : String(format: String(localized: "quota.today_used"), used, quotaUsage.limit)
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
        VoiceTodoLog.coordinator.info("coordinator.confirm.start id=\(confirmID, privacy: .public) todoCount=\(todos.count) pendingCount=\(self.pendingItemIds.count) calendarMode=\(self.calendarWriteModeProvider().rawValue, privacy: .public)")
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

    /// 取消确认
    func cancelTodos() {
        VoiceTodoLog.coordinator.info("coordinator.confirm.cancel pendingCount=\(self.pendingItemIds.count) extractedCount=\(self.extractedTodos.count) isExtracting=\(self.isExtracting)")
        extractionTask?.cancel()
        extractionTask = nil

        // 记录已取消的 pending ID，避免本次 session 重复弹窗
        // 不删除 pending 条目，保留离线转写数据
        skipPendingForCurrentSession(pendingItemIds, reason: "confirm_cancelled", flowID: nil)

        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
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

    /// 更新待办（含系统日历同步：删旧建新）
    /// - Parameters:
    ///   - id: 待办 ID
    ///   - title: 新标题
    ///   - category: 新分类（nil 表示不修改）
    ///   - priority: 新优先级（nil 表示不修改）
    ///   - dueHint: 新时间提示（nil 表示不修改，空字符串清除）
    ///   - recurrenceRule: 新重复规则（nil 表示关闭重复）
    func updateTodo(
        _ id: UUID,
        title: String,
        category: TodoCategory? = nil,
        priority: Priority? = nil,
        dueHint: String? = nil,
        recurrenceRule: RecurrenceRule? = nil
    ) throws {
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.todo.update.start id=\(id.uuidString, privacy: .public) titleChars=\(title.count) hasCategory=\(category != nil) hasPriority=\(priority != nil) dueHintChars=\(dueHint?.count ?? -1) recurrenceSet=\(recurrenceRule != nil)")
        let oldTodo = store.todos.first { $0.id == id }

        try store.update(id, title: title, category: category, priority: priority, dueHint: dueHint, recurrenceRule: recurrenceRule)
        VoiceTodoLog.coordinator.info("coordinator.todo.update.saved id=\(id.uuidString, privacy: .public) hadOldCalendarEvent=\(oldTodo?.systemCalendarEventIdentifier != nil) shouldSyncCalendar=\(self.calendarWriteModeProvider() == .appAndSystemCalendar) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

        if let updated = store.todos.first(where: { $0.id == id }) {
            let learningTitle = title
            let learningDetail = updated.detail
            let learningDueHint = updated.dueHint
            // 优先用 todo 创建时记录的 locale；旧数据无 localeIdentifier 时回退到当前输入 locale
            let learningLocaleIdentifier = updated.localeIdentifier ?? voiceInput.currentLocale.identifier
            Task.detached(priority: .utility) { [vocabularyStore] in
                vocabularyStore.learn(
                    fromTexts: [learningTitle, learningDetail, learningDueHint].compactMap { $0 },
                    localeIdentifier: learningLocaleIdentifier,
                    source: .editedTodo
                )
            }
        }

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
        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
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
            await self.handleCalendarSyncResult(result)
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
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.noTodosFound, style: .info)
        case .partial(let result):
            guard !result.todos.isEmpty else {
                VoiceTodoLog.coordinator.debug("coordinator.process_transcript.empty_partial_ignored id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public)")
                break
            }
            extractedTodos = result.todos
            if !showConfirmSheet {
                showConfirmSheet = true
                VoiceTodoLog.coordinator.info("coordinator.process_transcript.confirm_sheet_shown id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) todos=\(result.todos.count)")
            }
        case .success:
            break
        case .noTodos:
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.noTodosFound, style: .info)
        case .offlineSaved:
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.savedOffline, style: .info)
        case .offlineSaveFailed(let error):
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            handleError(error)
        case .networkFallbackSaved:
            handleOfflineFallbackSaved(triggerPaywall: false)
        case .quotaFallbackSaved:
            handleOfflineFallbackSaved(triggerPaywall: true)
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
        extractedTodos = []
        showConfirmSheet = false
    }

    /// 网络降级（含配额耗尽）离线兜底成功后的统一处理：清展示、提示已离线保存。
    /// `triggerPaywall=true` 时额外弹出订阅页（仅配额耗尽场景）。
    private func handleOfflineFallbackSaved(triggerPaywall: Bool) {
        clearExtractionPresentation()
        activeInputTranscript = nil
        activeInputLocaleIdentifier = nil
        showToast(message: ErrorMessages.savedOffline, style: .info)
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
                showToast(message: ErrorMessages.micDenied, style: .warning, actionTitle: settingsTitle, action: settingsAction)
            case .speechRecognitionPermissionDenied:
                showToast(message: ErrorMessages.speechDenied, style: .warning, actionTitle: settingsTitle, action: settingsAction)
            case .speechRecognitionUnavailable:
                showToast(message: ErrorMessages.speechUnavailable, style: .warning, actionTitle: settingsTitle, action: settingsAction)
            case .networkUnavailable:
                showToast(message: ErrorMessages.networkError, style: .warning)
            case .quotaExhausted:
                // 配额耗尽：开 paywall 引导升级，不弹普通失败 toast。
                VoiceTodoLog.coordinator.info("coordinator.paywall.trigger reason=quota_exhausted_handled")
                showPaywall = true
            case .rateLimited:
                showToast(message: ErrorMessages.rateLimited, style: .warning)
            case .serviceUnavailable:
                showToast(message: ErrorMessages.serviceBusy, style: .warning)
            case .storageReadFailed, .storageWriteFailed:
                showToast(message: ErrorMessages.storageError, style: .warning)
            default:
                showToast(message: voiceError.localizedDescription, style: .warning)
            }
        } else {
            showToast(message: error.localizedDescription, style: .warning)
        }
    }
}
