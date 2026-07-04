import SwiftUI
import UIKit
import WidgetKit

private func formattedHomeDate(_ date: Date) -> String {
    date.formatted(.dateTime.month().day().weekday(.wide))
}

// MARK: - HomeView

private struct HomeCalendarDayState {
    let date: Date
    let occurrences: [TodoOccurrenceData]
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let hasHighPriority: Bool
}

/// 首页日历视图模式：整月网格 / 单周一行。
enum CalendarViewMode: String {
    case month
    case week
}

private struct HomeCalendarState {
    let selectedDate: Date
    let visibleMonthAnchor: Date
    let viewMode: CalendarViewMode
    /// 当前模式下要渲染的日期：月视图为整月网格（42 天），周视图为所在周 7 天。
    let visibleDays: [Date]
    let weekHeaderDays: [Date]
    let occurrencesByDay: [String: [TodoOccurrenceData]]
    let unscheduledTodos: [TodoItemData]
    let selectedOccurrences: [TodoOccurrenceData]
    let uncompletedOccurrences: [TodoOccurrenceData]
    let completedOccurrences: [TodoOccurrenceData]
    let hasTodos: Bool

    private let calendar: Calendar

    var monthTitle: String {
        switch viewMode {
        case .month:
            return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
        case .week:
            guard let first = visibleDays.first, let last = visibleDays.last else {
                return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
            }
            return "\(first.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))"
        }
    }

    var selectedDateTitle: String {
        if calendar.isDateInToday(selectedDate) {
            return String(localized: "home.week.today")
        }
        if calendar.isDateInTomorrow(selectedDate) {
            return String(localized: "home.week.tomorrow")
        }
        return selectedDate.formatted(.dateTime.month().day().weekday(.wide))
    }

    static func make<Store: HomeTodoStore>(
        store: Store,
        selectedDate: Date,
        visibleMonthAnchor: Date,
        viewMode: CalendarViewMode,
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar,
        now: Date = Date()
    ) -> HomeCalendarState {
        let normalizedSelectedDate = calendar.startOfDay(for: selectedDate)
        let normalizedAnchor = calendar.startOfDay(for: visibleMonthAnchor)
        let visibleDays = days(for: viewMode, anchor: normalizedAnchor, calendar: calendar)

        return HomeCalendarState(
            todos: store.todos,
            selectedDate: normalizedSelectedDate,
            visibleMonthAnchor: normalizedAnchor,
            viewMode: viewMode,
            visibleDays: visibleDays,
            weekHeaderDays: weekHeaderDays(referenceDate: now, calendar: calendar),
            occurrencesByDay: occurrencesByDay,
            calendar: calendar
        )
    }

    static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    func dayState(for day: Date) -> HomeCalendarDayState {
        let dayOccurrences = occurrences(on: day)
        return HomeCalendarDayState(
            date: day,
            occurrences: dayOccurrences,
            isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
            isToday: calendar.isDateInToday(day),
            // 周视图 7 天等权重，不按"当月"置灰；月视图保留跨月补齐日的弱化样式。
            isCurrentMonth: viewMode == .week
                ? true
                : calendar.isDate(day, equalTo: visibleMonthAnchor, toGranularity: .month),
            hasHighPriority: dayOccurrences.contains { $0.todo.priority == .high && !$0.isCompleted }
        )
    }

    func weekdayTitle(for date: Date) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    private init(
        todos: [TodoItemData],
        selectedDate: Date,
        visibleMonthAnchor: Date,
        viewMode: CalendarViewMode,
        visibleDays: [Date],
        weekHeaderDays: [Date],
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) {
        self.selectedDate = selectedDate
        self.visibleMonthAnchor = visibleMonthAnchor
        self.viewMode = viewMode
        self.visibleDays = visibleDays
        self.weekHeaderDays = weekHeaderDays
        self.occurrencesByDay = occurrencesByDay
        self.unscheduledTodos = todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
        self.hasTodos = !todos.isEmpty
        self.calendar = calendar

        let selectedOccurrences = Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)
        self.selectedOccurrences = selectedOccurrences
        self.uncompletedOccurrences = selectedOccurrences.filter { !$0.isCompleted }
        self.completedOccurrences = selectedOccurrences.filter { $0.isCompleted }
    }

    private func occurrences(on day: Date) -> [TodoOccurrenceData] {
        Self.occurrences(on: day, in: occurrencesByDay, calendar: calendar)
    }

    private static func occurrences(
        on day: Date,
        in occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) -> [TodoOccurrenceData] {
        occurrencesByDay[TodoOccurrenceData.dayKey(for: day, calendar: calendar)] ?? []
    }

    /// 按模式返回要渲染/加载的日期集合。月视图 42 天网格；周视图所在周 7 天。
    static func days(for viewMode: CalendarViewMode, anchor: Date, calendar: Calendar) -> [Date] {
        switch viewMode {
        case .month:
            return monthDays(for: anchor, calendar: calendar)
        case .week:
            return weekDays(for: anchor, calendar: calendar)
        }
    }

    static func monthDays(for visibleMonthAnchor: Date, calendar: Calendar) -> [Date] {
        let monthStart = startOfMonth(for: visibleMonthAnchor, calendar: calendar)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// 锚点所在周的 7 天（与月视图同为周一起始，复用 startOfWeek）。
    static func weekDays(for anchor: Date, calendar: Calendar) -> [Date] {
        let start = startOfWeek(for: anchor, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func weekHeaderDays(referenceDate: Date, calendar: Calendar) -> [Date] {
        let monday = startOfWeek(for: referenceDate, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
    }
}

private enum HomeCalendarLoadState {
    case loading
    case empty
    case error
    case success
}

@MainActor
/// 月历 occurrence 缓存的刷新键：当月锚点 / 当前 todos / occurrence 完成修订号任一变化即重算。
/// 用于 `.task(id:)` —— 规律任务 occurrence 完成切换不改 `store.todos`，必须靠 revision 触发刷新。
///
/// 性能取舍：用 `[TodoItemData]` 全数组做 Hashable，500 todos × ~20 字段 = μs 级比较，
/// 远小于 SwiftData fetch + 规则展开的耗时（后者才是 CLAUDE.md 性能表里的瓶颈）。
/// 派生 token（count + lastMutatedId）会漏掉对单条 todo 字段编辑的感知，不正确；
/// 用 `TodoStore.dataRevision` 全局自增能省掉这层比较，但需要 TodoStore 在所有写操作处 bump，
/// 工作量大且容易漏。当前方案是正确性优先。
private struct CalendarRefreshKey: Hashable {
    let anchor: Date
    let mode: CalendarViewMode
    let todos: [TodoItemData]
    let revision: Int
}

@MainActor
private struct HomeViewActions<Store: HomeTodoStore> {
    let store: Store
    let coordinator: AppCoordinator
    let permissionManager: PermissionManager
    let setProcessing: (Bool) -> Void
    let setManualInputPresented: (Bool) -> Void
    let selectTodo: (TodoItemData) -> Void
    /// 通知视图：规律任务 occurrence 完成状态已写入（store.todos 不会变化），需要刷新月历缓存。
    let markCalendarDataChanged: () -> Void

    func showManualInput() {
        setManualInputPresented(true)
    }

    func cancelExtraction() {
        coordinator.cancelExtraction()
        updateProcessing(false)
    }

    func navigateToDeepLinkedTodo(id: UUID) {
        if let todo = store.todos.first(where: { $0.id == id }) {
            selectTodo(todo)
            coordinator.deepLinkTodoId = nil
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard coordinator.deepLinkTodoId == id else { return }
            if let todo = store.todos.first(where: { $0.id == id }) {
                selectTodo(todo)
            }
            coordinator.deepLinkTodoId = nil
        }
    }

    func toggleRecording() {
        if coordinator.isRecording {
            Task { @MainActor in
                updateProcessing(true)
                await coordinator.stopRecordingAndProcess()
                updateProcessing(false)
            }
        } else {
            Task { @MainActor in
                let readiness = await permissionManager.ensureVoicePermissionsBeforeRecording()
                if readiness == .granted {
                    await coordinator.startRecording()
                } else {
                    coordinator.showVoicePermissionRequiredToast()
                }
            }
        }
    }

    func submitManualInput(_ text: String) {
        setManualInputPresented(false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            updateProcessing(true)
            await coordinator.processManualInput(text)
            updateProcessing(false)
        }
    }

    func toggleTodo(_ id: UUID) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try store.toggleComplete(id)
                WidgetCenter.shared.reloadAllTimelines()
                VoiceTodoLog.store.info("ui.home.toggle.success id=\(id.uuidString, privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.toggle.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    func toggleOccurrence(_ occurrence: TodoOccurrenceData) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try store.toggleOccurrenceComplete(occurrence.todo.id, on: occurrence.occurrenceDate)
                WidgetCenter.shared.reloadAllTimelines()
                markCalendarDataChanged()
                VoiceTodoLog.store.info("ui.home.toggle_occurrence.success id=\(occurrence.todo.id.uuidString, privacy: .public) date=\(occurrence.occurrenceDate.ISO8601Format(), privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.toggle_occurrence.failed id=\(occurrence.todo.id.uuidString, privacy: .public) date=\(occurrence.occurrenceDate.ISO8601Format(), privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    func deleteTodo(_ id: UUID) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try coordinator.deleteTodo(id)
                VoiceTodoLog.store.info("ui.home.delete.success id=\(id.uuidString, privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.delete.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    private func updateProcessing(_ isProcessing: Bool) {
        withAnimation(.easeInOut(duration: 0.3)) {
            setProcessing(isProcessing)
        }
    }
}

private struct HomeMonthHeaderView: View {
    let state: HomeCalendarState
    let onShift: (Int) -> Void
    let onJumpToToday: () -> Void
    let onSelectDay: (Date) -> Void
    let onSetViewMode: (CalendarViewMode) -> Void

    private var viewModeBinding: Binding<CalendarViewMode> {
        Binding(get: { state.viewMode }, set: { onSetViewMode($0) })
    }

    var body: some View {
        VStack(spacing: WarmSpacing.sm) {
            Picker("", selection: viewModeBinding) {
                Text(String(localized: "calendar.mode.month")).tag(CalendarViewMode.month)
                Text(String(localized: "calendar.mode.week")).tag(CalendarViewMode.week)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("CalendarViewModePicker")
            .accessibilityLabel(String(localized: "a11y.calendar_mode"))

            HStack {
                Button(action: { onShift(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PreviousMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.previous_week" : "a11y.previous_month"))

                Text(state.monthTitle)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button(action: { onShift(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NextMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.next_week" : "a11y.next_month"))

                Button(action: onJumpToToday) {
                    Text(String(localized: "home.week.today_button"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.primaryDark)
                        .padding(.horizontal, WarmSpacing.sm)
                        .frame(height: 32)
                        .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TodayMonthButton")
                .accessibilityLabel(String(localized: "a11y.today_month"))
            }

            HStack(spacing: WarmSpacing.xs) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: WarmSpacing.xs), count: 7), spacing: WarmSpacing.xs) {
                ForEach(state.visibleDays, id: \.self) { day in
                    HomeMonthDayButton(dayState: state.dayState(for: day), onSelect: onSelectDay)
                }
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.top, WarmSpacing.xxs)
        .padding(.bottom, WarmSpacing.sm)
        .background(WarmTheme.background.opacity(0.94))
    }
}

private struct HomeMonthDayButton: View {
    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void

    var body: some View {
        Button {
            onSelect(dayState.date)
        } label: {
            VStack(spacing: WarmSpacing.xxs) {
                Text(dayState.date.formatted(.dateTime.day(.twoDigits)))
                    .font(WarmFont.headline(14))
                    .foregroundColor(dayState.isSelected ? .white : (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))

                HStack(spacing: 2) {
                    ForEach(0..<min(dayState.occurrences.count, 3), id: \.self) { index in
                        Circle()
                            .fill(dayState.hasHighPriority && index == 0 ? WarmTheme.urgent : (dayState.isSelected ? Color.white : WarmTheme.primary))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: WarmSpacing.xxxl)
            // 选中态放大：弱动画提示用户"我点对了"，但不夸张到挤压相邻格
            // （月历 7 列宽，放大太多会重叠）。Reduce Motion 时 animation 会被系统忽略。
            .scaleEffect(dayState.isSelected ? WarmAnimation.monthDaySelectedScale : WarmAnimation.monthDayDefaultScale)
            .animation(WarmAnimation.springSmooth, value: dayState.isSelected)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .fill(dayState.isSelected ? WarmTheme.primary : Color.white.opacity(dayState.isCurrentMonth ? 0.9 : 0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: WarmRadius.card)
                            .stroke(dayState.isToday && !dayState.isSelected ? WarmTheme.primary.opacity(0.55) : Color.clear, lineWidth: 1.5)
                    )
                    .shadow(color: dayState.isSelected ? WarmTheme.shadowMedium : WarmTheme.shadowLight, radius: dayState.isSelected ? 8 : 4, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceOverLabel.build(for: dayState))
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthDay_\(dayState.date.formatted(.dateTime.year().month().day()))")
    }
}

/// VoiceOver 文案构造：把日历单元格的状态翻译成完整一句话。
/// 月视图单元格视觉信息（数字、点、底色）对低视力/盲人用户没用，必须用文字补全。
/// 顺序遵循可达性惯例：身份（日期）在前，状态（非当月/今天/待办数）在后。
/// 使用 app 当前本地化语言 + gregorian 日历格式化日期，避免系统区域语言与 app 文案混读。
private enum VoiceOverLabel {
    private static let gregorian = Calendar(identifier: .gregorian)

    static func build(for dayState: HomeCalendarDayState) -> String {
        var parts = [
            monthDayText(for: dayState.date),
            weekdayText(for: dayState.date)
        ]

        // 状态在后
        if !dayState.isCurrentMonth {
            parts.append(String(localized: "a11y.day.out_of_month"))
        }
        if dayState.isToday {
            parts.append(String(localized: "a11y.day.today"))
        }
        let count = dayState.occurrences.count
        if count > 0 {
            parts.append(String(format: String(localized: "a11y.day.todo_count"), count))
        } else {
            parts.append(String(localized: "a11y.day.no_todo"))
        }
        return parts.joined(separator: String(localized: "a11y.day.separator"))
    }

    private static func monthDayText(for date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day()
        style.calendar = gregorian
        style.locale = appLocale
        return date.formatted(style)
    }

    private static func weekdayText(for date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.calendar = gregorian
        style.locale = appLocale
        return date.formatted(style)
    }

    private static var appLocale: Locale {
        guard let identifier = Bundle.main.preferredLocalizations.first(where: { $0 != "Base" }) else {
            return .current
        }
        return Locale(identifier: identifier)
    }
}

private struct HomeSelectedDayListView: View {
    let state: HomeCalendarState
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onDeleteTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    let onMoveUnscheduled: (IndexSet, Int) -> Void
    let onStartRecording: @Sendable () -> Void
    let onShowManualInput: @Sendable () -> Void

    var body: some View {
        List {
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if state.selectedOccurrences.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(Array(zip(state.uncompletedOccurrences.indices, state.uncompletedOccurrences)), id: \.1.id) { index, occurrence in
                        occurrenceRow(occurrence, index: index)
                    }
                }
            } header: {
                daySectionHeader(title: state.selectedDateTitle, count: state.uncompletedOccurrences.count)
            }

            if !state.completedOccurrences.isEmpty {
                Section {
                    ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(occurrence, index: state.uncompletedOccurrences.count + idx)
                    }
                } header: {
                    daySectionHeader(title: String(localized: "home.completed_section \(state.completedOccurrences.count)"), count: state.completedOccurrences.count)
                }
            }

            if !state.unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(state.unscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        todoRow(todo, index: state.selectedOccurrences.count + idx)
                    }
                    .onMove(perform: onMoveUnscheduled)
                } header: {
                    daySectionHeader(title: String(localized: "home.week.unscheduled"), count: state.unscheduledTodos.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("TodoList")
    }

    private var homeGlobalEmptyRow: some View {
        // 不放 primaryAction / secondaryAction——底部 action bar 已经有「录音」+「文字输入」
        // 两个入口，这里再放一份会让用户在两个位置看到同样的按钮，UI 冗余。
        // 空状态只做文案引导，用户视线自然落到屏幕底部 action bar。
        ProductEmptyStateView(
            icon: "sparkles",
            title: String(localized: "empty.home.title"),
            message: String(localized: "empty.home.message")
        )
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.sm, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    private var emptySelectedDayRow: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "empty.day.title"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(Color.white.opacity(0.86))
                .shadow(color: WarmTheme.shadowLight, radius: 5, x: 0, y: 2)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("EmptyState")
    }

    private func daySectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(title)
                .font(WarmFont.headline(15))
            Text("\(count)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.primaryDark)
                .padding(.horizontal, WarmSpacing.xs)
                .padding(.vertical, WarmSpacing.xxs)
                .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: WarmSpacing.md, leading: WarmSpacing.xl, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
    }

    private func todoRow(_ todo: TodoItemData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    private func occurrenceRow(_ occurrence: TodoOccurrenceData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: occurrence.todo,
            onToggle: { onToggleOccurrence(occurrence) },
            onTap: { onOpenTodo(occurrence.todo) }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(occurrence.todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(occurrence.todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(occurrence.todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(occurrence.todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }
}

private struct HomeCalendarLoadingView: View {
    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                .scaleEffect(1.2)

            Text(String(localized: "home.calendar.loading"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("HomeCalendarLoadingState")
    }
}

private struct HomeCalendarErrorView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: WarmSpacing.md) {
                ProductEmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "home.calendar.error.title"),
                    message: String(localized: "home.calendar.error.message")
                )

                Button(action: onRetry) {
                    Label(String(localized: "common.retry"), systemImage: "arrow.clockwise")
                        .font(WarmFont.headline(15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: WarmSize.touch)
                        .background(
                            Capsule()
                                .fill(WarmTheme.primary)
                                .shadow(color: WarmTheme.shadowMedium, radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HomeCalendarRetryButton")
            }
            .padding(.horizontal, WarmSpacing.xl)
            .accessibilityIdentifier("HomeCalendarErrorState")

            Spacer()
        }
    }
}

/// 主页视图 - 温暖手账风格
/// 纸张纹理背景 + 手写展示字体 + 分类色带卡片
struct HomeView<Store: HomeTodoStore>: View {
    @ObservedObject var store: Store
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var permissionManager: PermissionManager
    @State private var showRecordingButton = false
    @State private var isProcessing = false
    @State private var showManualInputSheet = false
    @State private var showSettingsSheet = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var visibleMonthAnchor = Calendar.current.startOfDay(for: Date())
    @State private var hasStartedEntranceAnimation = false
    /// 月历 occurrence 缓存：由后台 `queryActor` 异步加载，主线程不再做 SwiftData fetch/展开。
    /// `.task(id:)` 在 visibleMonthAnchor / store.todos / occurrenceRevision 变化时刷新。
    @State private var monthOccurrences: [String: [TodoOccurrenceData]] = [:]
    @State private var calendarLoadState: HomeCalendarLoadState = .loading
    /// 规律任务 occurrence 完成切换不会改 `store.todos`（完成记录在独立表），用此 revision 强制刷新。
    @State private var occurrenceRevision = 0
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
    /// 日历视图模式（月/周），跨启动记住上次选择。
    @AppStorage("calendarViewMode") private var calendarViewModeRaw = CalendarViewMode.month.rawValue
    private var calendarViewMode: CalendarViewMode {
        CalendarViewMode(rawValue: calendarViewModeRaw) ?? .month
    }

    private let waveformHeights: [CGFloat] = [12, 24, 20, 32, 16]
    private let calendar = Calendar.current

    // MARK: - Initialization

    init(store: Store) {
        self.store = store
    }

    @State private var selectedTodo: TodoItemData?

    // 动画状态
    @State private var headerOffset: CGFloat = -50
    @State private var headerOpacity: Double = 0
    @State private var listOffset: CGFloat = 30
    @State private var listOpacity: Double = 0
    @State private var cardAppeared: Set<UUID> = []

    private var actions: HomeViewActions<Store> {
        HomeViewActions(
            store: store,
            coordinator: coordinator,
            permissionManager: permissionManager,
            setProcessing: { isProcessing = $0 },
            setManualInputPresented: { showManualInputSheet = $0 },
            selectTodo: { selectedTodo = $0 },
            markCalendarDataChanged: { occurrenceRevision += 1 }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(spacing: 0) {
                    headerView

                    if coordinator.isRecording || isProcessing || coordinator.isExtracting {
                        recordingOverlay
                    }

                    Group {
                        if !coordinator.isRecording && !isProcessing && !coordinator.isExtracting {
                            monthHomeView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                startEntranceAnimation()
            }
            .overlay {
                if coordinator.isRecording {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("RecordingIndicator")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showRecordingButton {
                    bottomActionBar
                }
            }
            .sheet(isPresented: $showManualInputSheet) {
                ManualInputSheetView { text in
                    actions.submitManualInput(text)
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                HomeSettingsSheet(
                    calendarWriteModeRaw: $calendarWriteModeRaw,
                    onUpgradePro: { coordinator.showPaywall = true }
                )
            }
            .navigationDestination(item: $selectedTodo) { todo in
                TodoDetailView(store: store, todo: todo)
                    .environmentObject(coordinator)
            }
            .onChange(of: coordinator.deepLinkTodoId) { _, todoId in
                guard let todoId else { return }
                actions.navigateToDeepLinkedTodo(id: todoId)
            }
            .onChange(of: store.todos.count) { _, _ in
                let currentIds: Set<UUID> = Set(store.todos.map(\.id))
                cardAppeared = cardAppeared.intersection(currentIds)
            }
        }
        .accessibilityIdentifier("HomeView")
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(formattedHomeDate(Date()))
                    .font(WarmFont.caption(14))
                    .foregroundColor(WarmTheme.textSecondary)

                Text(greetingText)
                    .font(WarmFont.display(30))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Spacer()

            if !store.todos.isEmpty {
                statsBadge
            }

            settingsButton
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.md)
        .padding(.bottom, WarmSpacing.lg)
        .background(
            WarmTheme.background.opacity(0.9)
                .shadow(color: WarmTheme.shadowLight, radius: 1, y: 1)
        )
        .offset(y: headerOffset)
        .opacity(headerOpacity)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return String(localized: "home.greeting.morning")
        case 12..<14:
            return String(localized: "home.greeting.noon")
        case 14..<18:
            return String(localized: "home.greeting.afternoon")
        case 18..<22:
            return String(localized: "home.greeting.evening")
        default:
            return String(localized: "home.greeting.night")
        }
    }

    private var statsBadge: some View {
        let total = store.todos.count
        let completed = store.todos.filter { $0.isCompleted }.count
        return HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "home.stats \(completed) \(total)"))
                .font(WarmFont.caption(14))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .padding(.horizontal, WarmSpacing.sm)
        .padding(.vertical, WarmSpacing.xs)
        .background(
            Capsule()
                .fill(WarmTheme.secondaryBackground)
        )
    }

    private var settingsButton: some View {
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.textSecondary)
                .frame(width: WarmSize.touch, height: WarmSize.touch)
                .background(
                    Circle()
                        .fill(WarmTheme.secondaryBackground)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HomeSettingsButton")
        .accessibilityLabel(String(localized: "settings.title"))
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        ZStack {
            WarmTheme.background.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: WarmSpacing.xl) {
                Spacer()

                if isProcessing || coordinator.isExtracting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                        .scaleEffect(1.5)

                    Text(String(localized: "home.processing"))
                        .font(WarmFont.displayLight(20))
                        .foregroundColor(WarmTheme.textSecondary)

                    if coordinator.isExtracting {
                        Button(action: {
                            actions.cancelExtraction()
                        }) {
                            Text(String(localized: "home.cancel_extraction"))
                                .font(WarmFont.body(15))
                                .foregroundColor(WarmTheme.textSecondary)
                                .padding(.horizontal, WarmSpacing.lg)
                                .padding(.vertical, WarmSpacing.xs)
                                .background(
                                    Capsule()
                                        .stroke(WarmTheme.textMuted, lineWidth: 1)
                                )
                        }
                        .accessibilityIdentifier("CancelExtractionButton")
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(WarmTheme.primary.opacity(0.08))
                            .frame(width: WarmSize.mega, height: WarmSize.mega)

                        Circle()
                            .fill(WarmTheme.primary.opacity(0.15))
                            .frame(width: WarmSize.hero, height: WarmSize.hero)

                        HStack(spacing: WarmSpacing.xxs) {
                            ForEach(Array(waveformHeights.enumerated()), id: \.offset) { i, h in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(WarmTheme.primary)
                                    .frame(width: 4, height: h)
                                    .animation(
                                        .easeInOut(duration: 0.5)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.12),
                                        value: coordinator.isRecording
                                    )
                            }
                        }
                    }

                    Text(String(localized: "home.listening"))
                        .font(WarmFont.display(22))
                        .foregroundColor(WarmTheme.textPrimary)
                }

                if !coordinator.transcript.isEmpty {
                    Text(coordinator.transcript)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, WarmSpacing.xxl)
                        .padding(.vertical, WarmSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.section)
                                .fill(Color.white.opacity(0.8))
                                .shadow(color: WarmTheme.shadowLight, radius: 4, y: 2)
                        )
                        .padding(.horizontal, WarmSpacing.xl)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .animation(.easeOut(duration: 0.2), value: coordinator.transcript)
                }

                Spacer()
            }
        }
        .transition(.opacity)
    }

    // MARK: - Month Home View

    private var monthHomeView: some View {
        let state = HomeCalendarState.make(
            store: store,
            selectedDate: selectedDate,
            visibleMonthAnchor: visibleMonthAnchor,
            viewMode: calendarViewMode,
            occurrencesByDay: monthOccurrences,
            calendar: calendar
        )

        return VStack(spacing: 0) {
            HomeMonthHeaderView(
                state: state,
                onShift: shiftPeriod,
                onJumpToToday: jumpToToday,
                onSelectDay: selectDay,
                onSetViewMode: setViewMode
            )

            switch calendarLoadState {
            case .loading:
                HomeCalendarLoadingView()
            case .error:
                HomeCalendarErrorView(onRetry: retryCalendarLoad)
            case .empty, .success:
                HomeSelectedDayListView(
                    state: state,
                    cardAppeared: $cardAppeared,
                    onToggleTodo: { actions.toggleTodo($0) },
                    onToggleOccurrence: { actions.toggleOccurrence($0) },
                    onDeleteTodo: { actions.deleteTodo($0) },
                    onOpenTodo: { selectedTodo = $0 },
                    onMoveUnscheduled: { source, destination in
                        moveUnscheduled(from: source, to: destination)
                    },
                    onStartRecording: {
                        Task { @MainActor in
                            actions.toggleRecording()
                        }
                    },
                    onShowManualInput: {
                        Task { @MainActor in
                            actions.showManualInput()
                        }
                    }
                )
            }
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("MonthHomeView")
        .task(id: CalendarRefreshKey(anchor: visibleMonthAnchor, mode: calendarViewMode, todos: store.todos, revision: occurrenceRevision)) {
            let startedAt = Date()
            // 注意：这里**不**主动设 .loading（避免切月份时清掉旧数据导致闪烁）。
            // 唯一例外：如果当前是 .error 态（上一次加载失败），重置为 .loading ——
            // 因为错误态本来就没有可保留的旧数据，重置闪烁可接受，反而避免新月份加载期间错误视图盖屏。
            if calendarLoadState == .error {
                calendarLoadState = .loading
            }
            // .success / .empty / 初始 .loading 都不主动设，保留旧值。
            let rangeDays = HomeCalendarState.days(for: calendarViewMode, anchor: visibleMonthAnchor, calendar: calendar)
            guard let firstDay = rangeDays.first, let lastDay = rangeDays.last else {
                monthOccurrences = [:]
                calendarLoadState = store.todos.isEmpty ? .empty : .success
                VoiceTodoLog.store.warning("home.month_occurrences.load_skipped reason=no_month_days anchor=\(visibleMonthAnchor.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                return
            }
            do {
                let groupedOccurrences = try await store.groupedCalendarOccurrences(
                    from: firstDay,
                    to: lastDay,
                    calendar: calendar
                )
                guard !Task.isCancelled else {
                    VoiceTodoLog.store.debug("home.month_occurrences.load_cancelled start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    return
                }
                monthOccurrences = groupedOccurrences
                calendarLoadState = store.todos.isEmpty ? .empty : .success
                VoiceTodoLog.store.debug("home.month_occurrences.load_success start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) dayBuckets=\(monthOccurrences.count) todoCount=\(store.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            } catch is CancellationError {
                VoiceTodoLog.store.debug("home.month_occurrences.load_cancelled start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            } catch {
                calendarLoadState = .error
                VoiceTodoLog.store.error("home.month_occurrences.load_failed start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) todoCount=\(store.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
    }

    private func retryCalendarLoad() {
        occurrenceRevision += 1
    }

    private func selectDay(_ day: Date) {
        withAnimation(WarmAnimation.springStandard) {
            selectedDate = calendar.startOfDay(for: day)
            visibleMonthAnchor = calendar.startOfDay(for: day)
        }
    }

    // MARK: - Bottom Actions

    private var bottomActionBar: some View {
        VStack(spacing: WarmSpacing.xs) {
            manualInputButton
            recordingButton
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.xs)
        .padding(.bottom, WarmSpacing.sm)
        .background(WarmTheme.background.opacity(0.92))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var manualInputButton: some View {
        Button(action: { actions.showManualInput() }) {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(WarmTheme.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(WarmTheme.primary.opacity(0.12))
                    )

                Text(String(localized: "manual_input.home_button"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, WarmSpacing.md)
            .padding(.vertical, WarmSpacing.sm)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .overlay(
                        Capsule()
                            .stroke(WarmTheme.primary.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isRecording || coordinator.isExtracting || isProcessing)
        .opacity(coordinator.isRecording || coordinator.isExtracting || isProcessing ? 0.55 : 1)
        .accessibilityIdentifier("ManualInputButton")
        .accessibilityLabel(String(localized: "a11y.manual_input"))
        .accessibilityHint(String(localized: "a11y.manual_input_hint"))
    }

    private var recordingButton: some View {
        Button(action: { actions.toggleRecording() }) {
            HStack(spacing: WarmSpacing.xs) {
                ZStack {
                    if coordinator.isRecording {
                        Circle()
                            .stroke(WarmTheme.primary.opacity(0.3), lineWidth: 3)
                            .frame(width: WarmSize.touch, height: WarmSize.touch)
                            .scaleEffect(coordinator.isRecording ? 1.3 : 1.0)
                            .animation(
                                Animation.easeInOut(duration: 0.8)
                                    .repeatForever(autoreverses: true),
                                value: coordinator.isRecording
                            )
                    }

                    Image(systemName: coordinator.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: WarmSize.touch, height: WarmSize.touch)
                        .background(
                            Circle()
                                .fill(coordinator.isRecording ? WarmTheme.urgent : WarmTheme.primary)
                        )
                }

                Text(coordinator.isRecording ? String(localized: "home.listening") : String(localized: "home.start_recording"))
                    .font(WarmFont.headline(17))
                    .foregroundColor(WarmTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, WarmSpacing.xl)
            .padding(.vertical, WarmSpacing.md)
            .background(
                Capsule()
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowMedium, radius: 12, x: 0, y: 6)
            )
        }
        .animation(WarmAnimation.springSmooth, value: coordinator.isRecording)
        .accessibilityIdentifier("RecordButton")
        .accessibilityLabel(coordinator.isRecording ? String(localized: "a11y.stop_recording") : String(localized: "a11y.start_voice_input"))
        .accessibilityHint(coordinator.isRecording ? String(localized: "a11y.stop_hint") : String(localized: "a11y.start_hint"))
    }

    // MARK: - Actions

    private func startEntranceAnimation() {
        if !hasStartedEntranceAnimation {
            let today = calendar.startOfDay(for: Date())
            selectedDate = today
            visibleMonthAnchor = today
            hasStartedEntranceAnimation = true
        }

        withAnimation(WarmAnimation.springEntrance.delay(0.1)) {
            headerOffset = 0
            headerOpacity = 1
        }

        withAnimation(WarmAnimation.springEntrance.delay(0.25)) {
            listOffset = 0
            listOpacity = 1
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(WarmAnimation.springButton) {
                showRecordingButton = true
            }
        }
    }

    /// 模式感知的翻页：月视图按月翻，周视图按周翻。
    private func shiftPeriod(by value: Int) {
        let component: Calendar.Component = calendarViewMode == .week ? .weekOfYear : .month
        guard let newAnchor = calendar.date(byAdding: component, value: value, to: visibleMonthAnchor) else {
            return
        }
        let normalizedAnchor: Date = calendarViewMode == .week
            ? calendar.startOfDay(for: newAnchor)
            : HomeCalendarState.startOfMonth(for: newAnchor, calendar: calendar)
        withAnimation(WarmAnimation.springStandard) {
            visibleMonthAnchor = normalizedAnchor
            selectedDate = normalizedAnchor
        }
    }

    private func setViewMode(_ mode: CalendarViewMode) {
        guard calendarViewMode != mode else { return }
        withAnimation(WarmAnimation.springStandard) {
            calendarViewModeRaw = mode.rawValue
            // 把可视锚点对齐到当前选中日：切周→显示选中日所在周，切月→显示选中日所在月，
            // 避免切换后选中高亮/下方任务列表落在看不见的区间外。
            visibleMonthAnchor = mode == .week
                ? calendar.startOfDay(for: selectedDate)
                : HomeCalendarState.startOfMonth(for: selectedDate, calendar: calendar)
        }
    }

    private func jumpToToday() {
        let today = calendar.startOfDay(for: Date())
        withAnimation(WarmAnimation.springStandard) {
            selectedDate = today
            visibleMonthAnchor = today
        }
    }

    /// 拖动重排「无日期」段：只在无日期任务之间互换全局位置，已排期/已完成任务槽位不动，
    /// 避免打乱 Widget 依赖的全局 sortOrder。
    private func moveUnscheduled(from source: IndexSet, to destination: Int) {
        // 与 HomeCalendarState.unscheduledTodos 同源同序（store.todos 已按 sortOrder 升序）。
        var displayed = store.todos.filter(TodoReorderPlanner.isUnscheduled)
        displayed.move(fromOffsets: source, toOffset: destination)
        let newUnscheduledOrder = displayed.filter { !$0.isCompleted }.map(\.id)
        let uncompleted = store.todos.filter { !$0.isCompleted }
        let fullIds = TodoReorderPlanner.reorderedUncompletedIDs(
            uncompleted: uncompleted,
            newUnscheduledOrder: newUnscheduledOrder
        )
        do {
            try store.reorder(ids: fullIds)
        } catch {
            VoiceTodoLog.store.error("home.reorder_unscheduled.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            store.refreshTodos()
        }
    }
}

// MARK: - Warm Todo Card

struct WarmTodoCard: View {
    let index: Int
    let todo: TodoItemData
    let onToggle: () -> Void
    var onTap: (() -> Void)? = nil

    private var categoryColor: Color {
        WarmTheme.color(for: todo.category)
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(todo.isCompleted ? WarmTheme.textMuted.opacity(0.3) : categoryColor)
                .frame(width: 4)
                .padding(.vertical, WarmSpacing.xs)

            HStack(spacing: WarmSpacing.sm) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .stroke(
                                todo.isCompleted ? WarmTheme.success : categoryColor,
                                lineWidth: 2.5
                            )
                            .frame(width: WarmSize.icon, height: WarmSize.icon)

                        Circle()
                            .fill(WarmTheme.success)
                            .frame(width: WarmSize.icon, height: WarmSize.icon)
                            .opacity(todo.isCompleted ? 1 : 0)
                            .animation(.easeInOut(duration: 0.2), value: todo.isCompleted)

                        WarmCheckmarkShape()
                            .trim(from: 0, to: todo.isCompleted ? 1 : 0)
                            .stroke(
                                .white,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: WarmSize.icon - 6, height: WarmSize.icon - 6)
                            .animation(.easeInOut(duration: 0.3), value: todo.isCompleted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TodoCheckbox_\(index)")
                .accessibilityLabel(todo.isCompleted ? String(localized: "a11y.completed") : String(localized: "a11y.not_completed"))
                .accessibilityHint({
                    let action = todo.isCompleted
                        ? String(localized: "a11y.mark_incomplete")
                        : String(localized: "a11y.mark_complete")
                    return String(localized: "a11y.toggle_complete \(action)")
                }())

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(todo.category.emoji)
                            .font(.system(size: 15))

                        Text(todo.title)
                            .font(todo.priority == .high ? WarmFont.headline(16) : WarmFont.body(16))
                            .foregroundColor(todo.isCompleted ? WarmTheme.textMuted : WarmTheme.textPrimary)
                            .strikethrough(todo.isCompleted, color: WarmTheme.textMuted)
                            .lineLimit(2)
                    }

                    if let dueHint = todo.dueHint, !todo.isCompleted {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(dueHint)
                                .font(WarmFont.caption(12))
                        }
                        .foregroundColor(WarmTheme.textSecondary)
                    }

                    if let recurrenceRule = todo.recurrenceRule, !todo.isCompleted {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "repeat")
                                .font(.system(size: 10, weight: .semibold))
                            Text(recurrenceRule.displayText)
                                .font(WarmFont.caption(12))
                        }
                        .foregroundColor(WarmTheme.primaryDark)
                    }
                }

                Spacer()

                if todo.priority == .high && !todo.isCompleted {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(WarmTheme.urgent)
                        )
                        .accessibilityIdentifier("PriorityLabel")
                        .accessibilityLabel(String(localized: "a11y.high_priority"))
                }
            }
            .padding(.leading, WarmSpacing.sm)
            .padding(.trailing, WarmSpacing.md)
            .padding(.vertical, WarmSpacing.md)
        }
        .clipShape(RoundedRectangle(cornerRadius: WarmRadius.section))
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .accessibilityIdentifier("TodoCell_\(index)")
        .accessibilityValue(todo.isCompleted ? String(localized: "a11y.completed") : String(localized: "a11y.not_completed"))
        .accessibilityHint(String(localized: "a11y.view_detail"))
    }
}

// MARK: - Checkmark Shape

/// 勾号路径 — 借鉴 M13Checkbox 的 `M13CheckboxCheckPathGenerator`：
/// 用三点折线（短臂起点 → 中点 → 长臂顶点），配合 `.trim(from:to:)` 做"沿路径一笔绘制"的 stroke 动画。
/// 不直接用 SF Symbols 的 `checkmark`，是因为后者无法控制 stroke 的渐变绘制时机，
/// 而 `trim` 让"短臂→中点→长臂"按顺序出现，视觉上就是"被一笔勾出"。
private struct WarmCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p1 = CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.55)
        let p2 = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.75)
        let p3 = CGPoint(x: rect.minX + rect.width * 0.85, y: rect.minY + rect.height * 0.25)
        path.move(to: p1)
        path.addLine(to: p2)
        path.addLine(to: p3)
        return path
    }
}

// MARK: - Preview

#Preview {
    HomeView(store: MockStore.preview)
        .environmentObject(AppCoordinator.preview)
}
