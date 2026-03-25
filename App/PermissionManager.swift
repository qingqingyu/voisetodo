import Foundation
import UIKit
import Combine
import AVFoundation
import Speech

/// 权限管理器 [v2 新增]
/// 负责管理和请求麦克风、语音识别权限
final class PermissionManager: ObservableObject {
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
        let granted = await VoiceInputManager.requestMicrophonePermission()
        micGranted = granted
        return granted
    }

    /// 请求语音识别权限
    @MainActor
    func requestSpeechPermission() async -> Bool {
        let granted = await VoiceInputManager.requestSpeechPermission()
        speechGranted = granted
        return granted
    }

    // MARK: - System Settings

    /// 打开系统设置
    func openAppSettings() {
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
        let status = AVAudioSession.sharedInstance().recordPermission
        return status == .denied
    }

    /// 检查语音识别权限是否被永久拒绝
    var isSpeechPermanentlyDenied: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied
    }
}
