import SwiftUI

struct HomeSettingsSheet: View {
    @Binding var calendarWriteModeRaw: String
    @AppStorage(NotificationPlanner.enabledDefaultsKey) private var notificationsEnabled = true
    @AppStorage(UserVocabularyStore.isEnabledKey, store: UserVocabularyStore.sharedDefaults())
    private var isPersonalizedRecognitionEnabled = true
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
        }
    }
}

#Preview {
    HomeSettingsSheet(calendarWriteModeRaw: .constant(CalendarWriteMode.appOnly.rawValue))
}
