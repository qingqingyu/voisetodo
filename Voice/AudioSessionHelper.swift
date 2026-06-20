import Foundation
import AVFoundation

/// 音频会话中断恢复通知
/// 当音频中断结束且可以恢复时发出，userInfo 包含 AVAudioSession.InterruptionOptions
extension Notification.Name {
    static let audioSessionInterruptionBegan = Notification.Name("AudioSessionInterruptionBegan")
    static let audioSessionDidRecoverFromInterruption = Notification.Name("AudioSessionDidRecoverFromInterruption")
}

/// 音频会话辅助类
/// 负责配置 AVAudioSession，处理音频会话中断、恢复、路由变更
final class AudioSessionHelper {
    private let session = AVAudioSession.sharedInstance()
    private var isActive = false
    private var wasActiveBeforeInterruption = false
    private var observers: [NSObjectProtocol] = []

    /// 配置音频会话为录音模式
    func configureSession() throws {
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
            isActive = true
            VoiceTodoLog.voice.info("audio_session.configured category=record mode=default")
        } catch {
            VoiceTodoLog.voice.error("audio_session.configure_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            throw VoiceTodoError.audioSessionInterrupted
        }
    }

    /// 停用音频会话
    func deactivateSession() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
            VoiceTodoLog.voice.info("audio_session.deactivated")
        } catch {
            // 停用失败不影响流程，记录即可
            VoiceTodoLog.voice.error("audio_session.deactivate_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
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
            VoiceTodoLog.voice.warning("audio_session.interruption.began wasActive=\(self.isActive)")
            wasActiveBeforeInterruption = isActive
            isActive = false
            NotificationCenter.default.post(
                name: .audioSessionInterruptionBegan,
                object: self
            )
        case .ended:
            // 中断结束
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                VoiceTodoLog.voice.info("audio_session.interruption.ended shouldResume=\(options.contains(.shouldResume)) wasActiveBeforeInterruption=\(self.wasActiveBeforeInterruption)")
                if options.contains(.shouldResume) && wasActiveBeforeInterruption {
                    // 可以恢复音频会话
                    do {
                        try configureSession()
                    } catch {
                        VoiceTodoLog.voice.error("audio_session.interruption.resume_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        wasActiveBeforeInterruption = false
                        return
                    }

                    // 通知上层可以恢复录音
                    NotificationCenter.default.post(
                        name: .audioSessionDidRecoverFromInterruption,
                        object: self,
                        userInfo: ["shouldResume": true]
                    )
                }
            }
            wasActiveBeforeInterruption = false
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
            VoiceTodoLog.voice.info("audio_session.route_changed reason=newDeviceAvailable")
        case .oldDeviceUnavailable:
            VoiceTodoLog.voice.warning("audio_session.route_changed reason=oldDeviceUnavailable")
        default:
            VoiceTodoLog.voice.debug("audio_session.route_changed reason=\(reason.rawValue)")
            break
        }
    }

    // MARK: - Notification Observing

    /// 开始监听音频会话中断和路由变更通知
    func startObserving() {
        stopObserving()
        VoiceTodoLog.voice.debug("audio_session.observing.start")

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
        guard !observers.isEmpty else { return }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        VoiceTodoLog.voice.debug("audio_session.observing.stop")
    }
}
