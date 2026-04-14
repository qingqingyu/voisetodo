import Foundation
import AVFoundation

/// 音频会话辅助类
/// 负责配置 AVAudioSession，处理音频会话中断、恢复、路由变更
final class AudioSessionHelper {
    private let session = AVAudioSession.sharedInstance()
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

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
            #if DEBUG
            print("Failed to deactivate audio session: \(error)")
            #endif
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
            #if DEBUG
            print("New audio device available")
            #endif
        case .oldDeviceUnavailable:
            #if DEBUG
            print("Old audio device unavailable")
            #endif
        default:
            break
        }
    }

    // MARK: - Notification Observing

    /// 开始监听音频会话中断和路由变更通知
    func startObserving() {
        stopObserving()

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }

        let routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
        }

        observers = [interruptionObserver, routeChangeObserver]
    }

    /// 停止监听通知
    func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}
