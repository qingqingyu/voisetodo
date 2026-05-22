import SwiftUI
import WidgetKit

private func formattedDetailDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}

/// 待办详情页 - 温暖主题风格
/// 支持编辑标题、分类、优先级、时间提示，以及删除
struct TodoDetailView<Store: TodoStoreProtocol>: View {
    // MARK: - Properties

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var store: Store
    let todo: TodoItemData

    @State private var editedTitle: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueHint: String
    @State private var editedRecurrenceFrequency: RecurrenceFrequency?
    @State private var editedWeekdays: Set<Int>
    @State private var editedDayOfMonth: String
    @State private var hasChanges = false
    @State private var showDeleteConfirmation = false

    // MARK: - Initialization

    init(store: Store, todo: TodoItemData) {
        self.store = store
        self.todo = todo
        _editedTitle = State(initialValue: todo.title)
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueHint = State(initialValue: todo.dueHint ?? "")
        _editedRecurrenceFrequency = State(initialValue: todo.recurrenceRule?.frequency)
        _editedWeekdays = State(initialValue: Set(todo.recurrenceRule?.weekdays ?? []))
        _editedDayOfMonth = State(initialValue: todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
    }

    // MARK: - Body

    private var categoryColor: Color {
        WarmTheme.color(for: editedCategory)
    }

    private var canSave: Bool {
        hasChanges &&
            !editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            recurrenceValidationMessage == nil
    }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                VStack(spacing: 20) {
                    // 标题编辑 — 视觉焦点，更大的 padding 和装饰
                    VStack(alignment: .leading) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(categoryColor)
                                .frame(width: 4, height: 28)

                            Text(String(localized: "detail.section.title"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                        }

                        TextField(String(localized: "confirm.todo_title_placeholder"), text: $editedTitle, axis: .vertical)
                            .font(WarmFont.display(22))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1...3)
                            .onChange(of: editedTitle) { _, _ in checkForChanges() }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white)
                            .shadow(color: WarmTheme.shadowMedium, radius: 10, x: 0, y: 5)
                    )

                    // 分类选择
                    detailCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "detail.section.category"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(TodoCategory.allCases, id: \.self) { category in
                                        categoryChip(category)
                                    }
                                }
                            }
                        }
                    }

                    // 优先级选择
                    detailCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "detail.section.priority"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            HStack(spacing: 12) {
                                priorityButton(.normal, label: String(localized: "detail.priority.normal"), icon: "minus")
                                priorityButton(.high, label: String(localized: "detail.priority.high"), icon: "exclamationmark")
                            }
                        }
                    }

                    // 时间提示
                    detailCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "detail.section.due_hint"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            TextField(String(localized: "detail.due_hint_placeholder"), text: $editedDueHint)
                                .font(WarmFont.body(17))
                                .foregroundColor(WarmTheme.textPrimary)
                                .onChange(of: editedDueHint) { _, _ in checkForChanges() }
                        }
                    }

                    recurrenceEditorCard

                    // 元信息
                    detailCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "detail.created_at"))
                                    .font(WarmFont.body(15))
                                    .foregroundColor(WarmTheme.textPrimary)
                                Spacer()
                                Text(formattedDetailDate(todo.createdAt))
                                    .font(WarmFont.caption(14))
                                    .foregroundColor(WarmTheme.textSecondary)
                            }

                            if todo.needsAIProcessing {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(WarmTheme.warning)
                                    Text(String(localized: "detail.needs_ai"))
                                        .font(WarmFont.body(14))
                                        .foregroundColor(WarmTheme.warning)
                                }
                            }
                        }
                    }

                    // 删除按钮
                    Button(action: { showDeleteConfirmation = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                            Text(String(localized: "detail.delete_button"))
                        }
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.urgent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(WarmTheme.urgent.opacity(0.08))
                        )
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(String(localized: "detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "detail.discard")) { dismiss() }
                        .font(WarmFont.body(16))
                        .foregroundColor(WarmTheme.textSecondary)
                }
            }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "detail.save")) { saveChanges() }
                        .font(WarmFont.headline(16))
                        .foregroundColor(canSave ? WarmTheme.primary : WarmTheme.textMuted)
                        .disabled(!canSave)
                }
            }
        .alert(String(localized: "detail.confirm_delete"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "detail.cancel"), role: .cancel) {}
            Button(String(localized: "detail.delete"), role: .destructive) { deleteTodo() }
        } message: {
            Text(String(localized: "detail.delete_warning"))
        }
    }

    // MARK: - Card Wrapper

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
        )
    }

    // MARK: - Category Chip

    private func categoryChip(_ category: TodoCategory) -> some View {
        let isSelected = editedCategory == category
        return Button {
            withAnimation(.spring(response: 0.3)) {
                editedCategory = category
                checkForChanges()
            }
        } label: {
            HStack(spacing: 4) {
                Text(category.emoji)
                    .font(.system(size: 14))
                Text(category.displayName)
                    .font(WarmFont.caption(13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? WarmTheme.primary.opacity(0.15) : WarmTheme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? WarmTheme.primary : Color.clear, lineWidth: 1.5)
            )
            .foregroundColor(isSelected ? WarmTheme.primaryDark : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Priority Button

    private func priorityButton(_ priority: Priority, label: String, icon: String) -> some View {
        let isSelected = editedPriority == priority
        let color = priority == .high ? WarmTheme.urgent : WarmTheme.success
        return Button {
            withAnimation(.spring(response: 0.3)) {
                editedPriority = priority
                checkForChanges()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(WarmFont.body(15))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.12) : WarmTheme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1.5)
            )
            .foregroundColor(isSelected ? color : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recurrence Editor

    private var recurrenceEditorCard: some View {
        detailCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "detail.section.recurrence"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)

                HStack(spacing: 8) {
                    recurrenceModeButton(nil, title: String(localized: "recurrence.none"))
                    recurrenceModeButton(.daily, title: String(localized: "recurrence.daily"))
                    recurrenceModeButton(.weekly, title: String(localized: "recurrence.weekly_short"))
                    recurrenceModeButton(.monthly, title: String(localized: "recurrence.monthly_short"))
                }

                if editedRecurrenceFrequency == .weekly {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { weekday in
                            weekdayButton(weekday)
                        }
                    }
                }

                if editedRecurrenceFrequency == .monthly {
                    HStack(spacing: 8) {
                        Text(String(localized: "recurrence.monthly_day_prefix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        TextField("1", text: $editedDayOfMonth)
                            .keyboardType(.numberPad)
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textPrimary)
                            .frame(width: 52)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WarmTheme.secondaryBackground)
                            )
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
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
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
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground)
                )
        }
        .buttonStyle(.plain)
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isSelected = editedWeekdays.contains(weekday)
        return Button {
            if isSelected {
                editedWeekdays.remove(weekday)
            } else {
                editedWeekdays.insert(weekday)
            }
            checkForChanges()
        } label: {
            Text(shortWeekdayName(weekday))
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground)
                )
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
        case .daily:
            return RecurrenceRule(frequency: .daily)
        case .weekly:
            return editedWeekdays.isEmpty ? nil : RecurrenceRule(frequency: .weekly, weekdays: Array(editedWeekdays))
        case .monthly:
            guard let day = Int(editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...31).contains(day) else {
                return nil
            }
            return RecurrenceRule(frequency: .monthly, dayOfMonth: day)
        case nil:
            return nil
        }
    }

    private var recurrenceValidationMessage: String? {
        switch editedRecurrenceFrequency {
        case .weekly:
            return editedWeekdays.isEmpty ? String(localized: "recurrence.validation.weekly_required") : nil
        case .monthly:
            let trimmed = editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let day = Int(trimmed), (1...31).contains(day) else {
                return String(localized: "recurrence.validation.monthly_day")
            }
            return nil
        case .daily, nil:
            return nil
        }
    }

    private var recurrenceStateChanged: Bool {
        if editedRecurrenceFrequency != todo.recurrenceRule?.frequency {
            return true
        }
        switch editedRecurrenceFrequency {
        case .weekly:
            return editedWeekdays != Set(todo.recurrenceRule?.weekdays ?? [])
        case .monthly:
            return editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines) != (todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
        case .daily, nil:
            return false
        }
    }

    // MARK: - Actions

    private func checkForChanges() {
        hasChanges = editedTitle != todo.title ||
                     editedCategory != todo.category ||
                     editedPriority != todo.priority ||
                     editedDueHint != (todo.dueHint ?? "") ||
                     recurrenceStateChanged
    }

    private func saveChanges() {
        guard recurrenceValidationMessage == nil else {
            coordinator.showToast(message: recurrenceValidationMessage ?? ErrorMessages.storageError, style: .warning)
            return
        }

        do {
            let newCategory = editedCategory != todo.category ? editedCategory : nil
            let newPriority = editedPriority != todo.priority ? editedPriority : nil
            let newDueHint: String? = editedDueHint != (todo.dueHint ?? "") ? editedDueHint : nil

            try store.update(
                todo.id,
                title: editedTitle,
                category: newCategory,
                priority: newPriority,
                dueHint: newDueHint,
                recurrenceRule: editedRecurrenceRule
            )

            WidgetCenter.shared.reloadAllTimelines()

            coordinator.showToast(message: ErrorMessages.todoSaved, style: .success)
            dismiss()
        } catch {
            coordinator.showToast(message: ErrorMessages.todoSaveFailedMessage(error.localizedDescription), style: .warning)
        }
    }

    private func deleteTodo() {
        do {
            try store.delete(todo.id)
            WidgetCenter.shared.reloadAllTimelines()
            coordinator.showToast(message: ErrorMessages.todoDeleted, style: .info)
            dismiss()
        } catch {
            coordinator.showToast(message: ErrorMessages.todoDeleteFailed, style: .warning)
        }
    }
}
