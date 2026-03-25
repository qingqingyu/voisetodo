import SwiftUI

// MARK: - 温暖配色主题

enum WarmTheme {
    // 主色调 - 温暖的珊瑚橙
    static let primary = Color(hex: "FF8A6B")
    static let primaryLight = Color(hex: "FFB5A0")
    static let primaryDark = Color(hex: "E56B4F")

    // 背景色 - 奶油白
    static let background = Color(hex: "FFFBF7")
    static let cardBackground = Color(hex: "FFFFFF")
    static let secondaryBackground = Color(hex: "FFF5EE")

    // 手绘风格 - 纸张色
    static let paperBackground = Color(hex: "FFF8F0")

    // 文字色
    static let textPrimary = Color(hex: "3D3A38")
    static let textSecondary = Color(hex: "8B8580")
    static let textMuted = Color(hex: "B8B3AD")

    // 手绘风格 - 墨水色
    static let ink = Color(hex: "4A4543")
    static let sketch = Color(hex: "6B6560")

    // 状态色
    static let success = Color(hex: "7BC47F")
    static let urgent = Color(hex: "FF6B6B")
    static let warning = Color(hex: "FFB347")

    // 阴影
    static let shadowLight = Color(hex: "3D3A38").opacity(0.08)
    static let shadowMedium = Color(hex: "3D3A38").opacity(0.12)
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - HomeView

/// 主页视图 - 温暖友好风格
/// 显示待办列表，支持勾选完成、左滑删除
struct HomeView<Store: TodoStoreProtocol>: View {
    @ObservedObject var store: Store
    @State private var showRecordingButton = false
    @State private var isRecording = false

    // 动画状态
    @State private var headerOffset: CGFloat = -50
    @State private var headerOpacity: Double = 0
    @State private var listOffset: CGFloat = 30
    @State private var listOpacity: Double = 0

    // 日期格式化
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    var body: some View {
        ZStack {
            // 背景
            WarmTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 自定义导航栏
                headerView

                // 主内容
                Group {
                    if store.todos.isEmpty {
                        emptyStateView
                    } else {
                        todoListView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            startEntranceAnimation()
        }
        .overlay(alignment: .bottom) {
            if showRecordingButton {
                recordingButton
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                // 日期
                Text(dateFormatter.string(from: Date()))
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

    // MARK: - Todo List View

    private var todoListView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(store.todos) { todo in
                    WarmTodoCard(
                        todo: todo,
                        onToggle: { toggleTodo(todo.id) },
                        onDelete: { deleteTodo(todo.id) }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .refreshable {
            // 下拉刷新动画
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            // 插画
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

            VStack(spacing: 12) {
                Text("今天还没有待办")
                    .font(.custom("Avenir Next", size: 22))
                    .fontWeight(.semibold)
                    .foregroundColor(WarmTheme.textPrimary)

                Text("按下下方的录音按钮\n说出你想做的事情")
                    .font(.custom("Avenir Next", size: 16))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .offset(y: listOffset)
            .opacity(listOpacity)

            Spacer()
        }
    }

    // MARK: - Recording Button

    private var recordingButton: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 10) {
                // 麦克风图标
                ZStack {
                    if isRecording {
                        // 录音动画
                        Circle()
                            .stroke(WarmTheme.primary.opacity(0.3), lineWidth: 3)
                            .frame(width: 44, height: 44)
                            .scaleEffect(isRecording ? 1.3 : 1.0)
                            .animation(
                                Animation.easeInOut(duration: 0.8)
                                    .repeatForever(autoreverses: true),
                                value: isRecording
                            )
                    }

                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isRecording ? WarmTheme.urgent : WarmTheme.primary)
                        )
                }

                Text(isRecording ? "正在聆听..." : "开始录音")
                    .font(.custom("Avenir Next", size: 17))
                    .fontWeight(.semibold)
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
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func startEntranceAnimation() {
        // 延迟显示录音按钮
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                showRecordingButton = true
            }
        }

        // Header 入场动画
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
            headerOffset = 0
            headerOpacity = 1
        }

        // 列表入场动画
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.25)) {
            listOffset = 0
            listOpacity = 1
        }
    }

    private func toggleRecording() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isRecording.toggle()
        }

        if isRecording {
            // TODO: Agent E 会实现录音触发逻辑
            print("Start recording")
        } else {
            print("Stop recording")
        }
    }

    private func toggleTodo(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            try? store.toggleComplete(id)
        }
    }

    private func deleteTodo(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            try? store.delete(id)
        }
    }
}

// MARK: - Warm Todo Card

struct WarmTodoCard: View {
    let todo: TodoItemData
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isSwiping = false

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
            // 完成按钮
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

            // 优先级标签
            if todo.priority == .high && !todo.isCompleted {
                Text("!")
                    .font(.custom("Avenir Next", size: 14))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(WarmTheme.urgent)
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
        )
        .offset(x: offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.width < 0 {
                        isSwiping = true
                        offset = value.translation.width
                    }
                }
                .onEnded { value in
                    if value.translation.width < -100 {
                        // 删除
                        onDelete()
                    } else {
                        // 弹回
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            offset = 0
                        }
                    }
                    isSwiping = false
                }
        )
    }
}

// MARK: - Preview

#Preview {
    // Mock Store for Preview
    class MockStore: TodoStoreProtocol, ObservableObject {
        @Published var todos: [TodoItemData] = [
            TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
            TodoItemData(title: "准备面试材料", dueHint: "周三前", priority: .high, category: .work),
            TodoItemData(title: "去健身房", dueHint: nil, priority: .normal, category: .health, isCompleted: true),
            TodoItemData(title: "给妈妈打电话", dueHint: "晚上", priority: .normal, category: .social),
            TodoItemData(title: "学习 SwiftUI", dueHint: nil, priority: .normal, category: .study)
        ]

        func add(_ item: ExtractedTodo) throws {}
        func addBatch(_ items: [ExtractedTodo]) throws {}
        func addRawTranscript(_ transcript: String) throws {}
        func toggleComplete(_ id: UUID) throws {
            if let index = todos.firstIndex(where: { $0.id == id }) {
                todos[index].isCompleted.toggle()
            }
        }
        func delete(_ id: UUID) throws {
            todos.removeAll { $0.id == id }
        }
        func update(_ id: UUID, title: String) throws {}
        func pendingItems() -> [TodoItemData] { return [] }
        func recentUncompleted(limit: Int) -> [TodoItemData] {
            return todos.filter { !$0.isCompleted }.prefix(limit).map { $0 }
        }
        func replacePendingWithExtracted(_ pendingId: UUID, _ items: [ExtractedTodo]) throws {}
    }

    return HomeView(store: MockStore())
}
