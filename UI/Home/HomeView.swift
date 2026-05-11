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
    @State private var visibleWeekAnchor = Calendar.current.startOfDay(for: Date())
    @State private var hasStartedEntranceAnimation = false

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
                            weekHomeView
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

    // MARK: - Week Home View

    private var visibleWeekDays: [Date] {
        let weekStart = startOfWeek(for: visibleWeekAnchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var selectedDayTodos: [TodoItemData] {
        store.todos.filter { todo in
            guard let dueDate = todo.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: selectedDate)
        }
    }

    private var selectedDayUncompletedTodos: [TodoItemData] {
        selectedDayTodos.filter { !$0.isCompleted }
    }

    private var selectedDayCompletedTodos: [TodoItemData] {
        selectedDayTodos.filter { $0.isCompleted }
    }

    private var unscheduledTodos: [TodoItemData] {
        store.todos.filter { $0.dueDate == nil }
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

    private var weekHomeView: some View {
        VStack(spacing: 0) {
            weekHeaderView
            selectedDayListView
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("WeekHomeView")
    }

    private var weekHeaderView: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: { shiftWeek(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PreviousWeekButton")
                .accessibilityLabel(String(localized: "a11y.previous_week"))

                Text(weekRangeTitle)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button(action: { shiftWeek(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NextWeekButton")
                .accessibilityLabel(String(localized: "a11y.next_week"))

                Button(action: jumpToToday) {
                    Text(String(localized: "home.week.today_button"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.primaryDark)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TodayWeekButton")
                .accessibilityLabel(String(localized: "a11y.today_week"))
            }

            HStack(spacing: 6) {
                ForEach(visibleWeekDays, id: \.self) { day in
                    weekDayButton(for: day)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(WarmTheme.background.opacity(0.94))
    }

    private var weekRangeTitle: String {
        guard let first = visibleWeekDays.first,
              let last = visibleWeekDays.last else {
            return String(localized: "home.week.this_week")
        }
        let range = "\(first.formatted(.dateTime.month().day())) - \(last.formatted(.dateTime.month().day()))"
        if visibleWeekDays.contains(where: calendar.isDateInToday) {
            return String(localized: "home.week.this_week_range \(range)")
        }
        return range
    }

    private func weekDayButton(for day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let dayTodos = todos(on: day)
        let hasHighPriority = dayTodos.contains { $0.priority == .high && !$0.isCompleted }

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedDate = calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 6) {
                Text(shortWeekday(for: day))
                    .font(WarmFont.caption(12))
                    .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)

                Text(day.formatted(.dateTime.day(.twoDigits)))
                    .font(WarmFont.headline(15))
                    .foregroundColor(isSelected ? .white : WarmTheme.textPrimary)

                HStack(spacing: 2) {
                    ForEach(0..<min(dayTodos.count, 3), id: \.self) { index in
                        Circle()
                            .fill(hasHighPriority && index == 0 ? WarmTheme.urgent : (isSelected ? Color.white : WarmTheme.primary))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? WarmTheme.primary : Color.white.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isToday && !isSelected ? WarmTheme.primary.opacity(0.55) : Color.clear, lineWidth: 1.5)
                    )
                    .shadow(color: isSelected ? WarmTheme.shadowMedium : WarmTheme.shadowLight, radius: isSelected ? 8 : 4, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("WeekDay_\(day.formatted(.dateTime.year().month().day()))")
    }

    private var selectedDayListView: some View {
        let uncompleted = selectedDayUncompletedTodos
        let completed = selectedDayCompletedTodos

        return List {
            Section {
                if uncompleted.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(Array(zip(uncompleted.indices, uncompleted)), id: \.1.id) { index, todo in
                        todoRow(todo, index: index)
                    }
                }
            } header: {
                daySectionHeader(title: selectedDateTitle, count: uncompleted.count)
            }

            if !completed.isEmpty {
                Section {
                    ForEach(Array(zip(completed.indices, completed)), id: \.1.id) { idx, todo in
                        todoRow(todo, index: uncompleted.count + idx)
                    }
                } header: {
                    daySectionHeader(title: String(localized: "home.completed_section \(completed.count)"), count: completed.count)
                }
            }

            if !unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(zip(unscheduledTodos.indices, unscheduledTodos)), id: \.1.id) { idx, todo in
                        todoRow(todo, index: selectedDayTodos.count + idx)
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
            visibleWeekAnchor = today
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

    private func todos(on day: Date) -> [TodoItemData] {
        store.todos.filter { todo in
            guard let dueDate = todo.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: day)
        }
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

    private func shiftWeek(by value: Int) {
        guard let newAnchor = calendar.date(byAdding: .weekOfYear, value: value, to: visibleWeekAnchor),
              let newSelectedDate = calendar.date(byAdding: .weekOfYear, value: value, to: selectedDate) else {
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            visibleWeekAnchor = calendar.startOfDay(for: newAnchor)
            selectedDate = calendar.startOfDay(for: newSelectedDate)
        }
    }

    private func jumpToToday() {
        let today = calendar.startOfDay(for: Date())
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedDate = today
            visibleWeekAnchor = today
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

    private func deleteTodo(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            do {
                try store.delete(id)
                WidgetCenter.shared.reloadAllTimelines()
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
