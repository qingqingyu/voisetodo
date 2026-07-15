import SwiftUI
import WidgetKit

private func formattedDetailDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}

/// 待办详情页 - 温暖主题风格
/// 支持编辑标题、备注、分类、优先级、日期（DatePicker）、重复，以及标记完成/删除
struct TodoDetailView<Store: TodoListReadable>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var store: Store
    let todo: TodoItemData

    @State private var editedTitle: String
    @State private var editedDetail: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueDate: Date?
    @State private var editedHasDueTime: Bool
    @State private var editedTimeBucket: TimeBucket?
    @State private var editedRecurrenceFrequency: RecurrenceFrequency?
    @State private var editedWeekdays: Set<Int>
    @State private var editedDayOfMonth: String
    @State private var hasChanges = false
    @State private var showDeleteConfirmation = false

    init(store: Store, todo: TodoItemData) {
        self.store = store
        self.todo = todo
        _editedTitle = State(initialValue: todo.title)
        _editedDetail = State(initialValue: todo.detail ?? "")
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueDate = State(initialValue: todo.dueDate)
        _editedHasDueTime = State(initialValue: todo.hasDueTime)
        _editedTimeBucket = State(initialValue: todo.timeBucket)
        _editedRecurrenceFrequency = State(initialValue: todo.recurrenceRule?.frequency)
        _editedWeekdays = State(initialValue: Set(todo.recurrenceRule?.weekdays ?? []))
        _editedDayOfMonth = State(initialValue: todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
    }

    private var categoryColor: Color { WarmTheme.color(for: editedCategory) }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                VStack(spacing: WarmSpacing.lg) {
                    // 标题
                    VStack(alignment: .leading) {
                        HStack(spacing: WarmSpacing.xs) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(categoryColor)
                                .frame(width: 4, height: WarmSpacing.xl)
                            Text(String(localized: "detail.section.title"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                        }
                        TextField(String(localized: "detail.title_placeholder"), text: $editedTitle, axis: .vertical)
                            .font(WarmFont.display(22))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1...3)
                            .onChange(of: editedTitle) { _, _ in checkForChanges() }
                    }
                    .padding(WarmSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.sheet)
                            .fill(Color.white)
                            .shadow(color: WarmTheme.shadowMedium, radius: 10, x: 0, y: 5)
                    )

                    // 备注（issue 3：新增 Notes 字段）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.notes"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            TextField(String(localized: "detail.notes_placeholder"), text: $editedDetail, axis: .vertical)
                                .font(WarmFont.body(16))
                                .foregroundColor(WarmTheme.textPrimary)
                                .lineLimit(1...5)
                                .onChange(of: editedDetail) { _, _ in checkForChanges() }
                        }
                    }

                    // 分类
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.category"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: WarmSpacing.xs) {
                                    ForEach(TodoCategory.allCases, id: \.self) { cat in
                                        categoryChip(cat)
                                    }
                                }
                            }
                        }
                    }

                    // 优先级（issue 7：绿色改橙色系；issue 8：统一实心填充）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.priority"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            HStack(spacing: WarmSpacing.sm) {
                                priorityButton(.normal, label: String(localized: "detail.priority.normal"), icon: "minus")
                                priorityButton(.high, label: String(localized: "detail.priority.high"), icon: "exclamationmark")
                            }
                        }
                    }

                    // 日期（issue 1：DatePicker 替换 hint TextField）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.due_date"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            if editedDueDate != nil {
                                HStack {
                                    DatePicker(
                                        "",
                                        selection: Binding(
                                            get: { editedDueDate ?? Date() },
                                            set: { editedDueDate = $0; checkForChanges() }
                                        ),
                                        displayedComponents: .date
                                    )
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    Spacer()
                                    Button {
                                        editedDueDate = nil
                                        editedHasDueTime = false
                                        checkForChanges()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(WarmTheme.textMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Button {
                                    self.editedDueDate = Calendar.current.startOfDay(for: Date())
                                    checkForChanges()
                                } label: {
                                    HStack(spacing: WarmSpacing.xs) {
                                        Image(systemName: "calendar")
                                            .font(.system(size: 15))
                                        Text(String(localized: "detail.add_date"))
                                            .font(WarmFont.body(16))
                                    }
                                    .foregroundColor(WarmTheme.primary)
                                }
                                .buttonStyle(.plain)
                            }

                            // 语音原文备注（保留但不编辑）
                            if let hint = todo.dueHint, !hint.isEmpty {
                                Text(String(format: String(localized: "detail.voice_hint_format"), hint))
                                    .font(WarmFont.caption(12))
                                    .foregroundColor(WarmTheme.textMuted)
                            }
                        }
                    }

                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.time_bucket"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            if editedHasDueTime, let dueDate = editedDueDate {
                                Label(
                                    dueDate.formatted(.dateTime.hour().minute()),
                                    systemImage: "clock"
                                )
                                .font(WarmFont.body(15))
                                .foregroundColor(WarmTheme.textSecondary)
                            } else {
                                HStack(spacing: WarmSpacing.xs) {
                                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                                        timeBucketButton(bucket)
                                    }
                                }
                            }
                        }
                    }

                    recurrenceEditorCard

                    // 标记完成（issue 4：新增）
                    if !todo.isCompleted {
                        Button {
                            coordinator.toggleTodo(todo.id)
                            dismiss()
                        } label: {
                            HStack(spacing: WarmSpacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(String(localized: "detail.mark_done"))
                            }
                            .font(WarmFont.body(16))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarmSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: WarmRadius.section)
                                    .fill(WarmTheme.primary)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 删除（issue 10：加大间距）
                    Button(action: { showDeleteConfirmation = true }) {
                        HStack(spacing: WarmSpacing.xs) {
                            Image(systemName: "trash")
                            Text(String(localized: "detail.delete_button"))
                        }
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.urgent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WarmSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.section)
                                .fill(WarmTheme.urgent.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, WarmSpacing.xl)

                    // 元信息（issue 9：降为底部小字，不做卡片）
                    VStack(spacing: WarmSpacing.xxs) {
                        if todo.needsAIProcessing {
                            HStack(spacing: WarmSpacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(WarmTheme.warning)
                                Text(String(localized: "detail.needs_ai"))
                                    .font(WarmFont.body(13))
                                    .foregroundColor(WarmTheme.warning)
                            }
                        }
                        Text("\(String(localized: "detail.created_at")) \(formattedDetailDate(todo.createdAt))")
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, WarmSpacing.sm)
                }
                .padding(.horizontal, WarmSpacing.xl)
                .padding(.top, WarmSpacing.xl) // issue 6：加大 top padding 防 Title 被导航栏截断
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(String(localized: "detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        // issue 2：砍掉 Save/Discard，返回即自动保存
        .onDisappear { saveIfChanged() }
        .alert(String(localized: "detail.confirm_delete"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "detail.cancel"), role: .cancel) {}
            Button(String(localized: "detail.delete"), role: .destructive) { deleteTodo() }
        } message: {
            Text(String(localized: "detail.delete_warning"))
        }
    }

    // MARK: - Card Wrapper

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(WarmSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
            )
    }

    // MARK: - Chips (issue 8：统一实心填充选中样式)

    private func categoryChip(_ category: TodoCategory) -> some View {
        let isSelected = editedCategory == category
        return Button {
            withAnimation(WarmAnimation.springStandard) { editedCategory = category; checkForChanges() }
        } label: {
            HStack(spacing: WarmSpacing.xxs) {
                Text(category.emoji).font(.system(size: 14))
                Text(category.displayName).font(WarmFont.caption(13))
            }
            .padding(.horizontal, WarmSpacing.sm)
            .padding(.vertical, WarmSpacing.xs)
            .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
            .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // issue 7：Normal=橙色，High=红色，不用绿色
    private func priorityButton(_ priority: Priority, label: String, icon: String) -> some View {
        let isSelected = editedPriority == priority
        let color = priority == .high ? WarmTheme.urgent : WarmTheme.primary
        return Button {
            withAnimation(WarmAnimation.springStandard) { editedPriority = priority; checkForChanges() }
        } label: {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(label).font(WarmFont.body(15))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WarmSpacing.sm)
            .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? color : WarmTheme.secondaryBackground))
            .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func timeBucketButton(_ bucket: TimeBucket) -> some View {
        let selectedBucket = editedTimeBucket ?? .anytime
        let isSelected = selectedBucket == bucket
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedTimeBucket = bucket == .anytime ? nil : bucket
                checkForChanges()
            }
        } label: {
            Text(bucket.localizedTitle)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recurrence Editor

    private var recurrenceEditorCard: some View {
        detailCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "detail.section.recurrence"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)

                HStack(spacing: WarmSpacing.xs) {
                    recurrenceModeButton(nil, title: String(localized: "recurrence.none"))
                    recurrenceModeButton(.daily, title: String(localized: "recurrence.daily"))
                    recurrenceModeButton(.weekly, title: String(localized: "recurrence.weekly_short"))
                    recurrenceModeButton(.monthly, title: String(localized: "recurrence.monthly_short"))
                }

                if editedRecurrenceFrequency == .weekly {
                    HStack(spacing: WarmSpacing.xs) {
                        ForEach(1...7, id: \.self) { weekday in weekdayButton(weekday) }
                    }
                }

                if editedRecurrenceFrequency == .monthly {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(String(localized: "recurrence.monthly_day_prefix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        TextField(String(localized: "recurrence.monthly_day_placeholder"), text: $editedDayOfMonth)
                            .keyboardType(.numberPad)
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textPrimary)
                            .frame(width: 48)
                            .padding(.horizontal, WarmSpacing.xs)
                            .padding(.vertical, WarmSpacing.xs)
                            .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(WarmTheme.secondaryBackground))
                            .onChange(of: editedDayOfMonth) { _, _ in checkForChanges() }
                        Text(String(localized: "recurrence.monthly_day_suffix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                    }
                }

                if let recurrenceValidationMessage {
                    Text(recurrenceValidationMessage)
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.warning)
                }
            }
        }
    }

    private func recurrenceModeButton(_ frequency: RecurrenceFrequency?, title: String) -> some View {
        let isSelected = editedRecurrenceFrequency == frequency
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedRecurrenceFrequency = frequency
                if frequency == .weekly && editedWeekdays.isEmpty {
                    editedWeekdays = [Calendar.current.component(.weekday, from: Date())]
                }
                if frequency == .monthly && editedDayOfMonth.isEmpty {
                    editedDayOfMonth = String(Calendar.current.component(.day, from: Date()))
                }
                checkForChanges()
            }
        } label: {
            Text(title)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, WarmSpacing.xs)
                .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
        }
        .buttonStyle(.plain)
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isSelected = editedWeekdays.contains(weekday)
        return Button {
            if isSelected { editedWeekdays.remove(weekday) } else { editedWeekdays.insert(weekday) }
            checkForChanges()
        } label: {
            Text(shortWeekdayName(weekday))
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: WarmSpacing.xxl)
                .background(RoundedRectangle(cornerRadius: WarmRadius.chip).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
        }
        .buttonStyle(.plain)
    }

    private func shortWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    private var editedRecurrenceRule: RecurrenceRule? {
        switch editedRecurrenceFrequency {
        case .daily: return RecurrenceRule(frequency: .daily)
        case .weekly: return editedWeekdays.isEmpty ? nil : RecurrenceRule(frequency: .weekly, weekdays: Array(editedWeekdays))
        case .monthly:
            guard let day = Int(editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)), (1...31).contains(day) else { return nil }
            return RecurrenceRule(frequency: .monthly, dayOfMonth: day)
        case nil: return nil
        }
    }

    private var recurrenceValidationMessage: String? {
        switch editedRecurrenceFrequency {
        case .weekly: return editedWeekdays.isEmpty ? String(localized: "recurrence.validation.weekly_required") : nil
        case .monthly:
            let trimmed = editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let day = Int(trimmed), (1...31).contains(day) else { return String(localized: "recurrence.validation.monthly_day") }
            return nil
        case .daily, nil: return nil
        }
    }

    private var recurrenceStateChanged: Bool {
        if editedRecurrenceFrequency != todo.recurrenceRule?.frequency { return true }
        switch editedRecurrenceFrequency {
        case .weekly: return editedWeekdays != Set(todo.recurrenceRule?.weekdays ?? [])
        case .monthly: return editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines) != (todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
        case .daily, nil: return false
        }
    }

    // MARK: - Actions

    private func checkForChanges() {
        hasChanges = editedTitle != todo.title ||
                     editedDetail != (todo.detail ?? "") ||
                     editedCategory != todo.category ||
                     editedPriority != todo.priority ||
                     editedDueDate != todo.dueDate ||
                     editedHasDueTime != todo.hasDueTime ||
                     editedTimeBucket != todo.timeBucket ||
                     recurrenceStateChanged
    }

    private func saveIfChanged() {
        guard hasChanges else { return }
        guard recurrenceValidationMessage == nil else {
            coordinator.showToast(message: recurrenceValidationMessage ?? ErrorMessages.storageError, style: .warning)
            return
        }
        let timeMetadataChanged = editedDueDate != todo.dueDate ||
                                  editedHasDueTime != todo.hasDueTime ||
                                  editedTimeBucket != todo.timeBucket ||
                                  recurrenceStateChanged
        do {
            try coordinator.updateTodoDetail(
                todo.id,
                update: TodoDetailUpdate(
                    title: editedTitle,
                    detail: editedDetail.isEmpty ? nil : editedDetail,
                    category: editedCategory != todo.category ? editedCategory : nil,
                    priority: editedPriority != todo.priority ? editedPriority : nil,
                    dueDate: editedDueDate,
                    hasDueTime: editedHasDueTime,
                    timeBucket: editedTimeBucket,
                    dueHint: timeMetadataChanged ? "" : nil,
                    recurrenceRule: editedRecurrenceRule
                )
            )
        } catch {
            VoiceTodoLog.store.error("ui.detail.save_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }

    private func deleteTodo() {
        do {
            try coordinator.deleteTodo(todo.id)
            coordinator.showToast(message: ErrorMessages.todoDeleted, style: .info)
            dismiss()
        } catch {
            VoiceTodoLog.store.error("ui.detail.delete_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.todoDeleteFailed, style: .warning)
        }
    }
}
