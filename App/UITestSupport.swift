import Foundation
import Combine

@MainActor
final class UITestVoiceInputManager: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?

    private let options: UITestLaunchOptions

    init(options: UITestLaunchOptions = .current) {
        self.options = options
    }

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }

    func startRecording() async throws {
        if options.micPermissionDenied {
            throw VoiceTodoError.microphonePermissionDenied
        }

        error = nil
        transcript = options.mockTranscript
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    func finishRecording() {
        stopRecording()
    }
}

struct UITestTodoExtractor: TodoExtractorProtocol {
    func extract(from transcript: String) async throws -> ExtractionResult {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("好累") {
            return ExtractionResult(
                todos: [],
                ignored: "最近好累，什么都不想干（纯感受，无行动意图）"
            )
        }

        if normalized.contains("报告") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(
                        title: "交报告",
                        detail: normalized,
                        dueHint: normalized.contains("今天") ? "今天" : nil,
                        priority: .high,
                        categoryHint: .work
                    )
                ],
                ignored: ""
            )
        }

        if normalized.contains("银行") && normalized.contains("买菜") && normalized.contains("老妈") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "去银行办卡", detail: "明天去银行办卡", dueHint: "明天", priority: .normal, categoryHint: .finance),
                    ExtractedTodo(title: "买菜", detail: "顺便买菜", dueHint: nil, priority: .normal, categoryHint: .life),
                    ExtractedTodo(title: "给老妈打电话", detail: "晚上给老妈打电话", dueHint: "晚上", priority: .normal, categoryHint: .social)
                ],
                ignored: ""
            )
        }

        if normalized.contains("银行") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "去银行", detail: normalized, dueHint: normalized.contains("明天") ? "明天" : nil, priority: .normal, categoryHint: .finance)
                ],
                ignored: ""
            )
        }

        return ExtractionResult(
            todos: [
                ExtractedTodo(
                    title: TextUtils.truncateTitle(from: normalized, maxLength: 10),
                    detail: normalized,
                    dueHint: nil,
                    priority: .normal,
                    categoryHint: .other
                )
            ],
            ignored: ""
        )
    }
}
