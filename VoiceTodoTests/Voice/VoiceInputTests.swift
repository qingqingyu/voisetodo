import XCTest
import AVFoundation
@testable import VoiceTodo

final class VoiceInputTests: XCTestCase {
    // MARK: - 初始化与基础行为

    func testInitialState() async {
        let sut = await MainActor.run { VoiceInputManager() }
        let state = await MainActor.run { (sut.isRecording, sut.transcript, sut.error) }

        XCTAssertFalse(state.0, "初始状态应该不在录音")
        XCTAssertEqual(state.1, "", "初始转写文本应该为空")
        XCTAssertNil(state.2, "初始错误应该为 nil")
    }

    func testStopRecordingWhenNotRecording() async {
        let sut = await MainActor.run { VoiceInputManager() }
        await MainActor.run {
            sut.stopRecording()
        }

        let isRecording = await MainActor.run { sut.isRecording }
        XCTAssertFalse(isRecording, "停止后应该不在录音状态")
    }

    // MARK: - 常量配置测试

    func testVoiceConstantsSilenceThreshold() {
        XCTAssertGreaterThanOrEqual(VoiceConstants.silenceThresholdDB, -45.0)
        XCTAssertLessThanOrEqual(VoiceConstants.silenceThresholdDB, -35.0)
    }

    func testVoiceConstantsSilenceTimeout() {
        XCTAssertGreaterThanOrEqual(VoiceConstants.silenceTimeoutSeconds, 1.0)
        XCTAssertLessThanOrEqual(VoiceConstants.silenceTimeoutSeconds, 3.0)
    }

    func testVoiceConstantsFinishRecordingWatchdogTimeout() {
        XCTAssertGreaterThanOrEqual(VoiceConstants.finishRecordingWatchdogTimeoutSeconds, 3.0)
        XCTAssertLessThanOrEqual(VoiceConstants.finishRecordingWatchdogTimeoutSeconds, 10.0)
    }

    func testVoiceConstantsAudioBufferSize() {
        XCTAssertGreaterThan(VoiceConstants.audioBufferSize, 0)
    }

    func testVoiceConstantsSupportedLocales() {
        let localeIdentifiers = VoiceConstants.supportedLocales.map(\.identifier)
        XCTAssertTrue(localeIdentifiers.contains("zh-Hans"))
        XCTAssertTrue(localeIdentifiers.contains("en-US"))
    }

    func testRecognitionRequestUsesContextualStringsFromVocabularyProvider() async {
        let hints = (1...120).map { "Term\($0)" }
        let provider = StaticVocabularyProvider(hints: hints)

        let request = await MainActor.run {
            VoiceInputManager.makeRecognitionRequest(
                localeIdentifier: "en-US",
                vocabularyProvider: provider
            )
        }

        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertEqual(request.contextualStrings.count, UserVocabularyConfig.speechContextualStringsLimit)
        XCTAssertEqual(request.contextualStrings.first, "Term1")
    }

    func testRecognitionRequestAllowsEmptyContextualStrings() async {
        let provider = StaticVocabularyProvider(hints: [])

        let request = await MainActor.run {
            VoiceInputManager.makeRecognitionRequest(
                localeIdentifier: "en-US",
                vocabularyProvider: provider
            )
        }

        XCTAssertTrue(request.contextualStrings.isEmpty)
    }

    // MARK: - 权限测试

    func testMicrophonePermissionRequestMethod() throws {
        throw XCTSkip("系统麦克风权限弹窗在自动化环境中不稳定，改由 UI 测试覆盖权限流。")
    }

    func testSpeechPermissionRequestMethod() throws {
        throw XCTSkip("系统语音识别权限弹窗在自动化环境中不稳定，改由 UI 测试覆盖权限流。")
    }

    func testAudioSessionInterruptionBeganPostsCancellationNotification() {
        let helper = AudioSessionHelper()
        let expectation = expectation(description: "interruption began notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .audioSessionInterruptionBegan,
            object: helper,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        helper.handleInterruption(notification: Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        ))

        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }
}

private struct StaticVocabularyProvider: UserVocabularyProviding {
    let hints: [String]

    func vocabularyHints(localeIdentifier: String, limit: Int, now: Date) -> [String] {
        Array(hints.prefix(limit))
    }
}
