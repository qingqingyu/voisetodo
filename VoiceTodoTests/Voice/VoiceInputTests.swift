import XCTest
import Combine
@testable import VoiceTodo

final class VoiceInputTests: XCTestCase {
    var sut: VoiceInputManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        sut = VoiceInputManager()
        cancellables = []
    }

    override func tearDown() {
        sut = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - 初始化测试

    func testInitialState() {
        XCTAssertFalse(sut.isRecording, "初始状态应该不在录音")
        XCTAssertEqual(sut.transcript, "", "初始转写文本应该为空")
        XCTAssertNil(sut.error, "初始错误应该为 nil")
    }

    // MARK: - 常量配置测试 [v2]

    func testVoiceConstantsSilenceThreshold() {
        // 静音阈值应该在合理范围内
        XCTAssertGreaterThanOrEqual(
            VoiceConstants.silenceThresholdDB,
            -45.0,
            "静音阈值不应低于 -45 dB"
        )
        XCTAssertLessThanOrEqual(
            VoiceConstants.silenceThresholdDB,
            -35.0,
            "静音阈值不应高于 -35 dB"
        )
    }

    func testVoiceConstantsSilenceTimeout() {
        // 静音超时应该在合理范围内
        XCTAssertGreaterThanOrEqual(
            VoiceConstants.silenceTimeoutSeconds,
            1.0,
            "静音超时不应少于 1 秒"
        )
        XCTAssertLessThanOrEqual(
            VoiceConstants.silenceTimeoutSeconds,
            3.0,
            "静音超时不应超过 3 秒"
        )
    }

    func testVoiceConstantsAudioBufferSize() {
        // 缓冲区大小应该是合理的
        XCTAssertGreaterThan(
            VoiceConstants.audioBufferSize,
            0,
            "音频缓冲区大小应该大于 0"
        )
    }

    func testVoiceConstantsSupportedLocales() {
        // 应该至少支持中文和英文
        XCTAssertFalse(
            VoiceConstants.supportedLocales.isEmpty,
            "支持的 locale 列表不应为空"
        )

        let localeIdentifiers = VoiceConstants.supportedLocales.map { $0.identifier }
        XCTAssertTrue(
            localeIdentifiers.contains("zh-Hans"),
            "应该支持简体中文"
        )
        XCTAssertTrue(
            localeIdentifiers.contains("en-US"),
            "应该支持美式英语"
        )
    }

    // MARK: - 录音控制测试

    func testStopRecordingWhenNotRecording() {
        // 当不在录音状态时调用 stopRecording 不应该崩溃
        sut.stopRecording()
        XCTAssertFalse(sut.isRecording, "停止后应该不在录音状态")
    }

    // MARK: - 权限测试

    func testMicrophonePermissionRequestMethod() {
        // 测试静态方法是否存在
        let expectation = XCTestExpectation(description: "Permission request")

        Task {
            // 这个测试只验证方法可以调用，实际权限取决于系统设置
            _ = await VoiceInputManager.requestMicrophonePermission()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testSpeechPermissionRequestMethod() {
        // 测试静态方法是否存在
        let expectation = XCTestExpectation(description: "Permission request")

        Task {
            // 这个测试只验证方法可以调用，实际权限取决于系统设置
            _ = await VoiceInputManager.requestSpeechPermission()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - 状态更新测试

    func testTranscriptUpdates() {
        let expectation = XCTestExpectation(description: "Transcript should update")
        var updatedTranscripts: [String] = []

        sut.$transcript
            .sink { transcript in
                updatedTranscripts.append(transcript)
                if updatedTranscripts.count == 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // 模拟转写文本更新
        sut.transcript = "测试"
        sut.transcript = "测试语音"

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(updatedTranscripts.contains("测试"))
        XCTAssertTrue(updatedTranscripts.contains("测试语音"))
    }

    func testRecordingStateUpdates() {
        let expectation = XCTestExpectation(description: "isRecording should update")
        var recordingStates: [Bool] = []

        sut.$isRecording
            .sink { isRecording in
                recordingStates.append(isRecording)
                if recordingStates.count == 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // 模拟录音状态更新
        sut.isRecording = true
        sut.isRecording = false

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(recordingStates, [false, true, false])
    }

    func testErrorUpdates() {
        let expectation = XCTestExpectation(description: "error should update")
        var errors: [VoiceTodoError?] = []

        sut.$error
            .sink { error in
                errors.append(error)
                if errors.count == 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // 模拟错误更新
        sut.error = .microphonePermissionDenied
        sut.error = nil

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(errors[1])
        XCTAssertNil(errors[2])
    }
}
