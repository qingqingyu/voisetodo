import Foundation
import Combine
import Speech
import AVFoundation

/// 语音输入管理器
/// 实现 VoiceInputProtocol，封装 Apple Speech Framework
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

    // MARK: - Private Properties

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let audioSessionHelper = AudioSessionHelper()

    // 静音检测相关
    private var silenceStartTime: Date?
    private var isSilenceDetected = false

    // MARK: - Initialization

    init() {
        // 根据系统语言选择 locale
        let locale = selectLocale()
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

        // 1. 检查权限
        try await checkPermissions()

        // 2. 配置音频会话
        try audioSessionHelper.configureSession()

        // 3. 检查语音识别器可用性
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw VoiceTodoError.speechRecognitionUnavailable
        }

        // 4. 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw VoiceTodoError.recordingFailed("无法创建识别请求")
        }
        request.shouldReportPartialResults = true

        // 5. 开始识别任务
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                // 更新转写文本
                self.transcript = result.bestTranscription.formattedString

                // 如果是最终结果，停止录音
                if result.isFinal {
                    self.stopRecording()
                }
            }

            if error != nil {
                // 识别出错，但不抛出错误，可能是临时的
                print("Recognition error: \(error?.localizedDescription ?? "Unknown")")
            }
        }

        // 6. 配置音频输入和静音检测
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 安装音频 tap 进行音量监控
        inputNode.installTap(
            onBus: 0,
            bufferSize: VoiceConstants.audioBufferSize,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        // 7. 启动音频引擎
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
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

        // 停用音频会话
        audioSessionHelper.deactivateSession()

        // 更新状态
        isRecording = false
        isSilenceDetected = false
        silenceStartTime = nil
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
    private func selectLocale() -> Locale {
        let preferredLanguage = Locale.preferredLanguages.first ?? "zh-Hans"

        // 检查是否支持
        for locale in VoiceConstants.supportedLocales {
            if preferredLanguage.hasPrefix(locale.languageCode ?? "") {
                return locale
            }
        }

        // 默认使用中文
        return Locale(identifier: "zh-Hans")
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
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        // 计算 RMS 值
        let channelDataValue = channelData
        let channelDataArray = Array(UnsafeBufferPointer(start: channelDataValue, count: Int(buffer.frameLength)))

        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // 转换为 dB
        let avgPower = 20 * log10(rms)

        // 静音检测
        if avgPower < VoiceConstants.silenceThresholdDB {
            // 低于阈值，开始计时
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration >= VoiceConstants.silenceTimeoutSeconds && !isSilenceDetected {
                    // 超时，自动停止
                    isSilenceDetected = true
                    DispatchQueue.main.async { [weak self] in
                        self?.stopRecording()
                    }
                }
            }
        } else {
            // 高于阈值，重置计时
            silenceStartTime = nil
        }
    }
}
