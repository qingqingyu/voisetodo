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
    private let extractor: any TodoExtractorProtocol
    private let store: any TodoStoreProtocol
    private let systemCalendarWriter: any SystemCalendarWritingProtocol
    private let calendarWriteModeProvider: () -> CalendarWriteMode
    private let networkIsConnectedProvider: @MainActor () -> Bool
    private let vocabularyStore: UserVocabularyStore

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

    /// 本次 session 中用户已取消确认的 pending ID（避免重复弹窗）
    private var dismissedPendingIds: Set<UUID> = []

    /// 合并的原始转写文本（多个 pending 的 rawTranscript 合并，避免丢失）
    private var combinedRawTranscript: String?

    /// 当前待确认流程的输入原文（支持语音转写和手动输入共用确认页）
    private var activeInputTranscript: String?
    private var activeInputLocaleIdentifier: String?

    /// 正在执行的日历同步任务（用于串行化，防止快速连续确认产生重复日历事件）
    private var calendarSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        voiceInput: any VoiceInputProtocol,
        extractor: any TodoExtractorProtocol,
        store: any TodoStoreProtocol,
        systemCalendarWriter: any SystemCalendarWritingProtocol = SystemCalendarWriter(),
        calendarWriteModeProvider: @escaping () -> CalendarWriteMode = { CalendarWriteMode.current },
        networkIsConnectedProvider: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
        vocabularyStore: UserVocabularyStore = .shared
    ) {
        self.voiceInput = voiceInput
        self.extractor = extractor
        self.store = store
        self.systemCalendarWriter = systemCalendarWriter
        self.calendarWriteModeProvider = calendarWriteModeProvider
        self.networkIsConnectedProvider = networkIsConnectedProvider
        self.vocabularyStore = vocabularyStore

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
        VoiceTodoLog.coordinator.warning("coordinator.recording.interrupted transcriptChars=\(transcript.count)")
        voiceInput.cancelRecordingDueToInterruption()
        isAutoProcessing = false
        isProcessingTranscript = false
        isExtracting = false
    }

    /// 停止录音并处理结果
    func stopRecordingAndProcess() async {
        let flowID = VoiceTodoLog.makeID("stop-process")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.stop_and_process.start id=\(flowID, privacy: .public) transcriptChars=\(transcript.count)")

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
        await processTranscript(transcript)
        VoiceTodoLog.coordinator.info("coordinator.stop_and_process.finished id=\(flowID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) finalTranscriptChars=\(transcript.count)")
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
        VoiceTodoLog.coordinator.debug("coordinator.wait_recording.finished id=\(waitID, privacy: .public) stillRecording=\(voiceInput.isRecording) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
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
        VoiceTodoLog.coordinator.debug("coordinator.wait_auto_stop.finished id=\(waitID, privacy: .public) stillRecording=\(voiceInput.isRecording) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
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
        await processTranscript(transcript)
        VoiceTodoLog.coordinator.info("coordinator.action_button.finished id=\(flowID, privacy: .public) transcriptChars=\(transcript.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    }

    /// 处理手动输入文本并提取待办
    func processManualInput(_ text: String) async {
        guard !isRecording, !isAutoProcessing, !showConfirmSheet, !isProcessingTranscript else {
            VoiceTodoLog.coordinator.warning("coordinator.manual_input.ignored isRecording=\(isRecording) isAutoProcessing=\(isAutoProcessing) showConfirmSheet=\(showConfirmSheet) isProcessingTranscript=\(isProcessingTranscript)")
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
            VoiceTodoLog.coordinator.debug("coordinator.foreground.ignored isRecording=\(isRecording) isAutoProcessing=\(isAutoProcessing) isProcessingTranscript=\(isProcessingTranscript) showConfirmSheet=\(showConfirmSheet)")
            return
        }

        let pendingItems = store.pendingItems().filter { !dismissedPendingIds.contains($0.id) }
        guard !pendingItems.isEmpty else {
            VoiceTodoLog.coordinator.debug("coordinator.foreground.no_pending dismissedCount=\(dismissedPendingIds.count)")
            return
        }

        let flowID = VoiceTodoLog.makeID("pending")
        let startedAt = Date()
        isProcessingPending = true
        defer { isProcessingPending = false }
        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_start id=\(flowID, privacy: .public) pending=\(VoiceTodoLog.idsSummary(pendingItems.map(\.id)), privacy: .public) dismissedCount=\(dismissedPendingIds.count)")

        var processResults: [PendingProcessResult] = []

        // 先移除无 rawTranscript 的条目
        let validPending = pendingItems.filter { item in
            if item.rawTranscript == nil {
                VoiceTodoLog.coordinator.warning("coordinator.foreground.pending_missing_raw id=\(flowID, privacy: .public) pendingID=\(item.id.uuidString, privacy: .public)")
                deleteProcessedPending(id: item.id)
                return false
            }
            return true
        }

        let concurrency = NetworkConfig.pendingBatchConcurrency
        VoiceTodoLog.coordinator.info("coordinator.foreground.pending_window id=\(flowID, privacy: .public) validCount=\(validPending.count) concurrency=\(concurrency)")

        // 并发处理，滑动窗口模式
        await withTaskGroup(of: PendingProcessResult.self) { group in
            var iterator = validPending.enumerated().makeIterator()
            var activeCount = 0

            while activeCount < concurrency, let (index, pending) = iterator.next() {
                let transcript = pending.rawTranscript!
                let pendingId = pending.id
                let ext = self.extractor
                let loc = self.voiceInput.currentLocale
                group.addTask {
                    await Self.processSinglePending(index: index, id: pendingId, transcript: transcript, extractor: ext, locale: loc, flowID: flowID)
                }
                activeCount += 1
            }

            for await result in group {
                processResults.append(result)
                // 失败的保留 pending 不处理

                if let (index, next) = iterator.next() {
                    guard networkIsConnectedProvider() else { break }
                    let transcript = next.rawTranscript!
                    let nextId = next.id
                    let ext = self.extractor
                    let loc = self.voiceInput.currentLocale
                    group.addTask {
                        await Self.processSinglePending(index: index, id: nextId, transcript: transcript, extractor: ext, locale: loc, flowID: flowID)
                    }
                }
            }
        }

        let successfulResults = processResults
            .filter(\.succeeded)
            .sorted { $0.index < $1.index }
        let resultsWithTodos = successfulResults.filter { !$0.todos.isEmpty }
        let resultsWithoutTodos = successfulResults.filter { $0.todos.isEmpty }
        let allExtractedItems = resultsWithTodos.flatMap(\.todos)
        let processedWithTodosIds = resultsWithTodos.map(\.id)
        let processedWithoutTodosIds = resultsWithoutTodos.map(\.id)
        let rawTranscripts = resultsWithTodos.compactMap(\.rawTranscript)
        let mergedRawTranscript = rawTranscripts.isEmpty ? nil : rawTranscripts.joined(separator: "\n---\n")

        if !allExtractedItems.isEmpty {
            guard !isRecording, !isAutoProcessing, !isProcessingTranscript, !showConfirmSheet else {
                VoiceTodoLog.coordinator.warning("coordinator.foreground.results_deferred id=\(flowID, privacy: .public) extractedCount=\(allExtractedItems.count) isRecording=\(isRecording) isAutoProcessing=\(isAutoProcessing) isProcessingTranscript=\(isProcessingTranscript) showConfirmSheet=\(showConfirmSheet)")
                return
            }

            for pendingId in processedWithoutTodosIds {
                deleteProcessedPending(id: pendingId)
            }

            pendingItemIds = processedWithTodosIds
            combinedRawTranscript = mergedRawTranscript
            extractedTodos = allExtractedItems
            showConfirmSheet = true
            VoiceTodoLog.coordinator.info("coordinator.foreground.pending_success id=\(flowID, privacy: .public) extractedCount=\(allExtractedItems.count) processedWithTodos=\(processedWithTodosIds.count) processedWithoutTodos=\(processedWithoutTodosIds.count) failed=\(processResults.filter { !$0.succeeded }.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } else {
            for pendingId in processedWithTodosIds {
                deleteProcessedPending(id: pendingId)
            }
            for pendingId in processedWithoutTodosIds {
                deleteProcessedPending(id: pendingId)
            }
            pendingItemIds = []
            combinedRawTranscript = nil
            VoiceTodoLog.coordinator.info("coordinator.foreground.pending_finished_empty id=\(flowID, privacy: .public) processed=\(processResults.count) failed=\(processResults.filter { !$0.succeeded }.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        }
    }

    // MARK: - Pending Processing

    private struct PendingProcessResult: Sendable {
        let index: Int
        let id: UUID
        let todos: [ExtractedTodo]
        let rawTranscript: String?
        let succeeded: Bool
    }

    private static func processSinglePending(
        index: Int,
        id: UUID,
        transcript: String,
        extractor: any TodoExtractorProtocol,
        locale: Locale,
        flowID: String
    ) async -> PendingProcessResult {
        let startedAt = Date()
        let extractID = VoiceTodoLog.makeID("extract")
        VoiceTodoLog.coordinator.info("coordinator.pending_item.start id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) locale=\(locale.identifier, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            let result = try await VoiceTodoLog.$extractID.withValue(extractID) {
                try await extractor.extract(from: transcript, locale: locale)
            }
            VoiceTodoLog.coordinator.info("coordinator.pending_item.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) todos=\(result.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return PendingProcessResult(index: index, id: id, todos: result.todos, rawTranscript: transcript, succeeded: true)
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.pending_item.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) index=\(index) pendingID=\(id.uuidString, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return PendingProcessResult(index: index, id: id, todos: [], rawTranscript: transcript, succeeded: false)
        }
    }

    /// 确认添加待办
    /// - Returns: 是否保存成功
    func confirmTodos(_ todos: [ExtractedTodo]) -> Bool {
        let confirmID = VoiceTodoLog.makeID("confirm")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.confirm.start id=\(confirmID, privacy: .public) todoCount=\(todos.count) pendingCount=\(pendingItemIds.count) calendarMode=\(calendarWriteModeProvider().rawValue, privacy: .public)")
        do {
            let confirmedIds = Set(todos.map(\.id))
            // 如果有 pending 条目，使用替换逻辑
            if !pendingItemIds.isEmpty {
                try store.replacePendingBatchWithExtracted(pendingItemIds, todos, rawTranscript: combinedRawTranscript)
                VoiceTodoLog.coordinator.info("coordinator.confirm.replaced_pending id=\(confirmID, privacy: .public) pending=\(VoiceTodoLog.idsSummary(pendingItemIds), privacy: .public) todoCount=\(todos.count)")

                // 成功确认后清理 dismissed 记录（先移除再清空列表）
                dismissedPendingIds.subtract(pendingItemIds)
                pendingItemIds = []
                combinedRawTranscript = nil
                activeInputTranscript = nil
            } else {
                // 正常在线流程：直接添加
                try store.addBatch(todos)
                VoiceTodoLog.coordinator.info("coordinator.confirm.added_batch id=\(confirmID, privacy: .public) todoCount=\(todos.count)")
                activeInputTranscript = nil
            }

            let learningLocaleIdentifier = activeInputLocaleIdentifier ?? voiceInput.currentLocale.identifier
            let learningTodos = todos
            Task.detached(priority: .utility) { [vocabularyStore] in
                vocabularyStore.learn(
                    from: learningTodos,
                    localeIdentifier: learningLocaleIdentifier,
                    source: .confirmedTodo
                )
            }
            activeInputLocaleIdentifier = nil

            let shouldSyncSystemCalendar = calendarWriteModeProvider() == .appAndSystemCalendar
            if shouldSyncSystemCalendar {
                let previousTask = calendarSyncTask
                calendarSyncTask = Task { [weak self] in
                    await previousTask?.value
                    guard let self else { return }
                    let current = store.todos.filter { confirmedIds.contains($0.id) }
                    guard !current.isEmpty else {
                        VoiceTodoLog.coordinator.warning("coordinator.confirm.calendar_skipped id=\(confirmID, privacy: .public) reason=confirmed_items_missing")
                        return
                    }
                    await syncSystemCalendar(for: current)
                }
            }

            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.coordinator.info("coordinator.confirm.success id=\(confirmID, privacy: .public) todoCount=\(todos.count) shouldSyncCalendar=\(shouldSyncSystemCalendar) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return true
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.confirm.failed id=\(confirmID, privacy: .public) todoCount=\(todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
            return false
        }
    }

    /// 取消确认
    func cancelTodos() {
        VoiceTodoLog.coordinator.info("coordinator.confirm.cancel pendingCount=\(pendingItemIds.count) extractedCount=\(extractedTodos.count) isExtracting=\(isExtracting)")
        extractionTask?.cancel()
        extractionTask = nil

        // 记录已取消的 pending ID，避免本次 session 重复弹窗
        // 不删除 pending 条目，保留离线转写数据
        dismissedPendingIds.formUnion(pendingItemIds)

        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
        showConfirmSheet = false
        pendingItemIds = []
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
            let previousTask = calendarSyncTask
            let writer = systemCalendarWriter
            calendarSyncTask = Task { [weak self] in
                await previousTask?.value
                do {
                    try await writer.removeEvents(identifiers: [eventIdentifier])
                    VoiceTodoLog.calendar.info("calendar.delete.success todoID=\(id.uuidString, privacy: .public) eventID=\(eventIdentifier, privacy: .public)")
                } catch {
                    VoiceTodoLog.calendar.error("calendar.delete.failed todoID=\(id.uuidString, privacy: .public) eventID=\(eventIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    self?.showToast(message: ErrorMessages.systemCalendarSyncFailed, style: .warning)
                }
            }
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
        VoiceTodoLog.coordinator.info("coordinator.todo.update.saved id=\(id.uuidString, privacy: .public) hadOldCalendarEvent=\(oldTodo?.systemCalendarEventIdentifier != nil) shouldSyncCalendar=\(calendarWriteModeProvider() == .appAndSystemCalendar) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

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
            let previousTask = calendarSyncTask
            let writer = systemCalendarWriter
            calendarSyncTask = Task { [weak self] in
                await previousTask?.value
                guard let self else { return }
                if let oldId = oldTodo?.systemCalendarEventIdentifier {
                    do {
                        try await writer.removeEvents(identifiers: [oldId])
                        try store.updateSystemCalendarEventIdentifier(nil, for: id)
                        VoiceTodoLog.calendar.info("calendar.update.removed_old todoID=\(id.uuidString, privacy: .public) eventID=\(oldId, privacy: .public)")
                    } catch {
                        VoiceTodoLog.calendar.error("calendar.update.remove_old_failed todoID=\(id.uuidString, privacy: .public) eventID=\(oldId, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        showToast(message: ErrorMessages.systemCalendarSyncFailed, style: .warning)
                        return
                    }
                }
                guard let updated = store.todos.first(where: { $0.id == id }) else { return }
                if shouldSyncSystemCalendar {
                    await syncSystemCalendar(for: [updated])
                }
            }
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Private Methods

    /// 取消正在进行的 AI 提取
    func cancelExtraction() {
        VoiceTodoLog.coordinator.info("coordinator.extraction.cancel isExtracting=\(isExtracting) extractedCount=\(extractedTodos.count)")
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
        showConfirmSheet = false
        activeInputTranscript = nil
        activeInputLocaleIdentifier = nil
    }

    private func syncSystemCalendar(for todos: [TodoItemData]) async {
        let syncID = VoiceTodoLog.makeID("calendar")
        let startedAt = Date()
        VoiceTodoLog.calendar.info("calendar.sync.start id=\(syncID, privacy: .public) todoCount=\(todos.count) todoIDs=\(VoiceTodoLog.idsSummary(todos.map(\.id)), privacy: .public)")
        do {
            let results = try await systemCalendarWriter.writeEvents(for: todos)
            try await persistSystemCalendarResults(results)
            VoiceTodoLog.calendar.info("calendar.sync.success id=\(syncID, privacy: .public) resultCount=\(results.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } catch let partialError as SystemCalendarWriteError {
            VoiceTodoLog.calendar.error("calendar.sync.partial_failed id=\(syncID, privacy: .public) partialResults=\(partialError.results.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(partialError), privacy: .public)")
            do {
                try await persistSystemCalendarResults(partialError.results)
            } catch {
                VoiceTodoLog.calendar.error("calendar.sync.persist_partial_failed id=\(syncID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
            showToast(message: ErrorMessages.systemCalendarSyncFailed, style: .warning)
        } catch {
            VoiceTodoLog.calendar.error("calendar.sync.failed id=\(syncID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            showToast(message: ErrorMessages.systemCalendarSyncFailed, style: .warning)
        }
    }

    private func persistSystemCalendarResults(_ results: [SystemCalendarWriteResult]) async throws {
        var failedResults: [SystemCalendarWriteResult] = []

        for result in results {
            do {
                try store.updateSystemCalendarEventIdentifier(result.eventIdentifier, for: result.todoId)
                VoiceTodoLog.calendar.info("calendar.persist_identifier.success todoID=\(result.todoId.uuidString, privacy: .public) eventID=\(result.eventIdentifier, privacy: .public)")
            } catch {
                failedResults.append(result)
                VoiceTodoLog.calendar.error("calendar.persist_identifier.failed todoID=\(result.todoId.uuidString, privacy: .public) eventID=\(result.eventIdentifier, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }

        guard !failedResults.isEmpty else { return }

        do {
            try await systemCalendarWriter.removeEvents(identifiers: failedResults.map(\.eventIdentifier))
        } catch {
            VoiceTodoLog.calendar.error("calendar.cleanup_after_persist_failed failedCount=\(failedResults.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }

        throw VoiceTodoError.storageWriteFailed("Failed to persist system calendar event identifier")
    }

    /// 处理转写文本（流式）
    private func processTranscript(_ text: String, locale: Locale? = nil) async {
        guard !isProcessingTranscript else {
            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.ignored reason=already_processing \(VoiceTodoLog.textSummary(text), privacy: .public)")
            return
        }
        let flowID = VoiceTodoLog.makeID("process")
        let extractID = VoiceTodoLog.makeID("extract")
        let startedAt = Date()
        isProcessingTranscript = true
        isExtracting = true

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeInputTranscript = trimmed
        activeInputLocaleIdentifier = (locale ?? voiceInput.currentLocale).identifier
        let isConnected = networkIsConnectedProvider()
        VoiceTodoLog.coordinator.info("coordinator.process_transcript.start id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) locale=\((locale ?? voiceInput.currentLocale).identifier, privacy: .public) isConnected=\(isConnected) \(VoiceTodoLog.textSummary(trimmed), privacy: .public)")
        guard !trimmed.isEmpty else {
            isExtracting = false
            isProcessingTranscript = false
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.noTodosFound, style: .info)
            VoiceTodoLog.coordinator.info("coordinator.process_transcript.empty id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return
        }

        guard isConnected else {
            isExtracting = false
            isProcessingTranscript = false
            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.offline id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public)")
            await handleOfflineMode(transcript: text)
            return
        }

        extractionTask = Task {
            do {
                var receivedAny = false
                let stream = VoiceTodoLog.$extractID.withValue(extractID) {
                    extractor.extractStreaming(from: trimmed, locale: locale ?? voiceInput.currentLocale)
                }
                for try await partialResult in stream {
                    guard !Task.isCancelled else { return }
                    extractedTodos = partialResult.todos
                    if !showConfirmSheet && !partialResult.todos.isEmpty {
                        showConfirmSheet = true
                        VoiceTodoLog.coordinator.info("coordinator.process_transcript.confirm_sheet_shown id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) todos=\(partialResult.todos.count)")
                    }
                    receivedAny = !partialResult.todos.isEmpty
                    VoiceTodoLog.coordinator.debug("coordinator.process_transcript.partial id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) todos=\(partialResult.todos.count)")
                }

                guard !Task.isCancelled else { return }

                if !receivedAny {
                    activeInputTranscript = nil
                    activeInputLocaleIdentifier = nil
                    showToast(message: ErrorMessages.noTodosFound, style: .info)
                    VoiceTodoLog.coordinator.info("coordinator.process_transcript.no_todos id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                } else {
                    VoiceTodoLog.coordinator.info("coordinator.process_transcript.success id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) finalTodos=\(extractedTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let ve = error as? VoiceTodoError,
                   ve == .networkUnavailable || ve == .apiTimeout {
                    VoiceTodoLog.coordinator.warning("coordinator.process_transcript.network_fallback id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    clearExtractionPresentation()
                    await handleOfflineMode(transcript: text)
                } else {
                    activeInputTranscript = nil
                    activeInputLocaleIdentifier = nil
                    clearExtractionPresentation()
                    VoiceTodoLog.coordinator.error("coordinator.process_transcript.failed id=\(flowID, privacy: .public) extractID=\(extractID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                    handleError(error)
                }
            }

            isExtracting = false
            isProcessingTranscript = false
        }

        await extractionTask?.value
    }

    private func clearExtractionPresentation() {
        if showConfirmSheet || !extractedTodos.isEmpty {
            VoiceTodoLog.coordinator.warning("coordinator.process_transcript.clear_partial_results shown=\(showConfirmSheet) partialCount=\(extractedTodos.count)")
        }
        extractedTodos = []
        showConfirmSheet = false
    }

    /// 离线降级处理
    private func handleOfflineMode(transcript: String) async {
        let offlineID = VoiceTodoLog.makeID("offline")
        let startedAt = Date()
        VoiceTodoLog.coordinator.info("coordinator.offline_save.start id=\(offlineID, privacy: .public) \(VoiceTodoLog.textSummary(transcript), privacy: .public)")
        do {
            try store.addRawTranscript(transcript)
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            showToast(message: ErrorMessages.savedOffline, style: .info)
            VoiceTodoLog.coordinator.info("coordinator.offline_save.success id=\(offlineID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        } catch {
            activeInputTranscript = nil
            activeInputLocaleIdentifier = nil
            VoiceTodoLog.coordinator.error("coordinator.offline_save.failed id=\(offlineID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
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

    private func deleteProcessedPending(id: UUID) {
        do {
            try store.delete(id)
            VoiceTodoLog.coordinator.info("coordinator.pending.delete_processed id=\(id.uuidString, privacy: .public)")
        } catch {
            VoiceTodoLog.coordinator.error("coordinator.pending.delete_processed_failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            handleError(error)
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
