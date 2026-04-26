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
    private let networkMonitor = NetworkMonitor.shared

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
        combinedRawTranscript ?? transcript
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

    // MARK: - Initialization

    init(
        voiceInput: any VoiceInputProtocol,
        extractor: any TodoExtractorProtocol,
        store: any TodoStoreProtocol
    ) {
        self.voiceInput = voiceInput
        self.extractor = extractor
        self.store = store

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
        guard !voiceInput.isRecording else { return }
        do {
            try await voiceInput.startRecording()
        } catch {
            handleError(error)
        }
    }

    /// 停止录音并处理结果
    func stopRecordingAndProcess() async {
        // 取消自动处理（用户手动点击停止）
        isAutoProcessing = false

        // 使用 finishRecording() 让识别器自然完成，确保获取最终识别结果
        voiceInput.finishRecording()

        // 等待转写完成（isRecording 变为 false 表示识别结果已就绪）
        await waitForRecordingToFinish()

        // 兜底：若识别回调未及时结束，强制收敛录音状态，避免后续无法再次启动录音
        if voiceInput.isRecording {
            voiceInput.stopRecording()
        }

        // 处理转写结果
        await processTranscript(transcript)
    }

    /// 等待录音结束，最多等 3 秒
    private func waitForRecordingToFinish() async {
        guard voiceInput.isRecording else { return }
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
    }

    /// 等待自然停录（静音检测触发），最多等 60 秒
    private func waitForAutoStop() async {
        guard voiceInput.isRecording else { return }
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
    }

    /// 手动触发录音处理（用于 Action Button 启动）
    func handleActionButtonLaunch() async {
        // 确认页打开时不启动新录音，避免覆盖待确认的待办
        guard !showConfirmSheet else { return }

        isAutoProcessing = true

        await startRecording()

        // 录音未成功启动（权限错误等），直接返回
        guard voiceInput.isRecording else {
            isAutoProcessing = false
            return
        }

        // 等待自然停录（静音检测自动停止）
        await waitForAutoStop()

        // 60 秒超时后若仍在录音，主动结束输入并等待最终识别结果
        if voiceInput.isRecording {
            voiceInput.finishRecording()
            await waitForRecordingToFinish()
        }
        // 兜底收敛
        if voiceInput.isRecording {
            voiceInput.stopRecording()
        }

        // 检查是否被手动停止取消
        guard isAutoProcessing else { return }
        isAutoProcessing = false

        // 自动处理转写结果
        await processTranscript(transcript)
    }

    /// App 进入前台时处理待处理项（并发）
    func handleAppForeground() async {
        guard !isProcessingPending else { return }
        guard !isRecording, !isAutoProcessing, !isProcessingTranscript, !showConfirmSheet else { return }

        let pendingItems = store.pendingItems().filter { !dismissedPendingIds.contains($0.id) }
        guard !pendingItems.isEmpty else { return }

        isProcessingPending = true
        defer { isProcessingPending = false }

        var processResults: [PendingProcessResult] = []

        // 先移除无 rawTranscript 的条目
        let validPending = pendingItems.filter { item in
            if item.rawTranscript == nil {
                try? store.delete(item.id)
                return false
            }
            return true
        }

        let concurrency = NetworkConfig.pendingBatchConcurrency

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
                    await Self.processSinglePending(index: index, id: pendingId, transcript: transcript, extractor: ext, locale: loc)
                }
                activeCount += 1
            }

            for await result in group {
                processResults.append(result)
                // 失败的保留 pending 不处理

                if let (index, next) = iterator.next() {
                    guard networkMonitor.isConnected else { break }
                    let transcript = next.rawTranscript!
                    let nextId = next.id
                    let ext = self.extractor
                    let loc = self.voiceInput.currentLocale
                    group.addTask {
                        await Self.processSinglePending(index: index, id: nextId, transcript: transcript, extractor: ext, locale: loc)
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
            guard !isRecording, !isAutoProcessing, !isProcessingTranscript, !showConfirmSheet else { return }

            for pendingId in processedWithoutTodosIds {
                try? store.delete(pendingId)
            }

            pendingItemIds = processedWithTodosIds
            combinedRawTranscript = mergedRawTranscript
            extractedTodos = allExtractedItems
            showConfirmSheet = true
        } else {
            for pendingId in processedWithTodosIds {
                try? store.delete(pendingId)
            }
            for pendingId in processedWithoutTodosIds {
                try? store.delete(pendingId)
            }
            pendingItemIds = []
            combinedRawTranscript = nil
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
        locale: Locale
    ) async -> PendingProcessResult {
        do {
            let result = try await extractor.extract(from: transcript, locale: locale)
            return PendingProcessResult(index: index, id: id, todos: result.todos, rawTranscript: transcript, succeeded: true)
        } catch {
            #if DEBUG
            print("Failed to process pending item \(id): \(error)")
            #endif
            return PendingProcessResult(index: index, id: id, todos: [], rawTranscript: transcript, succeeded: false)
        }
    }

    /// 确认添加待办
    /// - Returns: 是否保存成功
    func confirmTodos(_ todos: [ExtractedTodo]) -> Bool {
        do {
            // 如果有 pending 条目，使用替换逻辑
            if !pendingItemIds.isEmpty {
                try store.replacePendingBatchWithExtracted(pendingItemIds, todos, rawTranscript: combinedRawTranscript)

                // 成功确认后清理 dismissed 记录（先移除再清空列表）
                dismissedPendingIds.subtract(pendingItemIds)
                pendingItemIds = []
                combinedRawTranscript = nil
            } else {
                // 正常在线流程：直接添加
                try store.addBatch(todos)
            }

            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            handleError(error)
            return false
        }
    }

    /// 取消确认
    func cancelTodos() {
        // 记录已取消的 pending ID，避免本次 session 重复弹窗
        // 不删除 pending 条目，保留离线转写数据
        dismissedPendingIds.formUnion(pendingItemIds)

        extractedTodos = []
        showConfirmSheet = false
        pendingItemIds = []
        combinedRawTranscript = nil
        isAutoProcessing = false
    }

    // MARK: - Private Methods

    /// 取消正在进行的 AI 提取
    func cancelExtraction() {
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
        isProcessingTranscript = false
        extractedTodos = []
        showConfirmSheet = false
    }

    /// 处理转写文本（流式）
    private func processTranscript(_ text: String) async {
        guard !isProcessingTranscript else { return }
        isProcessingTranscript = true
        isExtracting = true

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isExtracting = false
            isProcessingTranscript = false
            showToast(message: ErrorMessages.noTodosFound, style: .info)
            return
        }

        guard networkMonitor.isConnected else {
            isExtracting = false
            isProcessingTranscript = false
            await handleOfflineMode(transcript: text)
            return
        }

        extractionTask = Task {
            do {
                var receivedAny = false
                for try await partialResult in extractor.extractStreaming(from: trimmed, locale: voiceInput.currentLocale) {
                    guard !Task.isCancelled else { return }
                    extractedTodos = partialResult.todos
                    if !showConfirmSheet && !partialResult.todos.isEmpty {
                        showConfirmSheet = true
                    }
                    receivedAny = !partialResult.todos.isEmpty
                }

                guard !Task.isCancelled else { return }

                if !receivedAny {
                    showToast(message: ErrorMessages.noTodosFound, style: .info)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let ve = error as? VoiceTodoError,
                   ve == .networkUnavailable || ve == .apiTimeout {
                    await handleOfflineMode(transcript: text)
                } else {
                    handleError(error)
                }
            }

            isExtracting = false
            isProcessingTranscript = false
        }

        await extractionTask?.value
    }

    /// 离线降级处理
    private func handleOfflineMode(transcript: String) async {
        do {
            try store.addRawTranscript(transcript)
            showToast(message: ErrorMessages.savedOffline, style: .info)
        } catch {
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

    /// 统一错误处理
    private func handleError(_ error: Error) {
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
