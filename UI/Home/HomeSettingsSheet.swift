import StoreKit
import SwiftUI
import UIKit

struct HomeSettingsSheet: View {
    @Binding var calendarWriteModeRaw: String
    @AppStorage(NotificationPlanner.enabledDefaultsKey) private var notificationsEnabled = true
    /// 默认提前提醒(原始 Int:0 = 准时,其余 = 提前分钟数,档位见 ReminderOffsetPresetOptions)。
    /// 只在待办"出生"时回填,不影响存量。
    @AppStorage(ReminderOffsetConfig.defaultOffsetDefaultsKey) private var defaultOffsetRaw = 0
    @AppStorage(UserVocabularyStore.isEnabledKey, store: UserVocabularyStore.sharedDefaults())
    private var isPersonalizedRecognitionEnabled = true
    /// 匿名诊断上报开关(默认开)。隐私政策承诺「可在设置中随时关闭」,
    /// 存 App Group 与 TelemetryQueue 同库,Uploader 跨进程读取。
    @AppStorage(TelemetrySettings.isEnabledKey, store: TelemetrySettings.sharedDefaults())
    private var isTelemetryEnabled = true
    /// 语音识别语言（"auto" / "zh-Hans" / "en-US"）。
    /// 改了之后下次 startRecording 立即生效（不用重启 App）。
    @AppStorage(SpeechRecognitionLanguage.storageKey)
    private var speechRecognitionLanguage: String = SpeechRecognitionLanguage.auto.rawValue

    /// 一天起始时刻（0–23）。0 = 自然日午夜；3 = 凌晨 3 点才算新一天。
    /// 存 App Group UserDefaults，Widget 直接读，无需额外同步逻辑。
    @AppStorage(DayClock.startHourKey, store: DayClock.appGroupDefaults)
    private var dayStartHour: Int = 0
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var permissionManager: PermissionManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showClearConfirmation = false
    @State private var didClearLearningData = false
    @State private var showFeedbackSheet = false
    /// 兑换码面板拉起失败时的用户可见错误(nil = 不弹 alert)。
    @State private var redeemErrorMessage: String?
    /// 兑换面板请求进行中——防双击并发:第二次 `presentOfferCodeRedeemSheet`
    /// 会因面板已在呈现而抛错,给用户弹误导性的「失败」alert。
    @State private var isPresentingRedeemSheet = false

    private let vocabularyStore: UserVocabularyStore
    private let onUpgradePro: () -> Void
    /// 已订阅时入口文案改为「你已订阅 Pro」,不再对付费用户显示「升级」。
    /// 取 sheet 弹出时刻的值即可:购买发生在付费墙里,而点入口会先收起本 sheet。
    private let isPro: Bool
    private let onImportFromCalendar: () -> Void
    /// 数据体检回调(DEBUG-only UI,Release 下为默认空实现)。
    /// 由 HomeView 注入:取全量库 → `DataHealthAnalyzer.analyze` → os_log 打印。
    private let onRunDataDiagnostics: () -> Void

    init(
        calendarWriteModeRaw: Binding<String>,
        vocabularyStore: UserVocabularyStore = .shared,
        onUpgradePro: @escaping () -> Void = {},
        isPro: Bool = false,
        onImportFromCalendar: @escaping () -> Void = {},
        onRunDataDiagnostics: @escaping () -> Void = {}
    ) {
        _calendarWriteModeRaw = calendarWriteModeRaw
        self.vocabularyStore = vocabularyStore
        self.onUpgradePro = onUpgradePro
        self.isPro = isPro
        self.onImportFromCalendar = onImportFromCalendar
        self.onRunDataDiagnostics = onRunDataDiagnostics
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        onUpgradePro()
                        dismiss()
                    } label: {
                        HStack {
                            Label {
                                Text(String(localized: isPro ? "paywall.subscribed.title" : "paywall.title"))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .layoutPriority(1)
                            } icon: {
                                Image(systemName: isPro ? "checkmark.seal.fill" : "sparkles")
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                    .accessibilityIdentifier("UpgradeProButton")

                    // 兑换码入口(App Store Connect 的 Offer Code):拉起苹果官方兑换面板。
                    // 已订阅用户也保留入口——优惠码同样可以面向存量/流失订阅者发放。
                    Button {
                        presentOfferCodeRedeemSheet()
                    } label: {
                        Label {
                            Text(String(localized: "settings.redeem_code"))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .layoutPriority(1)
                        } icon: {
                            Image(systemName: "giftcard")
                        }
                    }
                    .accessibilityIdentifier("RedeemCodeButton")
                } header: {
                    Text(String(localized: "settings.upgrade_pro.header"))
                }

                // 麦克风 + 语音识别权限入口。iOS 上权限一旦在系统弹窗里被拒,App 内无法再
                // 拉起系统弹窗,只能引导用户去系统设置 —— 这里就是那个引导入口。
                // 状态文案在 scenePhase=.active 时刷新:用户从系统设置切回来能立刻看到结果。
                Section {
                    Button {
                        permissionManager.openAppSettings()
                    } label: {
                        HStack {
                            Label {
                                Text(String(localized: "settings.permissions.voice"))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .layoutPriority(1)
                            } icon: {
                                Image(systemName: "mic.fill")
                            }
                            Spacer()
                            Text(permissionManager.allPermissionsGranted
                                 ? String(localized: "settings.permissions.granted")
                                 : String(localized: "settings.permissions.denied"))
                                .foregroundStyle(permissionManager.allPermissionsGranted
                                                 ? .secondary
                                                 : WarmTheme.warning)
                                .font(.subheadline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                    .accessibilityIdentifier("VoicePermissionsSettingsButton")
                } header: {
                    Text(String(localized: "settings.permissions.title"))
                } footer: {
                    Text(String(localized: "settings.permissions.footer"))
                }

                Section(String(localized: "settings.calendar_write.title")) {
                    Picker(String(localized: "settings.calendar_write.title"), selection: $calendarWriteModeRaw) {
                        ForEach(CalendarWriteMode.allCases) { mode in
                            Text(mode.displayText)
                                .tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("CalendarWriteModePicker")

                    Button {
                        onImportFromCalendar()
                    } label: {
                        Label(String(localized: "calendar_import.button"), systemImage: "calendar")
                            .foregroundStyle(WarmTheme.textPrimary)
                    }
                    .accessibilityIdentifier("ImportFromCalendarButton")
                }

                Section {
                    Stepper(
                        value: $dayStartHour,
                        in: 0...23
                    ) {
                        HStack {
                            Text(String(localized: "settings.day_start_hour.label"))
                            Spacer()
                            Text(dayStartHourFormatted)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("DayStartHourStepper")

                    Text(String(localized: "settings.day_start_hour.description"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "settings.day_start_hour.calendar_note"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "settings.day_start_hour.title"))
                }

                // 日文 Beta 标签(计划书 docs/mvp-japanese-launch/plan.md §6.1-A 最小版):
                // 仅日文系统用户可见;点击进现有 FeedbackSheet,翻译问题分类现成
                // (feedback.type.translation)。首启 modal 等主动开日本市场时再做。
                if Locale.current.identifier.hasPrefix("ja") {
                    Section {
                        Button {
                            showFeedbackSheet = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(String(localized: "settings.ja_beta.title"), systemImage: "info.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(String(localized: "settings.ja_beta.message"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("JaBetaBanner")
                    }
                }

                Section(String(localized: "settings.speech_language.title")) {
                    Picker(String(localized: "settings.speech_language.title"), selection: $speechRecognitionLanguage) {
                        ForEach(SpeechRecognitionLanguage.allCases) { lang in
                            Text(lang.displayName)
                                .tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("SpeechLanguagePicker")
                }

                Section {
                    Toggle(String(localized: "settings.notifications.toggle"), isOn: $notificationsEnabled)
                        .accessibilityIdentifier("NotificationsToggle")
                        // 同步镜像到 App Group:Widget 扩展进程的 intent 局部通知对账
                        // 读不到 App 的 standard,靠镜像尊重全局 OFF(见 AppGroupConfig)。
                        .onChange(of: notificationsEnabled) { _, enabled in
                            AppGroupConfig.mirrorNotificationsEnabled(enabled)
                        }

                    Text(String(localized: "settings.notifications.description"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    // 默认提前提醒:只影响之后新建的带钟点待办(出生时回填),
                    // 存量待办与用户显式选"准时"的待办不会被覆盖。
                    Picker(selection: $defaultOffsetRaw) {
                        ForEach(ReminderOffsetPresetOptions.presets, id: \.self) { preset in
                            Text(ReminderOffsetPresetOptions.label(for: preset))
                                .tag(ReminderOffsetPresetOptions.rawValue(for: preset))
                        }
                    } label: {
                        Text(String(localized: "settings.notifications.default_offset"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityIdentifier("DefaultReminderOffsetPicker")

                    Text(String(localized: "settings.notifications.default_offset.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                } header: {
                    Text(String(localized: "settings.notifications.title"))
                }

                Section {
                    Toggle(String(localized: "settings.personalization.toggle"), isOn: $isPersonalizedRecognitionEnabled)
                        .accessibilityIdentifier("PersonalizedRecognitionToggle")

                    Text(String(localized: "settings.personalization.description"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Text(String(localized: "settings.personalization.clear"))
                    }
                    .accessibilityIdentifier("ClearVocabularyButton")

                    NavigationLink {
                        PersonalGlossaryView()
                    } label: {
                        Label(String(localized: "settings.my_expressions"), systemImage: "text.book.closed")
                    }

                    NavigationLink {
                        ReviewView()
                    } label: {
                        Label(String(localized: "settings.review"), systemImage: "chart.bar.fill")
                    }

                    if didClearLearningData {
                        Text(String(localized: "settings.personalization.cleared"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "settings.personalization.title"))
                }

                Section {
                    Toggle(String(localized: "settings.telemetry.toggle"), isOn: $isTelemetryEnabled)
                        .accessibilityIdentifier("TelemetryToggle")

                    Text(String(localized: "settings.telemetry.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                } header: {
                    Text(String(localized: "settings.telemetry.title"))
                }

                Section {
                    Button {
                        showFeedbackSheet = true
                    } label: {
                        Label(String(localized: "settings.feedback"), systemImage: "envelope.fill")
                    }
                    .accessibilityIdentifier("FeedbackButton")
                } header: {
                    Text(String(localized: "settings.feedback.header"))
                } footer: {
                    Text(String(localized: "settings.feedback.footer"))
                }

                #if DEBUG
                // 阶段 0 · 数据体检(DEBUG-only):打印四组统计到 os_log,
                // 决定洞察 01/05(依赖 Priority.high)何时值得启用。
                // 详见 docs/todo-review-flow-design.md「阶段 0」。
                Section {
                    Button {
                        onRunDataDiagnostics()
                    } label: {
                        Label(String(localized: "settings.diagnostics.run"), systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("DataDiagnosticsButton")
                } header: {
                    Text(String(localized: "settings.diagnostics.header"))
                } footer: {
                    Text(String(localized: "settings.diagnostics.footer"))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                }
                #endif
                Section {
                    // 隐私政策常驻入口(与付费墙法务链接同一 URL):5.1.1 披露的
                    // 日常可触达性——用户不必回到付费墙才能查看数据去向说明。
                    Link(
                        destination: PaywallLegal.privacyPolicyURL
                    ) {
                        Label(
                            String(localized: "settings.privacy_policy"),
                            systemImage: "hand.raised"
                        )
                    }
                }
            }
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackSheet()
            }
            .navigationTitle(String(localized: "settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "settings.done")) {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                String(localized: "settings.personalization.clear_confirm.title"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "settings.personalization.clear_confirm.action"), role: .destructive) {
                    vocabularyStore.clear()
                    didClearLearningData = true
                }
                Button(String(localized: "settings.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings.personalization.clear_confirm.message"))
            }
            .alert(
                String(localized: "settings.redeem_code"),
                isPresented: Binding(
                    get: { redeemErrorMessage != nil },
                    set: { if !$0 { redeemErrorMessage = nil } }
                )
            ) {
                Button(String(localized: "feedback.error.ok")) { redeemErrorMessage = nil }
            } message: {
                Text(redeemErrorMessage ?? "")
            }
            .onChange(of: isPersonalizedRecognitionEnabled) { _, _ in
                didClearLearningData = false
            }
            .onChange(of: dayStartHour) { _, _ in
                WidgetReloadCoalescer.scheduleReload()
            }
            // 用户从系统设置改完麦克风/语音识别权限切回来,刷新状态文案。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                permissionManager.checkCurrentStatus()
            }
        }
    }

    private var dayStartHourFormatted: String {
        String(format: "%02d:00", dayStartHour)
    }

    /// 拉起苹果官方优惠码兑换面板(App Store Connect 生成的 Offer Code)。
    /// 面板、校验、入账全由系统处理;兑换成功经 `Transaction.updates` 推送,
    /// `EntitlementManager` 已监听,Pro 自动解锁,这里无需额外权益逻辑。
    /// 注意:沙盒与本地 StoreKit 测试环境无法兑换优惠码——`presentOfferCodeRedeemSheet`
    /// 可能直接抛错(走 alert 提示),真实兑换只能上线后验证。
    /// 两条失败路径(scene 缺失 / StoreKit 抛错)用户只看通用文案,
    /// 具体原因入 `VoiceTodoLog` 日志供线上排障区分。
    private func presentOfferCodeRedeemSheet() {
        guard !isPresentingRedeemSheet else { return }
        isPresentingRedeemSheet = true
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first else {
            VoiceTodoLog.ui.error("settings.redeem.present_failed reason=scene_not_found")
            isPresentingRedeemSheet = false
            redeemErrorMessage = ErrorMessages.redeemCodeFailed
            return
        }
        Task {
            do {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            } catch {
                VoiceTodoLog.ui.error("settings.redeem.present_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                redeemErrorMessage = ErrorMessages.redeemCodeFailed
            }
            isPresentingRedeemSheet = false
        }
    }
}

#Preview {
    HomeSettingsSheet(calendarWriteModeRaw: .constant(CalendarWriteMode.appOnly.rawValue))
        .environmentObject(PermissionManager())
}
