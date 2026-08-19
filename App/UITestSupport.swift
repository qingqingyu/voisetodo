import Foundation
import Combine

@MainActor
final class UITestVoiceInputManager: VoiceInputProtocol {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?
    @Published var didAutoFinishDueToSilence: Bool = false
    @Published var audioLevel: Float = 0
    let currentLocale: Locale = Locale(identifier: "zh-Hans")

    private let options: UITestLaunchOptions

    init(options: UITestLaunchOptions = .current) {
        self.options = options
    }

    var isRecordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { $error.eraseToAnyPublisher() }
    var didAutoFinishDueToSilencePublisher: AnyPublisher<Bool, Never> { $didAutoFinishDueToSilence.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { $audioLevel.eraseToAnyPublisher() }
    var recordingSuccessPublisher: AnyPublisher<Void, Never> { Empty<Void, Never>().eraseToAnyPublisher() }

    func startRecording() async throws {
        if options.micPermissionDenied {
            throw VoiceTodoError.microphonePermissionDenied
        }
        if options.speechPermissionDenied {
            throw VoiceTodoError.speechRecognitionPermissionDenied
        }

        error = nil
        transcript = options.mockTranscript
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    func cancelRecordingDueToInterruption() {
        isRecording = false
        error = .audioSessionInterrupted
    }

    func cancelRecordingByUser() {
        isRecording = false
    }

    func finishRecording() {
        stopRecording()
    }
}

struct UITestTodoExtractor: TodoExtractorProtocol {
    private let options: UITestLaunchOptions

    init(options: UITestLaunchOptions = .current) {
        self.options = options
    }

    func extract(from transcript: String, locale: Locale) async throws -> ExtractionResult {
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

        // G2(S18a):落今天的单条。兜底分支恒给 dueHint nil(无日期),
        // 必须显式给 dueHint 才能让 TodoDueDateResolver 解析出今天。
        if normalized.contains("今晚八点") {
            return ExtractionResult(
                todos: [
                    ExtractedTodo(title: "给妈妈打电话", detail: normalized, dueHint: "今晚", priority: .normal, categoryHint: .social)
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

    func extractStreaming(from transcript: String, locale: Locale) -> AsyncThrowingStream<ExtractionResult, Error> {
        guard options.scenario == "streaming-partial" else {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        continuation.yield(try await extract(from: transcript, locale: locale))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        let first = ExtractedTodo(title: "第一条待办", detail: transcript, priority: .normal, categoryHint: .work)
        let second = ExtractedTodo(title: "第二条待办", detail: transcript, priority: .normal, categoryHint: .life)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    continuation.yield(ExtractionResult(todos: [first], ignored: ""))

                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    try Task.checkCancellation()
                    continuation.yield(ExtractionResult(todos: [first, second], ignored: ""))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
