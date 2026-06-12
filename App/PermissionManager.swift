import Foundation
import UIKit
import Combine
import AVFoundation
import Speech

enum VoicePermissionReadiness: Equatable {
    case granted
    case requestableDenied
    case settingsRequired
}

enum MicrophonePermissionStatus {
    case undetermined
    case denied
    case granted
}

enum SpeechPermissionStatus {
    case notDetermined
    case denied
    case restricted
    case authorized
}

struct VoicePermissionClient {
    var microphoneStatus: @MainActor () -> MicrophonePermissionStatus
    var speechStatus: @MainActor () -> SpeechPermissionStatus
    var requestMicrophone: @MainActor () async -> Bool
    var requestSpeech: @MainActor () async -> Bool

    static let live = VoicePermissionClient(
        microphoneStatus: {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        },
        speechStatus: {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .authorized:
                return .authorized
            @unknown default:
                return .restricted
            }
        },
        requestMicrophone: {
            await VoiceInputManager.requestMicrophonePermission()
        },
        requestSpeech: {
            await VoiceInputManager.requestSpeechPermission()
        }
    )
}

/// 权限管理器 [v2 新增]
/// 负责管理和请求麦克风、语音识别权限
@MainActor
final class PermissionManager: ObservableObject {
    private let uiTestOptions: UITestLaunchOptions
    private let permissionClient: VoicePermissionClient

    // MARK: - Published Properties

    @Published var micGranted: Bool = false
    @Published var speechGranted: Bool = false

    // MARK: - Initialization

    init(
        uiTestOptions: UITestLaunchOptions = .current,
        permissionClient: VoicePermissionClient = .live
    ) {
        self.uiTestOptions = uiTestOptions
        self.permissionClient = permissionClient
        checkCurrentStatus()
    }

    // MARK: - Status Check

    /// 检查当前权限状态
    func checkCurrentStatus() {
        if uiTestOptions.isUITesting {
            micGranted = !uiTestOptions.micPermissionDenied
            speechGranted = !uiTestOptions.speechPermissionDenied
            return
        }

        micGranted = (permissionClient.microphoneStatus() == .granted)
        speechGranted = (permissionClient.speechStatus() == .authorized)
    }

    /// 开始录音前统一确认权限。notDetermined 会拉起系统授权；已拒绝或受限则要求去设置。
    @MainActor
    func ensureVoicePermissionsBeforeRecording() async -> VoicePermissionReadiness {
        if uiTestOptions.isUITesting {
            micGranted = !uiTestOptions.micPermissionDenied
            speechGranted = !uiTestOptions.speechPermissionDenied
            return allPermissionsGranted ? .granted : .settingsRequired
        }

        switch permissionClient.microphoneStatus() {
        case .granted:
            micGranted = true
        case .undetermined:
            let granted = await requestMicPermission()
            guard granted else { return .requestableDenied }
        case .denied:
            micGranted = false
            return .settingsRequired
        }

        switch permissionClient.speechStatus() {
        case .authorized:
            speechGranted = true
        case .notDetermined:
            let granted = await requestSpeechPermission()
            guard granted else { return .requestableDenied }
        case .denied, .restricted:
            speechGranted = false
            return .settingsRequired
        }

        return allPermissionsGranted ? .granted : .settingsRequired
    }

    // MARK: - Permission Requests

    /// 请求麦克风权限
    @MainActor
    func requestMicPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            let granted = !uiTestOptions.micPermissionDenied
            micGranted = granted
            return granted
        }

        let granted = await permissionClient.requestMicrophone()
        micGranted = granted
        return granted
    }

    /// 请求语音识别权限
    @MainActor
    func requestSpeechPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            let granted = !uiTestOptions.speechPermissionDenied
            speechGranted = granted
            return granted
        }

        let granted = await permissionClient.requestSpeech()
        speechGranted = granted
        return granted
    }

    // MARK: - System Settings

    /// 打开系统设置
    func openAppSettings() {
        Self.openAppSettings()
    }

    /// 打开系统设置（静态方法，供无实例的场景调用）
    static func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        if UIApplication.shared.canOpenURL(settingsURL) {
            UIApplication.shared.open(settingsURL)
        }
    }

    // MARK: - Helper Methods

    /// 检查是否所有必需权限都已授予
    var allPermissionsGranted: Bool {
        return micGranted && speechGranted
    }

    /// 检查麦克风权限是否被永久拒绝
    var isMicPermanentlyDenied: Bool {
        if uiTestOptions.isUITesting {
            return uiTestOptions.micPermissionDenied
        }

        return permissionClient.microphoneStatus() == .denied
    }

    /// 检查语音识别权限是否被永久拒绝
    var isSpeechPermanentlyDenied: Bool {
        if uiTestOptions.isUITesting {
            return uiTestOptions.speechPermissionDenied
        }

        return permissionClient.speechStatus() == .denied
    }
}
