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

    // MARK: - Public Properties

    let currentLocale: Locale

    // MARK: - Private Properties

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let audioSessionHelper = AudioSessionHelper()

    // 静音检测相关
    private var silenceStartTime: Date?
    private var isSilenceDetected = false

    // Live Activity 相关
    private var liveActivity: Activity<RecordingActivityAttributes>?
    private var recordingStartTime: Date?
    private var updateTimer: Timer?
    private var interruptionRecoveryObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        let locale = VoiceInputManager.selectLocale()
        self.currentLocale = locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - VoiceInputProtocol Methods

    /// 开始录音
    func startRecording() async throws {
        // 清空之前的状态
        transcript = ""
        error = nil
        isSilenceDetected = false
        silenceStartTime = nil
        recordingStartTime = Date()

        // 1. 检查权限
        try await checkPermissions()

        // 2. 配置音频会话
        try audioSessionHelper.configureSession()

        // 3. 检查语音识别器可用性
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw VoiceTodoError.speechRecognitionUnavailable
        }

        // 4. 创建识别请求并启动识别任务
        try startRecognition(recognizer: recognizer)

        // 5. 配置音频输入和静音检测
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 防御性移除旧 tap，避免重复安装导致 crash
        inputNode.removeTap(onBus: 0)

        // 安装音频 tap 进行音量监控
        inputNode.installTap(
            onBus: 0,
            bufferSize: VoiceConstants.audioBufferSize,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            // 将静音检测派发到主线程，避免与 stopRecording 竞态
            DispatchQueue.main.async {
                self?.processAudioBuffer(buffer)
            }
        }

        // 6. 启动音频引擎
        do {
            try audioEngine.start()
            isRecording = true

            // 7. 监听音频会话中断和路由变更
            audioSessionHelper.startObserving()

            // 7.1 监听中断恢复通知（来电等中断结束后可恢复录音）
            removeInterruptionRecoveryObserver()
            interruptionRecoveryObserver = NotificationCenter.default.addObserver(
                forName: .audioSessionDidRecoverFromInterruption,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      self.isRecording,
                      let shouldResume = notification.userInfo?["shouldResume"] as? Bool,
                      shouldResume else { return }

                #if DEBUG
                print("Audio session recovered from interruption, rebuilding recognition pipeline")
                #endif

                // 重建完整识别链路（recognitionRequest + recognitionTask + audioEngine）
                self.rebuildRecognitionAfterInterruption()
            }

            // 8. 启动 Live Activity
            startLiveActivity()
        } catch {
            // 启动失败时清理已安装的 tap
            inputNode.removeTap(onBus: 0)
            throw VoiceTodoError.recordingFailed("无法启动音频引擎")
        }
    }

    /// 停止录音
    func stopRecording() {
        guard isRecording else { return }

        // 停止音频引擎
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // 结束识别请求
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // 取消识别任务
        recognitionTask?.cancel()
        recognitionTask = nil

        // 停用音频会话并停止监听中断通知
        audioSessionHelper.stopObserving()
        audioSessionHelper.deactivateSession()

        // 移除中断恢复通知监听
        removeInterruptionRecoveryObserver()

        // 更新状态
        isRecording = false
        isSilenceDetected = false
        silenceStartTime = nil

        // 结束 Live Activity
        endLiveActivity()
    }

    /// 通知识别器音频输入结束，等待最终识别结果
    /// 与 stopRecording() 不同，此方法不取消识别任务，
    /// 而是让 Apple Speech Framework 自然完成识别，
    /// 最终结果回调触发 stopRecording() 确保 transcript 是最终版本。
    func finishRecording() {
        guard isRecording else { return }

        // 停止音频引擎（不再输入新音频）
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // 通知识别器音频输入结束（不取消任务，等待最终识别结果）
        recognitionRequest?.endAudio()

        // 停用音频会话并停止监听中断通知
        audioSessionHelper.stopObserving()
        audioSessionHelper.deactivateSession()

        // 移除中断恢复通知监听
        removeInterruptionRecoveryObserver()

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
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request
        request.shouldReportPartialResults = true

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
                        self.stopRecording()
                    }
                }
            }

            if let error = error {
                let isFinal = result?.isFinal ?? true
                if isFinal {
                    // 识别终止且伴随错误，设置错误状态让 UI 可感知
                    DispatchQueue.main.async {
                        self.error = VoiceTodoError.recordingFailed(error.localizedDescription)
                    }
                }
                #if DEBUG
                print("Recognition error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// 中断恢复后重建完整识别链路
    /// 重建 recognitionRequest + recognitionTask，并重启 audioEngine
    private func rebuildRecognitionAfterInterruption() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            #if DEBUG
            print("Speech recognizer unavailable after interruption, stopping recording")
            #endif
            stopRecording()
            return
        }

        // 重建识别请求和任务
        do {
            try startRecognition(recognizer: recognizer)
        } catch {
            #if DEBUG
            print("Failed to rebuild recognition after interruption: \(error)")
            #endif
            stopRecording()
            return
        }

        // 重启音频引擎（tap 仍然安装着，只需重启引擎）
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                #if DEBUG
                print("Failed to restart audio engine after interruption: \(error)")
                #endif
                stopRecording()
            }
        }

        #if DEBUG
        print("Recognition pipeline rebuilt successfully after interruption")
        #endif
    }

    // MARK: - Live Activity Methods

    /// 启动 Live Activity（Dynamic Island 录音状态）
    private func startLiveActivity() {
        guard #available(iOS 16.2, *) else { return }

        // 检查是否已授权 Live Activity
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            print("Live Activity 未授权")
            #endif
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
            #if DEBUG
            print("Live Activity 已启动: \(activity.id)")
            #endif

            // 启动定时器更新时长
            startUpdateTimer()

        } catch {
            #if DEBUG
            print("启动 Live Activity 失败: \(error)")
            #endif
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

        guard let activity = liveActivity else { return }

        Task {
            // 创建最终状态
            let finalState = RecordingActivityAttributes.ContentState(
                isRecording: false,
                transcript: transcript,
                duration: recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            )

            // 结束 Activity
            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
            #if DEBUG
            print("Live Activity 已结束")
            #endif
        }

        liveActivity = nil
        recordingStartTime = nil
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

    private func removeInterruptionRecoveryObserver() {
        if let observer = interruptionRecoveryObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionRecoveryObserver = nil
        }
    }

    // MARK: - Permission Methods [v2]

    /// 请求麦克风权限
    static func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 请求语音识别权限
    static func requestSpeechPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Private Methods

    /// 根据系统语言选择 locale
    private static func selectLocale() -> Locale {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en-US"

        // 检查是否支持
        for locale in VoiceConstants.supportedLocales {
            if preferredLanguage.hasPrefix(locale.languageCode ?? "") {
                return locale
            }
        }

        // 非中文/英文系统回退到英文（国际通用）
        return Locale(identifier: "en-US")
    }

    /// 检查权限
    private func checkPermissions() async throws {
        // 检查麦克风权限
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        if micStatus != .granted {
            let granted = await Self.requestMicrophonePermission()
            if !granted {
                throw VoiceTodoError.microphonePermissionDenied
            }
        }

        // 检查语音识别权限
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            let granted = await Self.requestSpeechPermission()
            if !granted {
                throw VoiceTodoError.speechRecognitionPermissionDenied
            }
        }
    }

    /// 处理音频缓冲区，进行静音检测
    /// 注意：此方法通过 DispatchQueue.main.async 调用，已在主线程执行
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // 只在录音状态下处理，避免 stopRecording 后的延迟回调
        guard isRecording else { return }

        guard let channelData = buffer.floatChannelData?[0] else { return }

        // 直接用指针遍历计算 RMS，避免每帧分配临时数组
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))

        // 转换为 dB（避免 log10(0)）
        guard rms > 0 else { return }
        let avgPower = 20 * log10(rms)

        // 静音检测
        if avgPower < VoiceConstants.silenceThresholdDB {
            // 低于阈值，开始计时
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= VoiceConstants.silenceTimeoutSeconds && !isSilenceDetected {
                    // 超时，自动停止（已在主线程，直接调用）
                    isSilenceDetected = true
                    stopRecording()
                }
            }
        } else {
            // 高于阈值，重置计时
            silenceStartTime = nil
        }
    }
}
