import Foundation
import Combine
import WidgetKit

/// App 协调器（Agent E 实现）
/// 负责编排完整的语音录入流程
@MainActor
final class AppCoordinator: ObservableObject {
    // MARK: - Dependencies

    private let voiceInput: VoiceInputProtocol
    private let extractor: TodoExtractorProtocol
    private let store: TodoStoreProtocol
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

    // MARK: - Initialization

    init(
        voiceInput: VoiceInputProtocol,
        extractor: TodoExtractorProtocol,
        store: TodoStoreProtocol
    ) {
        self.voiceInput = voiceInput
        self.extractor = extractor
        self.store = store

        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // 监听录音状态
        voiceInput.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        // 监听转写文本
        voiceInput.$transcript
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

        // 等待转写完成
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 处理转写结果
        await processTranscript(transcript)
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

        // 后台静默处理
        var allExtractedItems: [ExtractedTodo] = []

        for pending in pendingItems {
            guard let transcript = pending.rawTranscript else { continue }

            // P1 修复: 使用 NetworkMonitor 检查网络
            guard networkMonitor.isConnected else {
                // 无网络，跳过此项
                continue
            }

            do {
                let result = try await extractor.extract(from: transcript)
                allExtractedItems.append(contentsOf: result.todos)
            } catch {
                // 单条失败不影响其他
                print("Failed to process pending item: \(error)")
            }
        }

        isProcessingPending = false

        // 有结果则显示一次性确认
        if !allExtractedItems.isEmpty {
            extractedTodos = allExtractedItems
            showConfirmSheet = true
        }
    }

    /// 确认添加待办
    func confirmTodos(_ todos: [ExtractedTodo]) {
        do {
            try store.addBatch(todos)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            handleError(error)
        }
    }

    /// 取消确认
    func cancelTodos() {
        extractedTodos = []
        showConfirmSheet = false
    }

    // MARK: - Private Methods

    /// 处理转写文本
    private func processTranscript(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(message: ErrorMessages.noTodosFound, style: .info)
            return
        }

        // P1 修复: 使用 NetworkMonitor 检查网络（替代简单的 URL 请求）
        guard networkMonitor.isConnected else {
            // 无网络，离线降级
            await handleOfflineMode(transcript: text)
            return
        }

        // 有网络，尝试 AI 提取
        do {
            let result = try await extractor.extract(from: text)

            // 检查是否有待办
            if result.todos.isEmpty {
                // 无待办（纯感受）
                showToast(message: ErrorMessages.noTodosFound, style: .info)
            } else {
                // 有待办，弹出确认
                extractedTodos = result.todos
                showConfirmSheet = true
            }
        } catch {
            // AI 提取失败，离线降级
            await handleOfflineMode(transcript: text)
        }
    }

    /// 离线降级处理
    private func handleOfflineMode(transcript: String) async {
        do {
            // 保存原始转写
            try store.addRawTranscript(transcript)

            // 显示提示
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
                ForEach(Array(todos.enumerated()), id: \.element.id) { index, _ in
                    TodoItemRow(
                        todo: $todos[index],
                        onDelete: {
                            todos.remove(at: index)
                        }
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
