import Foundation
import AVFoundation

/// 音频会话辅助类
/// 负责配置 AVAudioSession，处理音频会话中断、恢复、路由变更
final class AudioSessionHelper {
    private let session = AVAudioSession.sharedInstance()
    private var isActive = false

    /// 配置音频会话为录音模式
    func configureSession() throws {
        do {
            try session.setCategory(.record, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            isActive = true
        } catch {
            throw VoiceTodoError.audioSessionInterrupted
        }
    }

    /// 停用音频会话
    func deactivateSession() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
        } catch {
            // 停用失败不影响流程，记录即可
            print("Failed to deactivate audio session: \(error)")
        }
    }

    /// 处理音频会话中断通知
    func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // 中断开始（如来电、闹钟等）
            isActive = false
        case .ended:
            // 中断结束
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && isActive {
                    // 可以恢复音频会话
                    try? configureSession()
                }
            }
        @unknown default:
            break
        }
    }

    /// 处理音频路由变更通知
    func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        // 可以根据路由变更做相应处理
        // 例如：耳机插入/拔出、蓝牙设备连接/断开等
        switch reason {
        case .newDeviceAvailable:
            print("New audio device available")
        case .oldDeviceUnavailable:
            print("Old audio device unavailable")
        default:
            break
        }
    }
}
