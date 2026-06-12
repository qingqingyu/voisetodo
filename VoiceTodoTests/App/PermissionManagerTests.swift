import XCTest
@testable import VoiceTodo

@MainActor
final class PermissionManagerTests: XCTestCase {
    private final class PermissionProbe {
        var micStatus = MicrophonePermissionStatus.undetermined
        var speechStatus = SpeechPermissionStatus.notDetermined
        var micRequestCount = 0
        var speechRequestCount = 0
    }

    func testEnsureVoicePermissionsRequestsMicrophoneWhenStatusIsNotDetermined() async {
        let probe = PermissionProbe()
        probe.speechStatus = .authorized

        let manager = PermissionManager(
            uiTestOptions: UITestLaunchOptions(arguments: []),
            permissionClient: VoicePermissionClient(
                microphoneStatus: { probe.micStatus },
                speechStatus: { probe.speechStatus },
                requestMicrophone: { () async -> Bool in
                    probe.micRequestCount += 1
                    probe.micStatus = .granted
                    return true
                },
                requestSpeech: { () async -> Bool in
                    XCTFail("Speech permission should not be requested when already authorized")
                    return false
                }
            )
        )

        let readiness = await manager.ensureVoicePermissionsBeforeRecording()

        XCTAssertEqual(readiness, .granted)
        XCTAssertEqual(probe.micRequestCount, 1)
        XCTAssertTrue(manager.micGranted)
        XCTAssertTrue(manager.speechGranted)
    }

    func testEnsureVoicePermissionsRequestsSpeechWhenStatusIsNotDetermined() async {
        let probe = PermissionProbe()
        probe.micStatus = .granted

        let manager = PermissionManager(
            uiTestOptions: UITestLaunchOptions(arguments: []),
            permissionClient: VoicePermissionClient(
                microphoneStatus: { probe.micStatus },
                speechStatus: { probe.speechStatus },
                requestMicrophone: { () async -> Bool in
                    XCTFail("Microphone permission should not be requested when already granted")
                    return false
                },
                requestSpeech: { () async -> Bool in
                    probe.speechRequestCount += 1
                    probe.speechStatus = .authorized
                    return true
                }
            )
        )

        let readiness = await manager.ensureVoicePermissionsBeforeRecording()

        XCTAssertEqual(readiness, .granted)
        XCTAssertEqual(probe.speechRequestCount, 1)
        XCTAssertTrue(manager.micGranted)
        XCTAssertTrue(manager.speechGranted)
    }

    func testEnsureVoicePermissionsReturnsSettingsRequiredForPreviouslyDeniedPermission() async {
        let probe = PermissionProbe()
        probe.micStatus = .denied
        probe.speechStatus = .authorized

        let manager = PermissionManager(
            uiTestOptions: UITestLaunchOptions(arguments: []),
            permissionClient: VoicePermissionClient(
                microphoneStatus: { probe.micStatus },
                speechStatus: { probe.speechStatus },
                requestMicrophone: { () async -> Bool in
                    probe.micRequestCount += 1
                    return false
                },
                requestSpeech: { () async -> Bool in
                    probe.speechRequestCount += 1
                    return false
                }
            )
        )

        let readiness = await manager.ensureVoicePermissionsBeforeRecording()

        XCTAssertEqual(readiness, .settingsRequired)
        XCTAssertEqual(probe.micRequestCount, 0)
        XCTAssertEqual(probe.speechRequestCount, 0)
        XCTAssertFalse(manager.micGranted)
    }

    func testEnsureVoicePermissionsReturnsRequestableDeniedWhenUserDeclinesNewPrompt() async {
        let manager = PermissionManager(
            uiTestOptions: UITestLaunchOptions(arguments: []),
            permissionClient: VoicePermissionClient(
                microphoneStatus: { .undetermined },
                speechStatus: { .authorized },
                requestMicrophone: { () async -> Bool in false },
                requestSpeech: { () async -> Bool in true }
            )
        )

        let readiness = await manager.ensureVoicePermissionsBeforeRecording()

        XCTAssertEqual(readiness, .requestableDenied)
        XCTAssertFalse(manager.micGranted)
    }
}
