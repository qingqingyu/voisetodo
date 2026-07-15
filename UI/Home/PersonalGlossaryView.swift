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
                Text("还没有教过任何说法。点击右上角添加,让 AI 更懂你说话的方式。")
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
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle("我的说法")
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
            Text(entry.type == .alias ? "别名" : "时间约定")
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
                Section("类型") {
                    Picker("类型", selection: $type) {
                        Text("别名映射").tag(PersonalGlossaryEntryType.alias)
                        Text("时间约定").tag(PersonalGlossaryEntryType.convention)
                    }
                    .pickerStyle(.segmented)
                }

                Section("你的说法") {
                    TextField("例如:老地方、公司、交作业", text: $phrase)
                }

                if type == .alias {
                    Section("展开成") {
                        TextField("例如:星光健身房、XX大厦", text: $expansion)
                    }
                } else {
                    Section("默认时间") {
                        TextField("例如:每周五、3天内、月底", text: $defaultTimeHint)
                    }
                }

                Section {
                    Text(type == .alias
                        ? "之后说「\(phrase)」会自动理解为「\(expansion)」"
                        : "之后说「\(phrase)」会默认安排在\(defaultTimeHint)"
                    )
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)
                }
            }
            .navigationTitle("添加说法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
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
