import SwiftUI
import WidgetKit

private let homeDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "M月d日 EEEE"
    return formatter
}()

// MARK: - HomeView

/// 主页视图 - 温暖友好风格
/// 显示待办列表，支持勾选完成、左滑删除、点击编辑
struct HomeView<Store: TodoStoreProtocol>: View {
    @ObservedObject var store: Store
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showRecordingButton = false
    @State private var isProcessing = false

    private let waveformHeights: [CGFloat] = [14, 24, 18, 28, 16]

    // MARK: - Initialization

    init(store: Store) {
        self.store = store
    }

    // 导航状态
    @State private var selectedTodo: TodoItemData?

    // 动画状态
    @State private var headerOffset: CGFloat = -50
    @State private var headerOpacity: Double = 0
    @State private var listOffset: CGFloat = 30
    @State private var listOpacity: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景
                WarmTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 自定义导航栏
                    headerView

                    // 录音实时预览
                    if coordinator.isRecording || isProcessing {
                        recordingOverlay
                    }

                    // 主内容
                    Group {
                        if store.todos.isEmpty && !coordinator.isRecording && !isProcessing {
                            emptyStateView
                        } else if !coordinator.isRecording && !isProcessing {
                            todoListView
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
            .overlay(alignment: .bottom) {
                if showRecordingButton {
                    recordingButton
                }
            }
            // 导航到详情页
            .navigationDestination(item: $selectedTodo) { todo in
                TodoDetailView(store: store, todo: todo)
                    .environmentObject(coordinator)
            }
            // Widget 深链导航
            .onChange(of: coordinator.deepLinkTodoId) { _, todoId in
                guard let todoId else { return }
                navigateToDeepLinkedTodo(id: todoId)
            }
        }
        .accessibilityIdentifier("HomeView")
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                // 日期
                Text(homeDateFormatter.string(from: Date()))
                    .font(.custom("Avenir Next", size: 14))
                    .fontWeight(.medium)
                    .foregroundColor(WarmTheme.textSecondary)

                // 问候语
                Text(greetingText)
                    .font(.custom("Avenir Next", size: 28))
                    .fontWeight(.bold)
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Spacer()

            // 统计信息
            if !store.todos.isEmpty {
                statsBadge
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(
            WarmTheme.background
                .shadow(color: WarmTheme.shadowLight, radius: 1, y: 1)
        )
        .offset(y: headerOffset)
        .opacity(headerOpacity)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "早安 ☀️"
        case 12..<14:
            return "中午好 🌤"
        case 14..<18:
            return "下午好 🌈"
        case 18..<22:
            return "晚上好 🌙"
        default:
            return "夜深了 💫"
        }
    }

    private var statsBadge: some View {
        let uncompleted = store.todos.filter { !$0.isCompleted }.count
        return HStack(spacing: 6) {
            Circle()
                .fill(WarmTheme.primary)
                .frame(width: 8, height: 8)

            Text("\(uncompleted)")
                .font(.custom("Avenir Next", size: 18))
                .fontWeight(.bold)
                .foregroundColor(WarmTheme.textPrimary)

            Text("项待办")
                .font(.custom("Avenir Next", size: 14))
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
        VStack(spacing: 20) {
            Spacer()

            if isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                    .scaleEffect(1.2)

                Text("正在整理中...")
                    .font(WarmFont.body(17))
                    .foregroundColor(WarmTheme.textSecondary)
            } else {
                // 录音波形指示
                HStack(spacing: 4) {
                    ForEach(Array(waveformHeights.enumerated()), id: \.offset) { i, h in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WarmTheme.primary)
                            .frame(width: 4, height: h)
                            .animation(
                                .easeInOut(duration: 0.4)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.1),
                                value: coordinator.isRecording
                            )
                    }
                }
                .frame(height: 32)

                Text("正在聆听...")
                    .font(WarmFont.headline(18))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            // 实时转写预览
            if !coordinator.transcript.isEmpty {
                Text(coordinator.transcript)
                    .font(WarmFont.body(15))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(WarmTheme.secondaryBackground)
                    )
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeOut(duration: 0.2), value: coordinator.transcript)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: - Todo List View

    private var uncompletedTodos: [TodoItemData] {
        store.todos.filter { !$0.isCompleted }
    }

    private var completedTodos: [TodoItemData] {
        store.todos.filter { $0.isCompleted }
    }

    private var todoListView: some View {
        List {
            // 未完成区域
            ForEach(Array(uncompletedTodos.enumerated()), id: \.element.id) { index, todo in
                todoRow(todo, index: index)
            }

            // 已完成区域
            if !completedTodos.isEmpty {
                Section {
                    ForEach(Array(completedTodos.enumerated()), id: \.element.id) { index, todo in
                        todoRow(todo, index: uncompletedTodos.count + index)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13))
                        Text("已完成 (\(completedTodos.count))")
                            .font(WarmFont.caption(13))
                    }
                    .foregroundColor(WarmTheme.textMuted)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 4, trailing: 20))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(WarmTheme.background)
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("TodoList")
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
                Label("删除", systemImage: "trash")
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(WarmTheme.primaryLight.opacity(0.3))
                    .frame(width: 140, height: 140)

                Circle()
                    .fill(WarmTheme.primaryLight.opacity(0.5))
                    .frame(width: 100, height: 100)

                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(WarmTheme.primary)
            }
            .scaleEffect(listOpacity == 0 ? 0.8 : 1.0)
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("今天还没有待办")
                    .font(WarmFont.headline(22))
                    .foregroundColor(WarmTheme.textPrimary)

                Text("按下 Action Button 或下方录音按钮\n说出你想做的事情")
                    .font(WarmFont.body(16))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .offset(y: listOffset)
            .opacity(listOpacity)

            Spacer()
        }
        .accessibilityIdentifier("EmptyState")
    }

    // MARK: - Recording Button

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

                Text(coordinator.isRecording ? "正在聆听..." : "开始录音")
                    .font(WarmFont.headline(17))
                    .foregroundColor(WarmTheme.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowMedium, radius: 12, x: 0, y: 6)
            )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRecording)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("RecordButton")
        .accessibilityLabel(coordinator.isRecording ? "停止录音" : "开始语音录入")
        .accessibilityHint(coordinator.isRecording ? "点击停止录音并开始整理待办" : "点击开始录音，说出你的待办事项")
    }

    // MARK: - Actions

    private func navigateToDeepLinkedTodo(id: UUID) {
        if let todo = store.todos.first(where: { $0.id == id }) {
            selectedTodo = todo
            coordinator.deepLinkTodoId = nil
            return
        }
        // 冷启动时 store 可能还未加载完成，延迟重试一次
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let todo = store.todos.first(where: { $0.id == id }) {
                selectedTodo = todo
            }
            coordinator.deepLinkTodoId = nil
        }
    }

    private func startEntranceAnimation() {
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

    // 分类颜色
    private var categoryColor: Color {
        switch todo.category {
        case .work: return Color(hex: "6B8FE8")
        case .study: return Color(hex: "9B7FE8")
        case .life: return Color(hex: "E8A87C")
        case .health: return Color(hex: "7BC47F")
        case .finance: return Color(hex: "E8C86B")
        case .social: return Color(hex: "E87C9B")
        case .other: return Color(hex: "9BA8B8")
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(
                            todo.isCompleted ? WarmTheme.success : categoryColor,
                            lineWidth: 2.5
                        )
                        .frame(width: 28, height: 28)

                    if todo.isCompleted {
                        Circle()
                            .fill(WarmTheme.success)
                            .frame(width: 28, height: 28)

                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TodoCheckbox_\(index)")
            .accessibilityLabel(todo.isCompleted ? "已完成" : "未完成")
            .accessibilityHint("点击\(todo.isCompleted ? "取消完成" : "标记为已完成")")

            // 内容
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(todo.category.emoji)
                        .font(.system(size: 16))

                    Text(todo.title)
                        .font(.custom("Avenir Next", size: 17))
                        .fontWeight(todo.priority == .high ? .semibold : .medium)
                        .foregroundColor(todo.isCompleted ? WarmTheme.textMuted : WarmTheme.textPrimary)
                        .strikethrough(todo.isCompleted, color: WarmTheme.textMuted)
                        .lineLimit(2)
                }

                // 时间标签
                if let dueHint = todo.dueHint, !todo.isCompleted {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(dueHint)
                            .font(.custom("Avenir Next", size: 13))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                }

            }

            Spacer()

            if todo.priority == .high && !todo.isCompleted {
                Text("!")
                    .font(WarmFont.body(14))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(WarmTheme.urgent)
                    )
                    .accessibilityIdentifier("PriorityLabel")
                    .accessibilityLabel("高优先级")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .accessibilityIdentifier("TodoCell_\(index)")
        .accessibilityValue(todo.isCompleted ? "已完成" : "未完成")
        .accessibilityHint("点击查看详情")
    }
}

// MARK: - Preview

