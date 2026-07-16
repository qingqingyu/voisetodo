import SwiftUI

/// "我的说法"设置页——管理 PersonalGlossary 条目。
/// 用户可以手动教 App:"老地方"=某健身房、"交作业"=每周五。
/// 教一次后,每次录音提取都注入 prompt 让 AI 理解个人表达习惯。
struct PersonalGlossaryView: View {
    private let store = PersonalGlossaryStore.shared
    @State private var entries: [PersonalGlossaryEntry] = []
    @State private var showingAddSheet = false

    var body: some View {
        List {
            if entries.isEmpty {
                Text(String(localized: "glossary.empty_state"))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textSecondary)
                    .padding(.vertical, WarmSpacing.lg)
            } else {
                ForEach(entries) { entry in
                    GlossaryEntryRow(entry: entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(id: entry.id)
                                reload()
                            } label: {
                                Label(String(localized: "common.delete"), systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle(String(localized: "glossary.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddGlossaryEntrySheet { newEntry in
                store.add(newEntry)
                reload()
            }
        }
        .onAppear {
            reload()
        }
    }

    private func reload() {
        entries = store.allEntries().sorted { $0.phrase < $1.phrase }
    }
}

// MARK: - Entry Row

private struct GlossaryEntryRow: View {
    let entry: PersonalGlossaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack {
                Text(entry.phrase)
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)
                Image(systemName: entry.type == .alias ? "arrow.right" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(WarmTheme.textMuted)
                Text(entry.type == .alias ? (entry.expansion ?? "") : (entry.defaultTimeHint ?? ""))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textSecondary)
            }
            Text(entry.type == .alias
                 ? String(localized: "glossary.entry.alias_badge")
                 : String(localized: "glossary.entry.convention_badge"))
                .font(WarmFont.caption(11))
                .foregroundColor(WarmTheme.primary)
                .padding(.horizontal, WarmSpacing.xs)
                .padding(.vertical, 2)
                .background(Capsule().fill(WarmTheme.primary.opacity(0.1)))
        }
        .padding(.vertical, WarmSpacing.xxs)
    }
}

// MARK: - Add Entry Sheet

private struct AddGlossaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (PersonalGlossaryEntry) -> Void

    @State private var type: PersonalGlossaryEntryType = .alias
    @State private var phrase = ""
    @State private var expansion = ""
    @State private var defaultTimeHint = ""

    private var isValid: Bool {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return false }
        if type == .alias {
            return !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !defaultTimeHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "glossary.add.section.type")) {
                    Picker(String(localized: "glossary.add.section.type"), selection: $type) {
                        Text(String(localized: "glossary.add.type.alias")).tag(PersonalGlossaryEntryType.alias)
                        Text(String(localized: "glossary.add.type.convention")).tag(PersonalGlossaryEntryType.convention)
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "glossary.add.section.phrase")) {
                    TextField(String(localized: "glossary.add.phrase.placeholder"), text: $phrase)
                }

                if type == .alias {
                    Section(String(localized: "glossary.add.section.expansion")) {
                        TextField(String(localized: "glossary.add.expansion.placeholder"), text: $expansion)
                    }
                } else {
                    Section(String(localized: "glossary.add.section.default_time")) {
                        TextField(String(localized: "glossary.add.default_time.placeholder"), text: $defaultTimeHint)
                    }
                }

                Section {
                    Text(type == .alias
                        ? String(localized: "glossary.add.preview.alias \(phrase) \(expansion)")
                        : String(localized: "glossary.add.preview.convention \(phrase) \(defaultTimeHint)")
                    )
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)
                }
            }
            .navigationTitle(String(localized: "glossary.add.nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.save")) {
                        onSave(PersonalGlossaryEntry(
                            type: type,
                            phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                            expansion: type == .alias ? expansion.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                            defaultTimeHint: type == .convention ? defaultTimeHint.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                            localeIdentifier: Locale.current.identifier
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
