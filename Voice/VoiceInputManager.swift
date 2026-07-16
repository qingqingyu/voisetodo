import Foundation
import Combine
import Speech
import AVFoundation
import ActivityKit

/// 语音输入管理器
/// 实现 VoiceInputProtocol，封装 Apple Speech Framework
@MainActor
final class VoiceInputManager: VoiceInputProtocol {
    // MARK: - VoiceInputProtocol Properties

    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var error: VoiceTodoError?
    @Published var didAutoFinishDueToSilence: Bool = false
    @Published var audioLevel: Float = 0

    // MARK: - Publisher Accessors (协议要求)

    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        $isRecording.eraseToAnyPublisher()
    }

    var transcriptPublisher: AnyPublisher<String, Never> {
        $transcript.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> {
        $error.eraseToAnyPublisher()
    }

    var didAutoFinishDueToSilencePublisher: AnyPublisher<Bool, Never> {
        $didAutoFinishDueToSilence.eraseToAnyPublisher()
    }

    var audioLevelPublisher: AnyPublisher<Float, Never> {
        $audioLevel.eraseToAnyPublisher()
    }

    // MARK: - Public Properties

    /// 当前识别 locale。`private(set)`——外部只读，写入由 `startRecording` 在每次
    /// 录音前根据用户设置（`SpeechRecognitionLanguage.storageKey`）刷新。
    /// 协议 `VoiceInputProtocol.currentLocale` 声明为 `{ get }`，外部读访问兼容。
    ///
    /// 注意：此值仅在 `startRecording` 入口刷新。`AppCoordinator` 在录音进行中或
    /// 刚结束时读取此属性拿到的都是上次 `startRecording` 时的 locale——这是有意的,
    /// 因为识别结果对应的 locale 应该与录音开始时一致，不应中途变化。
    private(set) var currentLocale: Locale

    // MARK: - Private Properties

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let audioSessionHelper = AudioSessionHelper()
    private let vocabularyProvider: any UserVocabularyProviding

    // 静音自动提交：用户说完话后 1.5s 静音即自动 finishRecording + 触发提交。
    // 仅在已有转写内容时触发——用户没说话不自动提交（避免空 transcript 送 AI）。
    // 与旧版区别：路由到 finishRecording（等识别完成）而非 stopRecording（直接断 → 僵尸态）。
    private var silenceStartTime: Date?
    // max-duration + silence 共用的去重 flag，避免回调重复触发 stop
    private var isSilenceDetected = false
    // finishRecording 去重 flag：静音自动提交调一次 finishRecording 后，
    // HomeView 的 onChange 再触发 stopRecordingAndProcess → finishRecording 会被二次调用。
    // 此 flag 让第二次调用安全跳过，避免重复 stop/removeTap/endAudio/deactivate。
    private var hasFinishedRecording = false

    // Live Activity 相关
    private var liveActivity: Activity<RecordingActivityAttributes>?
    private var recordingStartTime: Date?
    private var updateTimer: Timer?
    private var finishRecordingWatchdogTask: Task<Void, Never>?
    private var interruptionBeganObserver: NSObjectProtocol?
    private var recordingSessionID: String?

    // MARK: - Initialization

    init(vocabularyProvider: any UserVocabularyProviding = UserVocabularyStore.shared) {
        let locale = VoiceInputManager.resolveCurrentLocale()
        self.currentLocale = locale
        self.vocabularyProvider = vocabularyProvider
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - VoiceInputProtocol Methods

    /// 开始录音
    func startRecording() async throws {
        guard !isRecording else {
            VoiceTodoLog.voice.warning("recording.start.ignored reason=already_recording activeID=\(self.recordingSessionID ?? "none", privacy: .public)")
            return
        }

        // 用户可能在上次录音结束后改了设置页的语言选项。每次开始录音前重新解析一次,
        // 如果跟当前 currentLocale 不同就重建 SFSpeechRecognizer——
        // 识别器对象本身是廉价的(不预加载模型),重建成本可忽略,
        // 比让用户改了设置必须重启 App 才生效好得多。
        // 若新 locale 无法创建识别器（设备不支持），保留旧识别器并回退到旧 locale,
        // 避免用户切到不支持的 locale 后丢失可用的识别器。
        let desired = VoiceInputManager.resolveCurrentLocale()
        if desired.identifier != currentLocale.identifier {
            if let newRecognizer = SFSpeechRecognizer(locale: desired) {
                VoiceTodoLog.voice.info("locale.rotated old=\(self.currentLocale.identifier, privacy: .public) new=\(desired.identifier, privacy: .public)")
                speechRecognizer = newRecognizer
                currentLocale = desired
            } else {
                VoiceTodoLog.voice.error("locale.rotation_failed unsupported_locale=\(desired.identifier, privacy: .public) keeping=\(self.currentLocale.identifier, privacy: .public)")
            }
        }

        let sessionID = VoiceTodoLog.makeID("recording")
        recordingSessionID = sessionID
        let startedAt = Date()
        VoiceTodoLog.voice.info("recording.start id=\(sessionID, privacy: .public) locale=\(self.currentLocale.identifier, privacy: .public)")

        // 清空之前的状态
        cancelFinishRecordingWatchdog()
        transcript = ""
        error = nil
        isSilenceDetected = false
        silenceStartTime = nil
        hasFinishedRecording = false
        didAutoFinishDueToSilence = false
        audioLevel = 0
        recordingStartTime = startedAt

        // 1. 检查权限
        do {
            try await checkPermissions()
            VoiceTodoLog.voice.info("recording.permissions.ready id=\(sessionID, privacy: .public)")
        } catch {
            VoiceTodoLog.voice.error("recording.permissions.failed id=\(sessionID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            recordingSessionID = nil
            recordingStartTime = nil
            throw error
        }

        // 2. 配置音频会话
        do {
            try audioSessionHelper.configureSession()
            VoiceTodoLog.voice.info("recording.audio_session.configured id=\(sessionID, privacy: .public)")
        } catch {
            VoiceTodoLog.voice.error("recording.audio_session.failed id=\(sessionID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            cleanupRecordingPipeline(markNotRecording: true, reason: "audioSessionStartFailure")
            throw error
        }

        // 3. 检查语音识别器可用性
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            VoiceTodoLog.voice.error("recording.recognizer.unavailable id=\(sessionID, privacy: .public) recognizerExists=\(self.speechRecognizer != nil)")
            cleanupRecordingPipeline(markNotRecording: true, reason: "recognizerUnavailable")
            throw VoiceTodoError.speechRecognitionUnavailable
        }

        // 4. 创建识别请求并启动识别任务
        do {
            try startRecognition(recognizer: recognizer)
            VoiceTodoLog.voice.info("recording.recognition.started id=\(sessionID, privacy: .public)")
        } catch {
            VoiceTodoLog.voice.error("recording.recognition.start_failed id=\(sessionID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            cleanupRecordingPipeline(markNotRecording: true, reason: "recognitionStartFailure")
            throw error
        }

        // 5. 配置音频输入和静音检测
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 防御性移除旧 tap，避免重复安装导致 crash
        inputNode.removeTap(onBus: 0)

        // 在主线程捕获 recognitionRequest 的局部引用，避免 tap 回调跨 @MainActor 边界
        // 访问 self.recognitionRequest 属性（数据竞争隐患）。
        // SFSpeechAudioBufferRecognitionRequest.append() 本身是线程安全的（Apple 文档），
        // 用局部引用避免属性读取的竞态即可。
        let request = recognitionRequest
        // 安装音频 tap：喂音频给识别器 + max-duration 检查
        inputNode.installTap(
            onBus: 0,
            bufferSize: VoiceConstants.audioBufferSize,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            // 必须在 tap 回调线程直接 append——SFSpeechAudioBufferRecognitionRequest
            // 靠这个拿音频数据，不 append 识别器永远拿不到音频，转写为空。
            request?.append(buffer)
            // max-duration + 静音检测派发到主线程，避免与 stopRecording 竞态
            DispatchQueue.main.async {
                self?.processAudioBuffer(buffer)
            }
        }

        // 6. 启动音频引擎
        do {
            try audioEngine.start()
            isRecording = true
            VoiceTodoLog.voice.info("recording.engine.started id=\(sessionID, privacy: .public) sampleRate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")

            // 7. 监听音频会话中断和路由变更
            audioSessionHelper.startObserving()

            // 7.1 监听音频中断；v1 策略是明确取消本次录音，不自动恢复。
            removeInterruptionObservers()
            interruptionBeganObserver = NotificationCenter.default.addObserver(
                forName: .audioSessionInterruptionBegan,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelRecordingDueToInterruption()
            }

            // 8. 启动 Live Activity
            startLiveActivity()
        } catch {
            // 启动失败时清理已安装的 tap
            VoiceTodoLog.voice.error("recording.engine.start_failed id=\(sessionID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            cleanupRecordingPipeline(markNotRecording: true, reason: "engineStartFailure")
            throw VoiceTodoError.recordingFailed("无法启动音频引擎")
        }
    }

    /// 停止录音
    func stopRecording() {
        guard isRecording else {
            VoiceTodoLog.voice.debug("recording.stop.ignored activeID=\(self.recordingSessionID ?? "none", privacy: .public) reason=not_recording")
            return
        }

        cleanupRecordingPipeline(markNotRecording: true, reason: "stopRecording")
    }

    func cancelRecordingDueToInterruption() {
        guard isRecording else {
            VoiceTodoLog.voice.debug("recording.interruption.ignored activeID=\(self.recordingSessionID ?? "none", privacy: .public) reason=not_recording")
            return
        }
        VoiceTodoLog.voice.warning("recording.interrupted id=\(self.recordingSessionID ?? "none", privacy: .public) transcriptChars=\(self.transcript.count)")
        let durationMS = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        Telemetry.record(.recordingOutcome(outcome: .interrupted, durationMS: durationMS, transcript: transcript))
        cleanupRecordingPipeline(markNotRecording: true, reason: "interruption")
        error = .audioSessionInterrupted
    }

    /// 用户主动取消当前录音（点击关闭/切换模式等）。
    /// 与 `cancelRecordingDueToInterruption` 的差别：
    /// - 不设置 `error`（不弹 toast，用户已知）
    /// - Telemetry 记 `userCancelled` 而非 `interrupted`，便于在数据中区分主动/被动结束。
    func cancelRecordingByUser() {
        guard isRecording else {
            VoiceTodoLog.voice.debug("recording.cancel_user.ignored activeID=\(self.recordingSessionID ?? "none", privacy: .public) reason=not_recording")
            return
        }
        VoiceTodoLog.voice.info("recording.cancelled_by_user id=\(self.recordingSessionID ?? "none", privacy: .public) transcriptChars=\(self.transcript.count)")
        let durationMS = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        Telemetry.record(.recordingOutcome(outcome: .userCancelled, durationMS: durationMS, transcript: transcript))
        cleanupRecordingPipeline(markNotRecording: true, reason: "user_cancel")
    }

    /// 通知识别器音频输入结束，等待最终识别结果
    /// 与 stopRecording() 不同，此方法不取消识别任务，
    /// 而是让 Apple Speech Framework 自然完成识别，
    /// 最终结果回调触发 stopRecording() 确保 transcript 是最终版本。
    func finishRecording() {
        guard isRecording else {
            VoiceTodoLog.voice.debug("recording.finish.ignored activeID=\(self.recordingSessionID ?? "none", privacy: .public) reason=not_recording")
            return
        }
        guard !hasFinishedRecording else {
            VoiceTodoLog.voice.debug("recording.finish.ignored activeID=\(self.recordingSessionID ?? "none", privacy: .public) reason=already_finished")
            return
        }
        hasFinishedRecording = true

        VoiceTodoLog.voice.info("recording.finish.requested id=\(self.recordingSessionID ?? "none", privacy: .public) transcriptChars=\(self.transcript.count)")

        // 停止音频引擎（不再输入新音频）
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // 通知识别器音频输入结束（不取消任务，等待最终识别结果）
        recognitionRequest?.endAudio()

        // 停用音频会话并停止监听中断通知
        audioSessionHelper.stopObserving()
        audioSessionHelper.deactivateSession()

        // 移除中断通知监听
        removeInterruptionObservers()

        startFinishRecordingWatchdog()

        // 注意：不设置 isRecording = false，等待 recognitionTask 的 isFinal 回调触发 stopRecording()
        // 这样可以确保 transcript 是最终识别结果
    }

    // MARK: - Recognition Pipeline

    /// 创建识别请求并启动识别任务
    /// 从 startRecording() 提取，便于中断恢复时复用
    private func startRecognition(recognizer: SFSpeechRecognizer) throws {
        // 清理旧的识别任务
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // 创建新的识别请求
        let request = makeRecognitionRequest()
        recognitionRequest = request

        // 启动识别任务
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                // 更新转写文本（派发到主线程，确保 @Published 属性线程安全）
                let newTranscript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = newTranscript
                    self.updateLiveActivity(transcript: newTranscript)
                }

                // 如果是最终结果，停止录音（派发到主线程避免与 processAudioBuffer 竞态）
                if result.isFinal {
                    DispatchQueue.main.async {
                        VoiceTodoLog.voice.info("recording.recognition.final id=\(self.recordingSessionID ?? "none", privacy: .public) transcriptChars=\(newTranscript.count)")
                        let durationMS = self.recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
                        Telemetry.record(.recordingOutcome(outcome: .success, durationMS: durationMS, transcript: self.transcript))
                        self.stopRecording()
                    }
                }
            }

            if let error = error {
                let isFinal = result?.isFinal ?? true
                if isFinal {
                    // 识别终止且伴随错误，设置错误状态让 UI 可感知
                    DispatchQueue.main.async {
                        // 已被看门狗/正常停止收敛时，忽略陈旧的取消回调，避免覆盖既有错误
                        guard self.isRecording else { return }
                        // 识别器初始化失败（模拟器缺 Siri asset / runtime 故障）映射为
                        // speechRecognitionUnavailable，让上层能自动切键盘 fallback，
                        // 而不是弹"录音失败"toast 让用户干瞪眼。
                        // kLSRErrorDomain Code=300 = "Failed to initialize recognizer"
                        let mapped: VoiceTodoError
                        if let nsError = error as? NSError,
                           nsError.domain == "kLSRErrorDomain",
                           nsError.code == 300 {
                            mapped = .speechRecognitionUnavailable
                        } else {
                            mapped = VoiceTodoError.recordingFailed(error.localizedDescription)
                        }
                        self.error = mapped
                        VoiceTodoLog.voice.error("recording.recognition.final_error id=\(self.recordingSessionID ?? "none", privacy: .public) isFinal=\(isFinal) error=\(VoiceTodoLog.errorSummary(error), privacy: .public) mapped=\(mapped, privacy: .public)")
                        Telemetry.record(.recordingFailed(reason: "recognition_error", errorCode: nil))
                        self.cleanupRecordingPipeline(markNotRecording: true, reason: "recognitionError")
                    }
                }
                DispatchQueue.main.async {
                    VoiceTodoLog.voice.error("recording.recognition.error id=\(self.recordingSessionID ?? "none", privacy: .public) isFinal=\(isFinal) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                }
            }
        }
    }

    func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        Self.makeRecognitionRequest(
            localeIdentifier: currentLocale.identifier,
            vocabularyProvider: vocabularyProvider
        )
    }

    static func makeRecognitionRequest(
        localeIdentifier: String,
        vocabularyProvider: any UserVocabularyProviding
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let hints = vocabularyProvider.vocabularyHints(
            localeIdentifier: localeIdentifier,
            limit: UserVocabularyConfig.speechContextualStringsLimit
        )
        request.contextualStrings = hints
        VoiceTodoLog.voice.info("recording.recognition.request_configured locale=\(localeIdentifier, privacy: .public) contextualStrings=\(hints.count)")
        return request
    }

    // MARK: - Live Activity Methods

    /// 启动 Live Activity（Dynamic Island 录音状态）
    private func startLiveActivity() {
        guard #available(iOS 16.2, *) else { return }

        // 检查是否已授权 Live Activity
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            VoiceTodoLog.voice.info("live_activity.disabled recordingID=\(self.recordingSessionID ?? "none", privacy: .public)")
            return
        }

        // 创建初始状态
        let attributes = RecordingActivityAttributes(name: "VoiceTodo")
        let initialState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            transcript: "",
            duration: 0
        )

        do {
            // 请求启动 Activity
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            self.liveActivity = activity
            VoiceTodoLog.voice.info("live_activity.started recordingID=\(self.recordingSessionID ?? "none", privacy: .public) activityID=\(activity.id, privacy: .public)")

            // 启动定时器更新时长
            startUpdateTimer()

        } catch {
            VoiceTodoLog.voice.error("live_activity.start_failed recordingID=\(self.recordingSessionID ?? "none", privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    /// 更新 Live Activity 状态
    private func updateLiveActivity(transcript: String) {
        guard let activity = liveActivity,
              let startTime = recordingStartTime else { return }

        let duration = Date().timeIntervalSince(startTime)
        let updatedState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            transcript: transcript,
            duration: duration
        )

        Task {
            let content = ActivityContent(state: updatedState, staleDate: nil)
            await activity.update(content)
        }
    }

    /// 结束 Live Activity
    private func endLiveActivity() {
        // 停止定时器
        stopUpdateTimer()

        let finalTranscript = transcript
        let finalTranscriptChars = transcript.count
        let finalDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        defer {
            liveActivity = nil
            recordingStartTime = nil
        }

        guard let activity = liveActivity else { return }

        Task {
            // 创建最终状态
            let finalState = RecordingActivityAttributes.ContentState(
                isRecording: false,
                transcript: finalTranscript,
                duration: finalDuration
            )

            // 结束 Activity
            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
            VoiceTodoLog.voice.info("live_activity.ended activityID=\(activity.id, privacy: .public) transcriptChars=\(finalTranscriptChars) duration=\(finalState.duration)")
        }
    }

    /// 启动定时器更新 Live Activity 时长
    private func startUpdateTimer() {
        stopUpdateTimer()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.isRecording,
                  let startTime = self.recordingStartTime else { return }

            let duration = Date().timeIntervalSince(startTime)
            let updatedState = RecordingActivityAttributes.ContentState(
                isRecording: true,
                transcript: self.transcript,
                duration: duration
            )

            Task { [weak self] in
                let content = ActivityContent(state: updatedState, staleDate: nil)
                await self?.liveActivity?.update(content)
            }
        }
    }

    /// 停止定时器
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func startFinishRecordingWatchdog() {
        cancelFinishRecordingWatchdog()
        VoiceTodoLog.voice.debug("recording.watchdog.started id=\(self.recordingSessionID ?? "none", privacy: .public) timeoutSeconds=\(VoiceConstants.finishRecordingWatchdogTimeoutSeconds)")
        finishRecordingWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(VoiceConstants.finishRecordingWatchdogTimeoutSeconds * 1_000_000_000)
                )
            } catch {
                return
            }
            await self?.handleFinishRecordingWatchdogExpired()
        }
    }

    private func cancelFinishRecordingWatchdog() {
        finishRecordingWatchdogTask?.cancel()
        finishRecordingWatchdogTask = nil
    }

    private func handleFinishRecordingWatchdogExpired() {
        guard isRecording else { return }
        VoiceTodoLog.voice.error("recording.watchdog.expired id=\(self.recordingSessionID ?? "none", privacy: .public) transcriptChars=\(self.transcript.count)")
        let durationMS = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        Telemetry.record(.recordingOutcome(outcome: .watchdogExpired, durationMS: durationMS, transcript: transcript))
        cleanupRecordingPipeline(markNotRecording: true, reason: "finishWatchdog")
        error = .recordingFailed("识别超时")
    }

    private func removeInterruptionObservers() {
        if let observer = interruptionBeganObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionBeganObserver = nil
        }
    }

    /// 清理录音管道：停 audioEngine、取消识别任务、停观察者、清状态。
    /// **不动 `error` 字段** —— 由调用方按场景决定（中断设 `.audioSessionInterrupted`，
    /// 用户取消不设）。这是 `cancelRecordingDueToInterruption` 与 `cancelRecordingByUser`
    /// 的关键差别，不要在此处隐式重置或设置 error。
    private func cleanupRecordingPipeline(markNotRecording: Bool, reason: String) {
        let sessionID = recordingSessionID ?? "none"
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        VoiceTodoLog.voice.info("recording.cleanup id=\(sessionID, privacy: .public) reason=\(reason, privacy: .public) markNotRecording=\(markNotRecording) transcriptChars=\(self.transcript.count) duration=\(duration)")

        cancelFinishRecordingWatchdog()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        audioSessionHelper.stopObserving()
        audioSessionHelper.deactivateSession()
        removeInterruptionObservers()

        if markNotRecording {
            isRecording = false
        }
        isSilenceDetected = false
        silenceStartTime = nil
        hasFinishedRecording = false
        audioLevel = 0
        endLiveActivity()
        recordingSessionID = nil
    }

    // MARK: - Permission Methods [v2]

    /// 请求麦克风权限
    static func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                VoiceTodoLog.voice.info("permission.microphone.request_result granted=\(granted)")
                continuation.resume(returning: granted)
            }
        }
    }

    /// 请求语音识别权限
    static func requestSpeechPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                VoiceTodoLog.voice.info("permission.speech.request_result status=\(String(describing: status), privacy: .public)")
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Private Methods

    /// 解析当前应该使用的 locale。
    ///
    /// 优先级：用户的显式选择（`SpeechRecognitionLanguage.storageKey`）>
    /// 系统首选语言（`auto` 模式）> 英文兜底。
    ///
    /// **每次 `init` 和 `startRecording` 都调用一次**——这让用户在设置页改了之后，
    /// 下次录音立即生效（不用重启 App，不需要重建 VoiceInputManager）。
    private static func resolveCurrentLocale() -> Locale {
        let stored = UserDefaults.standard.string(forKey: SpeechRecognitionLanguage.storageKey)
            ?? SpeechRecognitionLanguage.auto.rawValue
        let choice = SpeechRecognitionLanguage(rawValue: stored) ?? .auto
        if let fixed = choice.fixedLocale {
            VoiceTodoLog.voice.info("locale.user_selected choice=\(choice.rawValue, privacy: .public) selected=\(fixed.identifier, privacy: .public)")
            return fixed
        }
        return resolveSystemLocale()
    }

    /// `auto` 模式下的系统首选语言匹配。
    private static func resolveSystemLocale() -> Locale {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en-US"

        // 检查是否支持
        for locale in VoiceConstants.supportedLocales {
            if preferredLanguage.hasPrefix(locale.languageCode ?? "") {
                VoiceTodoLog.voice.info("locale.system preferred=\(preferredLanguage, privacy: .public) selected=\(locale.identifier, privacy: .public)")
                return locale
            }
        }

        // 非中文/英文系统回退到英文（国际通用）
        VoiceTodoLog.voice.info("locale.fallback preferred=\(preferredLanguage, privacy: .public) selected=en-US")
        return Locale(identifier: "en-US")
    }

    /// 检查权限
    private func checkPermissions() async throws {
        // 检查麦克风权限
        let micStatus = AVAudioApplication.shared.recordPermission
        VoiceTodoLog.voice.debug("permission.microphone.status status=\(String(describing: micStatus), privacy: .public)")
        if micStatus != .granted {
            let granted = await Self.requestMicrophonePermission()
            if !granted {
                throw VoiceTodoError.microphonePermissionDenied
            }
        }

        // 检查语音识别权限
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        VoiceTodoLog.voice.debug("permission.speech.status status=\(String(describing: speechStatus), privacy: .public)")
        if speechStatus != .authorized {
            let granted = await Self.requestSpeechPermission()
            if !granted {
                throw VoiceTodoError.speechRecognitionPermissionDenied
            }
        }
    }

    /// 处理音频缓冲区：max-duration 检查 + 静音自动提交检测。
    /// 注意：此方法通过 DispatchQueue.main.async 调用，已在主线程执行。
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // 只在录音状态下处理，避免 stopRecording 后的延迟回调
        guard isRecording else { return }

        // 硬性最大录音时长：到达即自动停止（无论在说话还是静音）
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) >= VoiceConstants.maxRecordingSeconds,
           !isSilenceDetected {
            isSilenceDetected = true
            VoiceTodoLog.voice.info("recording.max_duration_reached id=\(self.recordingSessionID ?? "none", privacy: .public) maxSeconds=\(VoiceConstants.maxRecordingSeconds)")
            let durationMS = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            Telemetry.record(.recordingOutcome(outcome: .maxDurationReached, durationMS: durationMS, transcript: transcript))
            stopRecording()
            return
        }

        // RMS 音量计算——用于静音检测
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        guard rms > 0 else { return }
        let avgPower = 20 * log10(rms)

        // 归一化音频电平 (-40dB...0dB → 0...1) 驱动波形动画
        audioLevel = max(0, min(1, (avgPower + 40) / 40))

        // 静音自动提交：基于音频电平检测静音，超时后仅在已有转写内容时触发提交。
        // 静音计时器只受音频电平控制——不受 transcript 是否为空影响。
        // 这样识别器短暂返回空 transcript 时不会重置静音计时器，避免自动提交永不触发。
        // transcript.isEmpty 的检查放在超时触发处：用户没说话（全程空 transcript）不自动提交。
        //
        // 宽限期：录音开始后 silenceTimeoutSeconds 内不启动静音检测——
        // 用户按完按钮需要反应时间才开口，初始静音不应触发自动提交。
        let recordingElapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let inGracePeriod = recordingElapsed < VoiceConstants.silenceTimeoutSeconds
        if avgPower < VoiceConstants.silenceThresholdDB && !inGracePeriod {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= VoiceConstants.silenceTimeoutSeconds && !isSilenceDetected {
                    // 标记已处理此静音周期——即使用户没说话（transcript 为空）也要设 flag，
                    // 否则每个后续 buffer 都会重复进入超时分支。
                    isSilenceDetected = true
                    // 已有转写内容才自动提交——避免用户没说话就送空 transcript 给 AI
                    guard !transcript.isEmpty else { return }
                    VoiceTodoLog.voice.info("recording.silence_auto_submit id=\(self.recordingSessionID ?? "none", privacy: .public) silenceDuration=\(duration) transcriptChars=\(self.transcript.count)")
                    let durationMS = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
                    Telemetry.record(.recordingOutcome(outcome: .silenceTimeout, durationMS: durationMS, transcript: transcript))
                    didAutoFinishDueToSilence = true
                    finishRecording()
                }
            }
        } else {
            silenceStartTime = nil
        }
    }
}
