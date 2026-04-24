import Foundation
import UIKit
import Combine
import AVFoundation
import Speech

/// 权限管理器 [v2 新增]
/// 负责管理和请求麦克风、语音识别权限
final class PermissionManager: ObservableObject {
    private let uiTestOptions = UITestLaunchOptions.current

    // MARK: - Published Properties

    @Published var micGranted: Bool = false
    @Published var speechGranted: Bool = false

    // MARK: - Initialization

    init() {
        checkCurrentStatus()
    }

    // MARK: - Status Check

    /// 检查当前权限状态
    func checkCurrentStatus() {
        if uiTestOptions.isUITesting {
            micGranted = !uiTestOptions.micPermissionDenied
            speechGranted = true
            return
        }

        // 检查麦克风权限
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        micGranted = (micStatus == .granted)

        // 检查语音识别权限
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechGranted = (speechStatus == .authorized)
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

        let granted = await VoiceInputManager.requestMicrophonePermission()
        micGranted = granted
        return granted
    }

    /// 请求语音识别权限
    @MainActor
    func requestSpeechPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            speechGranted = true
            return true
        }

        let granted = await VoiceInputManager.requestSpeechPermission()
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

        let status = AVAudioSession.sharedInstance().recordPermission
        return status == .denied
    }

    /// 检查语音识别权限是否被永久拒绝
    var isSpeechPermanentlyDenied: Bool {
        if uiTestOptions.isUITesting {
            return false
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied
    }
}
