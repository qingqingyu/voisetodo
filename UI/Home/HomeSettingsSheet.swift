import SwiftUI
import WidgetKit

struct HomeSettingsSheet: View {
    @Binding var calendarWriteModeRaw: String
    @AppStorage(NotificationPlanner.enabledDefaultsKey) private var notificationsEnabled = true
    @AppStorage(UserVocabularyStore.isEnabledKey, store: UserVocabularyStore.sharedDefaults())
    private var isPersonalizedRecognitionEnabled = true
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

    private let vocabularyStore: UserVocabularyStore
    private let onUpgradePro: () -> Void
    private let onImportFromCalendar: () -> Void

    init(
        calendarWriteModeRaw: Binding<String>,
        vocabularyStore: UserVocabularyStore = .shared,
        onUpgradePro: @escaping () -> Void = {},
        onImportFromCalendar: @escaping () -> Void = {}
    ) {
        _calendarWriteModeRaw = calendarWriteModeRaw
        self.vocabularyStore = vocabularyStore
        self.onUpgradePro = onUpgradePro
        self.onImportFromCalendar = onImportFromCalendar
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
                            Label(String(localized: "paywall.title"), systemImage: "sparkles")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                    .accessibilityIdentifier("UpgradeProButton")
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

                    Text(String(localized: "settings.notifications.description"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .onChange(of: isPersonalizedRecognitionEnabled) { _, _ in
                didClearLearningData = false
            }
            .onChange(of: dayStartHour) { _, _ in
                WidgetCenter.shared.reloadAllTimelines()
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
}

#Preview {
    HomeSettingsSheet(calendarWriteModeRaw: .constant(CalendarWriteMode.appOnly.rawValue))
        .environmentObject(PermissionManager())
}
