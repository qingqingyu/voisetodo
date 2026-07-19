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
    @State private var showClearConfirmation = false
    @State private var didClearLearningData = false

    private let vocabularyStore: UserVocabularyStore
    private let onUpgradePro: () -> Void

    init(
        calendarWriteModeRaw: Binding<String>,
        vocabularyStore: UserVocabularyStore = .shared,
        onUpgradePro: @escaping () -> Void = {}
    ) {
        _calendarWriteModeRaw = calendarWriteModeRaw
        self.vocabularyStore = vocabularyStore
        self.onUpgradePro = onUpgradePro
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
                        }
                    }
                    .accessibilityIdentifier("UpgradeProButton")
                } header: {
                    Text(String(localized: "paywall.subtitle"))
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
            .onChange(of: isPersonalizedRecognitionEnabled) { _ in
                didClearLearningData = false
            }
            .onChange(of: dayStartHour) { _ in
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private var dayStartHourFormatted: String {
        String(format: "%02d:00", dayStartHour)
    }
}

#Preview {
    HomeSettingsSheet(calendarWriteModeRaw: .constant(CalendarWriteMode.appOnly.rawValue))
}
