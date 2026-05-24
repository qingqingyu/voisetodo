import SwiftUI
import WidgetKit

private func formattedHomeDate(_ date: Date) -> String {
    date.formatted(.dateTime.month().day().weekday(.wide))
}

// MARK: - HomeView

/// 主页视图 - 温暖手账风格
/// 纸张纹理背景 + 手写展示字体 + 分类色带卡片
struct HomeView<Store: TodoStoreProtocol>: View {
    @ObservedObject var store: Store
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showRecordingButton = false
    @State private var isProcessing = false
    @State private var showManualInputSheet = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var visibleMonthAnchor = Calendar.current.startOfDay(for: Date())
    @State private var hasStartedEntranceAnimation = false
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue

    private let waveformHeights: [CGFloat] = [14, 24, 18, 28, 16]
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
                    submitManualInput(text)
                }
            }
            .navigationDestination(item: $selectedTodo) { todo in
                TodoDetailView(store: store, todo: todo)
                    .environmentObject(coordinator)
            }
            .onChange(of: coordinator.deepLinkTodoId) { _, todoId in
                guard let todoId else { return }
                navigateToDeepLinkedTodo(id: todoId)
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
            VStack(alignment: .leading, spacing: 4) {
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

            calendarSettingsMenu
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
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
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "home.stats \(completed) \(total)"))
                .font(WarmFont.caption(14))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(WarmTheme.secondaryBackground)
        )
    }

    private var calendarWriteMode: CalendarWriteMode {
        CalendarWriteMode(rawValue: calendarWriteModeRaw) ?? .appOnly
    }

    private var calendarSettingsMenu: some View {
        Menu {
            Section(String(localized: "settings.calendar_write.title")) {
                ForEach(CalendarWriteMode.allCases) { mode in
                    Button {
                        calendarWriteModeRaw = mode.rawValue
                    } label: {
                        Label(
                            mode.displayText,
                            systemImage: calendarWriteMode == mode ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(WarmTheme.secondaryBackground)
                )
        }
        .accessibilityIdentifier("CalendarWriteModeMenu")
        .accessibilityLabel(String(localized: "settings.calendar_write.title"))
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        ZStack {
            WarmTheme.background.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 24) {
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
                            coordinator.cancelExtraction()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isProcessing = false
                            }
                        }) {
                            Text(String(localized: "home.cancel_extraction"))
                                .font(WarmFont.body(15))
                                .foregroundColor(WarmTheme.textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
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
                            .frame(width: 120, height: 120)

                        Circle()
                            .fill(WarmTheme.primary.opacity(0.15))
                            .frame(width: 80, height: 80)

                        HStack(spacing: 5) {
                            ForEach(Array(waveformHeights.enumerated()), id: \.offset) { i, h in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(WarmTheme.primary)
                                    .frame(width: 5, height: h)
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
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.8))
                                .shadow(color: WarmTheme.shadowLight, radius: 4, y: 2)
                        )
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .animation(.easeOut(duration: 0.2), value: coordinator.transcript)
                }

                Spacer()
            }
        }
        .transition(.opacity)
    }

    // MARK: - Month Home View

    private var visibleMonthDays: [Date] {
        let monthStart = startOfMonth(for: visibleMonthAnchor)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var unscheduledTodos: [TodoItemData] {
        store.todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
    }

    private var selectedDateTitle: String {
        if calendar.isDateInToday(selectedDate) {
            return String(localized: "home.week.today")
        }
        if calendar.isDateInTomorrow(selectedDate) {
            return String(localized: "home.week.tomorrow")
        }
        return selectedDate.formatted(.dateTime.month().day().weekday(.wide))
    }

    private var monthHomeView: some View {
        let monthDays = visibleMonthDays
        let occurrencesByDay = monthOccurrencesByDay(for: monthDays)

        return VStack(spacing: 0) {
            monthHeaderView(monthDays: monthDays, occurrencesByDay: occurrencesByDay)
            selectedDayListView(occurrencesByDay: occurrencesByDay)
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("MonthHomeView")
    }

    private func monthHeaderView(
        monthDays: [Date],
        occurrencesByDay: [String: [TodoOccurrenceData]]
    ) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: { shiftMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PreviousMonthButton")
                .accessibilityLabel(String(localized: "a11y.previous_month"))

                Text(monthTitle)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button(action: { shiftMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NextMonthButton")
                .accessibilityLabel(String(localized: "a11y.next_month"))

                Button(action: jumpToToday) {
                    Text(String(localized: "home.week.today_button"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.primaryDark)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TodayMonthButton")
                .accessibilityLabel(String(localized: "a11y.today_month"))
            }

            HStack(spacing: 6) {
                ForEach(visibleWeekDaysForHeader, id: \.self) { day in
                    Text(shortWeekday(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(monthDays, id: \.self) { day in
                    monthDayButton(for: day, occurrencesByDay: occurrencesByDay)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(WarmTheme.background.opacity(0.94))
    }

    private var visibleWeekDaysForHeader: [Date] {
        let monday = startOfWeek(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private var monthTitle: String {
        visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
    }

    private func monthDayButton(
        for day: Date,
        occurrencesByDay: [String: [TodoOccurrenceData]]
    ) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let isCurrentMonth = calendar.isDate(day, equalTo: visibleMonthAnchor, toGranularity: .month)
        let dayOccurrences = occurrences(on: day, in: occurrencesByDay)
        let hasHighPriority = dayOccurrences.contains { $0.todo.priority == .high && !$0.isCompleted }

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedDate = calendar.startOfDay(for: day)
                visibleMonthAnchor = calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 5) {
                Text(day.formatted(.dateTime.day(.twoDigits)))
                    .font(WarmFont.headline(14))
                    .foregroundColor(isSelected ? .white : (isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))

                HStack(spacing: 2) {
                    ForEach(0..<min(dayOccurrences.count, 3), id: \.self) { index in
                        Circle()
                            .fill(hasHighPriority && index == 0 ? WarmTheme.urgent : (isSelected ? Color.white : WarmTheme.primary))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? WarmTheme.primary : Color.white.opacity(isCurrentMonth ? 0.9 : 0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isToday && !isSelected ? WarmTheme.primary.opacity(0.55) : Color.clear, lineWidth: 1.5)
                    )
                    .shadow(color: isSelected ? WarmTheme.shadowMedium : WarmTheme.shadowLight, radius: isSelected ? 8 : 4, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MonthDay_\(day.formatted(.dateTime.year().month().day()))")
    }

    private func selectedDayListView(occurrencesByDay: [String: [TodoOccurrenceData]]) -> some View {
        let selectedOccurrences = occurrences(on: selectedDate, in: occurrencesByDay)
        let uncompleted = selectedOccurrences.filter { !$0.isCompleted }
        let completed = selectedOccurrences.filter { $0.isCompleted }

        return List {
            Section {
                if uncompleted.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(Array(zip(uncompleted.indices, uncompleted)), id: \.1.id) { index, occurrence in
                        occurrenceRow(occurrence, index: index)
                    }
                }
            } header: {
                daySectionHeader(title: selectedDateTitle, count: uncompleted.count)
            }

            if !completed.isEmpty {
                Section {
                    ForEach(Array(zip(completed.indices, completed)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(occurrence, index: uncompleted.count + idx)
                    }
                } header: {
                    daySectionHeader(title: String(localized: "home.completed_section \(completed.count)"), count: completed.count)
                }
            }

            if !unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(zip(unscheduledTodos.indices, unscheduledTodos)), id: \.1.id) { idx, todo in
                        todoRow(todo, index: selectedOccurrences.count + idx)
                    }
                } header: {
                    daySectionHeader(title: String(localized: "home.week.unscheduled"), count: unscheduledTodos.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("TodoList")
    }

    private var emptySelectedDayRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "home.week.empty_day"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.86))
                .shadow(color: WarmTheme.shadowLight, radius: 5, x: 0, y: 2)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("EmptyState")
    }

    private func daySectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(WarmFont.headline(15))
            Text("\(count)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.primaryDark)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 4, trailing: 20))
    }

    private func todoRow(_ todo: TodoItemData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: { toggleTodo(todo.id) },
            onTap: { selectedTodo = todo }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteTodo(todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.06)) {
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
            onToggle: { toggleOccurrence(occurrence) },
            onTap: { selectedTodo = occurrence.todo }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteTodo(occurrence.todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(occurrence.todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(occurrence.todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(occurrence.todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    // MARK: - Bottom Actions

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            manualInputButton
            recordingButton
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(WarmTheme.background.opacity(0.92))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var manualInputButton: some View {
        Button(action: { showManualInputSheet = true }) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(WarmTheme.primary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(WarmTheme.primary.opacity(0.12))
                    )

                Text(String(localized: "manual_input.home_button"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
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
        Button(action: toggleRecording) {
            HStack(spacing: 10) {
                ZStack {
                    if coordinator.isRecording {
                        Circle()
                            .stroke(WarmTheme.primary.opacity(0.3), lineWidth: 3)
                            .frame(width: 44, height: 44)
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
                        .frame(width: 44, height: 44)
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
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowMedium, radius: 12, x: 0, y: 6)
            )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRecording)
        .accessibilityIdentifier("RecordButton")
        .accessibilityLabel(coordinator.isRecording ? String(localized: "a11y.stop_recording") : String(localized: "a11y.start_voice_input"))
        .accessibilityHint(coordinator.isRecording ? String(localized: "a11y.stop_hint") : String(localized: "a11y.start_hint"))
    }

    // MARK: - Actions

    private func navigateToDeepLinkedTodo(id: UUID) {
        if let todo = store.todos.first(where: { $0.id == id }) {
            selectedTodo = todo
            coordinator.deepLinkTodoId = nil
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard coordinator.deepLinkTodoId == id else { return }
            if let todo = store.todos.first(where: { $0.id == id }) {
                selectedTodo = todo
            }
            coordinator.deepLinkTodoId = nil
        }
    }

    private func startEntranceAnimation() {
        if !hasStartedEntranceAnimation {
            let today = calendar.startOfDay(for: Date())
            selectedDate = today
            visibleMonthAnchor = today
            hasStartedEntranceAnimation = true
        }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
            headerOffset = 0
            headerOpacity = 1
        }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.25)) {
            listOffset = 0
            listOpacity = 1
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                showRecordingButton = true
            }
        }
    }

    private func startOfWeek(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
    }

    private func monthOccurrencesByDay(for monthDays: [Date]) -> [String: [TodoOccurrenceData]] {
        guard let firstDay = monthDays.first,
              let lastDay = monthDays.last else {
            return [:]
        }
        return Dictionary(grouping: store.calendarOccurrences(from: firstDay, to: lastDay)) { occurrence in
            TodoOccurrenceData.dayKey(for: occurrence.occurrenceDate, calendar: calendar)
        }
    }

    private func occurrences(
        on day: Date,
        in occurrencesByDay: [String: [TodoOccurrenceData]]
    ) -> [TodoOccurrenceData] {
        occurrencesByDay[TodoOccurrenceData.dayKey(for: day, calendar: calendar)] ?? []
    }

    private func shortWeekday(for date: Date) -> String {
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

    private func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private func shiftMonth(by value: Int) {
        guard let newAnchor = calendar.date(byAdding: .month, value: value, to: visibleMonthAnchor) else {
            return
        }
        let normalizedAnchor = startOfMonth(for: newAnchor)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            visibleMonthAnchor = normalizedAnchor
            selectedDate = normalizedAnchor
        }
    }

    private func jumpToToday() {
        let today = calendar.startOfDay(for: Date())
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedDate = today
            visibleMonthAnchor = today
        }
    }

    private func toggleRecording() {
        if coordinator.isRecording {
            Task {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isProcessing = true
                }
                await coordinator.stopRecordingAndProcess()
                withAnimation(.easeInOut(duration: 0.3)) {
                    isProcessing = false
                }
            }
        } else {
            Task {
                await coordinator.startRecording()
            }
        }
    }

    private func submitManualInput(_ text: String) {
        showManualInputSheet = false
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeInOut(duration: 0.3)) {
                isProcessing = true
            }
            await coordinator.processManualInput(text)
            withAnimation(.easeInOut(duration: 0.3)) {
                isProcessing = false
            }
        }
    }

    private func toggleTodo(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            do {
                try store.toggleComplete(id)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    private func toggleOccurrence(_ occurrence: TodoOccurrenceData) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            do {
                try store.toggleOccurrenceComplete(occurrence.todo.id, on: occurrence.occurrenceDate)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    private func deleteTodo(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            do {
                try coordinator.deleteTodo(id)
            } catch {
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
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
                .padding(.vertical, 10)

            HStack(spacing: 14) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .stroke(
                                todo.isCompleted ? WarmTheme.success : categoryColor,
                                lineWidth: 2.5
                            )
                            .frame(width: 26, height: 26)

                        if todo.isCompleted {
                            Circle()
                                .fill(WarmTheme.success)
                                .frame(width: 26, height: 26)

                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
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

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(todo.category.emoji)
                            .font(.system(size: 15))

                        Text(todo.title)
                            .font(todo.priority == .high ? WarmFont.headline(16) : WarmFont.body(16))
                            .foregroundColor(todo.isCompleted ? WarmTheme.textMuted : WarmTheme.textPrimary)
                            .strikethrough(todo.isCompleted, color: WarmTheme.textMuted)
                            .lineLimit(2)
                    }

                    if let dueHint = todo.dueHint, !todo.isCompleted {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(dueHint)
                                .font(WarmFont.caption(12))
                        }
                        .foregroundColor(WarmTheme.textSecondary)
                    }

                    if let recurrenceRule = todo.recurrenceRule, !todo.isCompleted {
                        HStack(spacing: 4) {
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
                    Text("!")
                        .font(WarmFont.body(13))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(WarmTheme.urgent)
                        )
                        .accessibilityIdentifier("PriorityLabel")
                        .accessibilityLabel(String(localized: "a11y.high_priority"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(
            RoundedRectangle(cornerRadius: 16)
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

// MARK: - Preview
