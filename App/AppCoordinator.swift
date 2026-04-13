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

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var isProcessingPending = false

    /// 离线待处理条目 ID 列表（用于网络恢复后替换）
    private var pendingItemIds: [UUID] = []

    // MARK: - Initialization

    init(
        voiceInput: some VoiceInputProtocol,
        extractor: some TodoExtractorProtocol,
        store: some TodoStoreProtocol
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
    }

    // MARK: - Public Methods

    /// 启动录音流程
    func startRecording() async {
        do {
            try await voiceInput.startRecording()
        } catch {
            handleError(error)
        }
    }

    /// 停止录音并处理结果
    func stopRecordingAndProcess() async {
        voiceInput.stopRecording()

        // 等待转写完成（isRecording 变为 false 表示识别结果已就绪）
        await waitForRecordingToFinish()

        // 处理转写结果
        await processTranscript(transcript)
    }

    /// 等待录音结束，最多等 3 秒
    private func waitForRecordingToFinish() async {
        guard voiceInput.isRecording else { return }

        await withTaskGroup(of: Void.self) { group in
            // 任务 1：轮询等待 isRecording 变为 false
            group.addTask {
                while self.voiceInput.isRecording {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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

    /// 手动触发录音处理（用于 Action Button 启动）
    func handleActionButtonLaunch() async {
        // 直接开始录音
        await startRecording()
    }

    /// App 进入前台时处理待处理项
    func handleAppForeground() async {
        guard !isProcessingPending else { return }

        let pendingItems = store.pendingItems()
        guard !pendingItems.isEmpty else { return }

        isProcessingPending = true

        // 记录 pending ID（用于后续替换）
        pendingItemIds = pendingItems.map { $0.id }

        // 后台静默处理
        var allExtractedItems: [ExtractedTodo] = []

        for pending in pendingItems {
            guard let transcript = pending.rawTranscript else { continue }

            guard networkMonitor.isConnected else {
                continue
            }

            do {
                let result = try await extractor.extract(from: transcript)
                allExtractedItems.append(contentsOf: result.todos)
            } catch {
                #if DEBUG
                print("Failed to process pending item: \(error)")
                #endif
            }
        }

        isProcessingPending = false

        // 有结果则显示一次性确认
        if !allExtractedItems.isEmpty {
            extractedTodos = allExtractedItems
            showConfirmSheet = true
        } else {
            // 无结果时清空 pending ID 列表
            pendingItemIds = []
        }
    }

    /// 确认添加待办
    func confirmTodos(_ todos: [ExtractedTodo]) {
        do {
            // 如果有 pending 条目，使用替换逻辑
            if let firstPendingId = pendingItemIds.first {
                // 将所有提取的待办分配到第一个 pending（因为原始 pending 可能拆分成多个待办）
                // 调用替换方法：删除原始 pending，添加提取的待办
                try store.replacePendingWithExtracted(firstPendingId, todos)

                // 删除其他多余的 pending（如果有多个离线条目）
                for pendingId in pendingItemIds.dropFirst() {
                    try store.delete(pendingId)
                }

                // 清空 pending ID 列表
                pendingItemIds = []
            } else {
                // 正常在线流程：直接添加
                try store.addBatch(todos)
            }

            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            handleError(error)
        }
    }

    /// 取消确认
    func cancelTodos() {
        extractedTodos = []
        showConfirmSheet = false
        pendingItemIds = []  // 清空 pending ID 列表
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
            await handleOfflineMode(transcript: text)
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
    private func showToast(message: String, style: ToastStyle) {
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

// MARK: - Batch Confirm View

/// 批量确认视图（用于网络恢复后的补处理）
struct BatchConfirmView: View {
    @Binding var todos: [ExtractedTodo]
    let onConfirm: ([ExtractedTodo]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach($todos) { $todo in
                    BatchTodoItemRow(
                        todo: $todo,
                        todos: $todos
                    )
                }
            }
            .navigationTitle("已整理的待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("跳过") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("全部添加") {
                        onConfirm(todos)
                        dismiss()
                    }
                    .disabled(todos.isEmpty)
                }
            }
        }
    }
}

/// 辅助视图：批量确认中的待办行（使用 ID 删除，避免索引问题）
private struct BatchTodoItemRow: View {
    @Binding var todo: ExtractedTodo
    @Binding var todos: [ExtractedTodo]

    var body: some View {
        TodoItemRow(
            todo: $todo,
            onDelete: {
                withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                    todos.removeAll { $0.id == todo.id }
                }
            }
        )
    }
}
