import Foundation
import UIKit
import Combine
import AVFoundation
import Speech
import EventKit

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
            switch AVAudioApplication.shared.recordPermission {
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

enum CalendarPermissionStatus {
    case notDetermined
    case denied
    case granted
}

/// 日历权限的可注入 seam。与 `VoicePermissionClient` 对称 —— UI 测试必须能 mock,
/// 否则会被系统权限弹窗挂死。
struct CalendarPermissionClient {
    var status: @MainActor () -> CalendarPermissionStatus
    var requestAccess: @MainActor () async -> Bool

    static let live: CalendarPermissionClient = {
        // 用闭包捕获的 EKEventStore 复用实例,避免每次 requestAccess 新建(EventKit 内部状态更稳)。
        // 注意:authorizationStatus(for: .event) 是静态方法,不依赖实例;这里复用纯粹为 requestAccess 调用。
        // SystemCalendarWriter / SystemCalendarReader 各自持有独立 EKEventStore —— 这没问题,
        // EKEventStore 的授权和操作跨实例一致。
        let eventStore = EKEventStore()
        return CalendarPermissionClient(
            status: {
                switch EKEventStore.authorizationStatus(for: .event) {
                case .notDetermined:            return .notDetermined
                // writeOnly 对写入场景已经够用,按 granted 处理。
                // ⚠️ 不要往这里加 .authorized —— 它与 .fullAccess rawValue 相同
                //   (都是 3),但 Swift 里是独立 case,同列不会编译失败只会触发
                //   deprecated warning。iOS 17+ 的 authorizationStatus(for: .event) 永远
                //   不返回 .authorized(已废弃),加上是死代码且制造混淆。
                case .fullAccess, .writeOnly:   return .granted
                case .denied, .restricted:      return .denied
                @unknown default:               return .denied
                }
            },
            requestAccess: {
                // 必须是 requestFullAccessToEvents —— 与 SystemCalendarWriter.requestCalendarAccess()
                // (SystemCalendarWriter.swift:174) 请求同一档权限,否则首次写日历时会二次弹窗。
                //
                // error 刻意降级为 granted=false(与 mic/speech 的 `async -> Bool` seam 对称):
                // UI 只需知道「是否拿到权限」来决定回滚还是继续,error 已在 warning 级别留痕。
                // SystemCalendarWriter 那边用 throws 是因为写入路径需要区分「权限被拒」和「系统故障」。
                await withCheckedContinuation { continuation in
                    eventStore.requestFullAccessToEvents { granted, error in
                        if let error {
                            VoiceTodoLog.calendar.warning("permissions.calendar.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public) granted=\(granted)")
                        }
                        continuation.resume(returning: granted)
                    }
                }
            }
        )
    }()
}

/// 权限管理器 [v2 新增]
/// 负责管理和请求麦克风、语音识别权限
@MainActor
final class PermissionManager: ObservableObject {
    private let uiTestOptions: UITestLaunchOptions
    private let voicePermissionClient: VoicePermissionClient
    private let calendarPermissionClient: CalendarPermissionClient

    // MARK: - Published Properties

    @Published var micGranted: Bool = false
    @Published var speechGranted: Bool = false
    /// 日历写入权限。onboarding 日历同步开关打开时按需请求;拒绝后开关视觉回滚、
    /// 持久化保持 `.appOnly` —— 不变量见 `OnboardingView.calendarSyncBinding` 文档。
    @Published private(set) var calendarGranted: Bool = false

    /// 用户在 onboarding 权限页主动跳过(点了「Skip for now」)。
    /// 用于区分「未决定」(系统弹窗未触发)和「主动跳过」(看过说明但拒绝),
    /// 后者在主界面首次录音前会弹一次更详细的引导 sheet。
    /// 授权成功后会自动清掉(见 `clearSkippedInOnboarding()`)。
    /// 持久化到 UserDefaults,避免重启后丢失。
    @Published private(set) var hasSkippedInOnboarding: Bool

    private let hasSkippedInOnboardingKey = "hasSkippedVoicePermissionsInOnboarding"

    // MARK: - Initialization

    init(
        uiTestOptions: UITestLaunchOptions = .current,
        voicePermissionClient: VoicePermissionClient = .live,
        calendarPermissionClient: CalendarPermissionClient = .live
    ) {
        self.uiTestOptions = uiTestOptions
        self.voicePermissionClient = voicePermissionClient
        self.calendarPermissionClient = calendarPermissionClient
        // 初始化时从 UserDefaults 读一次,避免重启后标志丢失导致重复弹引导。
        // 测试模式下不读 UserDefaults(UI 测试通过 launchArguments 注入状态)。
        if uiTestOptions.isUITesting {
            self.hasSkippedInOnboarding = false
        } else {
            self.hasSkippedInOnboarding = UserDefaults.standard.bool(forKey: hasSkippedInOnboardingKey)
        }
        checkCurrentStatus()
    }

    // MARK: - Status Check

    /// 检查当前权限状态
    func checkCurrentStatus() {
        if uiTestOptions.isUITesting {
            micGranted = !uiTestOptions.micPermissionDenied
            speechGranted = !uiTestOptions.speechPermissionDenied
            calendarGranted = !uiTestOptions.calendarPermissionDenied
            VoiceTodoLog.app.info("permissions.status.ui_test micGranted=\(self.micGranted) speechGranted=\(self.speechGranted) calendarGranted=\(self.calendarGranted)")
            return
        }

        micGranted = (voicePermissionClient.microphoneStatus() == .granted)
        speechGranted = (voicePermissionClient.speechStatus() == .authorized)
        calendarGranted = (calendarPermissionClient.status() == .granted)
        VoiceTodoLog.app.info("permissions.status micGranted=\(self.micGranted) speechGranted=\(self.speechGranted) calendarGranted=\(self.calendarGranted)")
    }

    /// 开始录音前统一确认权限。notDetermined 会拉起系统授权；已拒绝或受限则要求去设置。
    @MainActor
    func ensureVoicePermissionsBeforeRecording() async -> VoicePermissionReadiness {
        if uiTestOptions.isUITesting {
            micGranted = !uiTestOptions.micPermissionDenied
            speechGranted = !uiTestOptions.speechPermissionDenied
            VoiceTodoLog.app.info("permissions.ensure.ui_test micGranted=\(self.micGranted) speechGranted=\(self.speechGranted)")
            return allPermissionsGranted ? .granted : .settingsRequired
        }

        switch voicePermissionClient.microphoneStatus() {
        case .granted:
            micGranted = true
            VoiceTodoLog.app.info("permissions.ensure.microphone already_granted=true")
        case .undetermined:
            let granted = await requestMicPermission()
            VoiceTodoLog.app.info("permissions.ensure.microphone requested granted=\(granted)")
            guard granted else { return .requestableDenied }
        case .denied:
            micGranted = false
            VoiceTodoLog.app.warning("permissions.ensure.microphone denied=settings_required")
            return .settingsRequired
        }

        switch voicePermissionClient.speechStatus() {
        case .authorized:
            speechGranted = true
            VoiceTodoLog.app.info("permissions.ensure.speech already_authorized=true")
        case .notDetermined:
            let granted = await requestSpeechPermission()
            VoiceTodoLog.app.info("permissions.ensure.speech requested granted=\(granted)")
            guard granted else { return .requestableDenied }
        case .denied, .restricted:
            speechGranted = false
            VoiceTodoLog.app.warning("permissions.ensure.speech denied_or_restricted=settings_required")
            return .settingsRequired
        }

        let readiness: VoicePermissionReadiness = allPermissionsGranted ? .granted : .settingsRequired
        if readiness == .granted { clearSkippedInOnboarding() }
        VoiceTodoLog.app.info("permissions.ensure.finished readiness=\(String(describing: readiness), privacy: .public)")
        return readiness
    }

    // MARK: - Permission Requests

    /// 请求麦克风权限
    @MainActor
    func requestMicPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            let granted = !uiTestOptions.micPermissionDenied
            micGranted = granted
            VoiceTodoLog.app.info("permissions.request_microphone.ui_test granted=\(granted)")
            if granted { clearSkippedInOnboarding() }
            return granted
        }

        let granted = await voicePermissionClient.requestMicrophone()
        micGranted = granted
        VoiceTodoLog.app.info("permissions.request_microphone.result granted=\(granted)")
        if granted { clearSkippedInOnboarding() }
        return granted
    }

    /// 请求语音识别权限
    @MainActor
    func requestSpeechPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            let granted = !uiTestOptions.speechPermissionDenied
            speechGranted = granted
            VoiceTodoLog.app.info("permissions.request_speech.ui_test granted=\(granted)")
            if granted { clearSkippedInOnboarding() }
            return granted
        }

        let granted = await voicePermissionClient.requestSpeech()
        speechGranted = granted
        VoiceTodoLog.app.info("permissions.request_speech.result granted=\(granted)")
        if granted { clearSkippedInOnboarding() }
        return granted
    }

    /// 请求日历写入权限。onboarding 日历同步开关打开时调用。
    /// 与 mic/speech 不同:日历权限不参与 onboarding 「跳过」语义,不调 clearSkippedInOnboarding。
    /// 失败时由调用方(OnboardingView.calendarSyncBinding)负责视觉回滚 + 显示「去设置开启」。
    @MainActor
    func requestCalendarPermission() async -> Bool {
        if uiTestOptions.isUITesting {
            let granted = !uiTestOptions.calendarPermissionDenied
            calendarGranted = granted
            VoiceTodoLog.app.info("permissions.request_calendar.ui_test granted=\(granted)")
            return granted
        }

        let granted = await calendarPermissionClient.requestAccess()
        calendarGranted = granted
        VoiceTodoLog.app.info("permissions.request_calendar.result granted=\(granted)")
        return granted
    }

    // MARK: - Onboarding Skip State

    /// 用户在 onboarding 权限页点了「Skip for now」时调用,标记跳过状态。
    /// 主界面首次录音前会读这个标志,决定是否弹更详细的引导 sheet。
    func markSkippedInOnboarding() {
        guard !hasSkippedInOnboarding else { return }
        hasSkippedInOnboarding = true
        UserDefaults.standard.set(true, forKey: hasSkippedInOnboardingKey)
        VoiceTodoLog.app.info("permissions.onboarding.skipped_marked")
    }

    /// 权限拿到后清掉跳过标志(由 `requestMicPermission` / `requestSpeechPermission`
    /// 授权成功时调用,以及 `ensureVoicePermissionsBeforeRecording` 已授权时调用)。
    func clearSkippedInOnboarding() {
        guard hasSkippedInOnboarding else { return }
        hasSkippedInOnboarding = false
        UserDefaults.standard.set(false, forKey: hasSkippedInOnboardingKey)
        VoiceTodoLog.app.info("permissions.onboarding.skipped_cleared")
    }

    // MARK: - System Settings

    /// 打开系统设置
    func openAppSettings() {
        Self.openAppSettings()
    }

    /// 打开系统设置（静态方法，供无实例的场景调用）
    static func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            VoiceTodoLog.app.error("permissions.open_settings.failed reason=invalid_url")
            return
        }

        if UIApplication.shared.canOpenURL(settingsURL) {
            UIApplication.shared.open(settingsURL)
            VoiceTodoLog.app.info("permissions.open_settings")
        } else {
            VoiceTodoLog.app.error("permissions.open_settings.failed reason=cannot_open_url")
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

        return voicePermissionClient.microphoneStatus() == .denied
    }

    /// 检查语音识别权限是否被永久拒绝
    var isSpeechPermanentlyDenied: Bool {
        if uiTestOptions.isUITesting {
            return uiTestOptions.speechPermissionDenied
        }

        return voicePermissionClient.speechStatus() == .denied
    }

    /// 检查日历权限是否被永久拒绝(用户在系统设置里关掉,只能去系统设置开启)
    var isCalendarPermanentlyDenied: Bool {
        if uiTestOptions.isUITesting {
            return uiTestOptions.calendarPermissionDenied
        }

        return calendarPermissionClient.status() == .denied
    }
}
