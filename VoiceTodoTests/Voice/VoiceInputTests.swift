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

    /// 用户主动取消在「未在录音」时应该是 no-op：不抛错、不设 error。
    /// 与 `cancelRecordingDueToInterruption` 的差别就在于不动 error 字段。
    func testCancelRecordingByUserWhenNotRecordingIsNoOp() async {
        let sut = await MainActor.run { VoiceInputManager() }
        await MainActor.run {
            sut.cancelRecordingByUser()
        }

        let snapshot = await MainActor.run { (sut.isRecording, sut.error) }
        XCTAssertFalse(snapshot.0, "未在录音状态应保持")
        XCTAssertNil(snapshot.1, "用户取消在未录音时不应设置 error（区别于中断路径）")
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

    /// 守住 §3.1/§3.2 的重构等价性:`SpeechRecognitionLanguage.systemResolved`
    /// 永不返回 `.auto`、必落在 `supportedLocales` 内;非 auto case 集合与
    /// `supportedLocales` 集合一一对应。
    ///
    /// 不加「顺序守护」(如 `allCases.last == .enUS`):前缀 "zh"/"ja"/"en"
    /// 两两互不包含,遍历顺序对匹配无影响;而 allCases 顺序同时决定 Picker
    /// 显示顺序,钉死会让纯 UI 调整撞在声称守护匹配规则的测试上。
    func testSpeechRecognitionLanguageSystemResolvedInvariants() {
        let resolved = SpeechRecognitionLanguage.systemResolved
        XCTAssertNotEqual(resolved, .auto, "systemResolved 永不返回 .auto")
        XCTAssertTrue(
            VoiceConstants.supportedLocales.contains { $0.identifier == resolved.fixedLocale?.identifier },
            "systemResolved 必落在 supportedLocales 内"
        )

        XCTAssertEqual(
            Set(SpeechRecognitionLanguage.allCases.compactMap { $0.fixedLocale?.identifier }),
            Set(VoiceConstants.supportedLocales.map(\.identifier)),
            "非 auto case 集合必须与 supportedLocales 集合一一对应"
        )
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

    func testRecognitionRequestInjectsChineseBaselineMergedWithUserVocabulary() async {
        let baseline = VoiceConstants.chineseTimeExpressionHints
        XCTAssertFalse(baseline.isEmpty, "chineseTimeExpressionHints 常量应该非空(防常量被误删)")

        var userHints: [String] = []
        if let firstBaseline = baseline.first {
            userHints.append(firstBaseline)
        }
        userHints.append(contentsOf: (1...120).map { "用户词\($0)" })
        let provider = StaticVocabularyProvider(hints: userHints)

        let request = await MainActor.run {
            VoiceInputManager.makeRecognitionRequest(
                localeIdentifier: "zh-Hans",
                vocabularyProvider: provider
            )
        }

        XCTAssertEqual(
            Array(request.contextualStrings.prefix(baseline.count)),
            baseline,
            "中文 locale 应该把 baseline 完整排在 contextualStrings 前面"
        )

        if let firstBaseline = baseline.first {
            let occurrences = request.contextualStrings.filter { $0 == firstBaseline }.count
            XCTAssertEqual(occurrences, 1, "baseline 和用户词重合的项应该只保留一次")
        }

        let uniqueTotal = Set(baseline).union(Set(userHints)).count
        XCTAssertEqual(
            request.contextualStrings.count,
            min(UserVocabularyConfig.speechContextualStringsLimit, uniqueTotal),
            "总数应该 = min(100, 去重后总数)"
        )
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
