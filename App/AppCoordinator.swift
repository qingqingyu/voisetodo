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
    @Published var deepLinkTodoId: UUID?

    /// 确认页应显示的语音原文（pending 场景使用合并的原始转写）
    var confirmSheetTranscript: String {
        combinedRawTranscript ?? transcript
    }

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var isProcessingPending = false

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

        // 检查是否被手动停止取消
        guard isAutoProcessing else { return }
        isAutoProcessing = false

        // 自动处理转写结果
        await processTranscript(transcript)
    }

    /// App 进入前台时处理待处理项
    func handleAppForeground() async {
        guard !isProcessingPending else { return }

        let pendingItems = store.pendingItems().filter { !dismissedPendingIds.contains($0.id) }
        guard !pendingItems.isEmpty else { return }

        isProcessingPending = true

        // 记录 pending ID（用于后续替换）
        pendingItemIds = pendingItems.map { $0.id }

        // 后台静默处理
        var allExtractedItems: [ExtractedTodo] = []
        var successfullyProcessedIds: [UUID] = []
        var rawTranscripts: [String] = []

        for pending in pendingItems {
            guard let transcript = pending.rawTranscript else {
                // 无转写文本的条目无法处理，直接删除（不应出现，防御性处理）
                try? store.delete(pending.id)
                continue
            }

            guard networkMonitor.isConnected else {
                // 网络中断，停止处理剩余条目，保留未处理的 pending
                break
            }

            do {
                let result = try await extractor.extract(from: transcript)
                if !result.todos.isEmpty {
                    allExtractedItems.append(contentsOf: result.todos)
                    successfullyProcessedIds.append(pending.id)
                    rawTranscripts.append(transcript)
                } else {
                    // AI 未提取到待办，也视为处理完成
                    successfullyProcessedIds.append(pending.id)
                }
            } catch {
                #if DEBUG
                print("Failed to process pending item: \(error)")
                #endif
                // 提取失败，保留该 pending 不删除
            }
        }

        // 只记录成功处理的 pending ID
        pendingItemIds = successfullyProcessedIds

        // 合并 rawTranscript（多个 pending 条目时拼接，避免丢失）
        combinedRawTranscript = rawTranscripts.isEmpty ? nil : rawTranscripts.joined(separator: "\n---\n")

        isProcessingPending = false

        // 有结果则显示一次性确认
        if !allExtractedItems.isEmpty {
            extractedTodos = allExtractedItems
            showConfirmSheet = true
        } else {
            // 无结果：删除已处理的 pending 条目（AI 判断无行动项）
            for pendingId in successfullyProcessedIds {
                try? store.delete(pendingId)
            }
            pendingItemIds = []
            combinedRawTranscript = nil
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

    /// 处理转写文本
    private func processTranscript(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(message: ErrorMessages.noTodosFound, style: .info)
            return
        }

        guard networkMonitor.isConnected else {
            await handleOfflineMode(transcript: text)
            return
        }

        do {
            let result = try await extractor.extract(from: text)

            if result.todos.isEmpty {
                showToast(message: ErrorMessages.noTodosFound, style: .info)
            } else {
                extractedTodos = result.todos
                showConfirmSheet = true
            }
        } catch {
            if let voiceError = error as? VoiceTodoError, voiceError == .networkUnavailable {
                await handleOfflineMode(transcript: text)
            } else {
                handleError(error)
            }
        }
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
    func showToast(message: String, style: ToastStyle) {
        toastMessage = message
        toastStyle = style
        showToast = true
    }

    /// 统一错误处理
    private func handleError(_ error: Error) {
        if let voiceError = error as? VoiceTodoError {
            switch voiceError {
            case .microphonePermissionDenied:
                showToast(message: ErrorMessages.micDenied, style: .warning)
            case .speechRecognitionPermissionDenied:
                showToast(message: ErrorMessages.speechDenied, style: .warning)
            case .speechRecognitionUnavailable:
                showToast(message: ErrorMessages.speechUnavailable, style: .warning)
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
