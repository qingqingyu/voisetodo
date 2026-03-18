import SwiftUI

/// 主页视图（Agent D 实现）
/// 显示待办列表，支持勾选完成、左滑删除
struct HomeView<Store: TodoStoreProtocol>: View {
    @ObservedObject var store: Store
    @State private var showRecordingButton = false

    var body: some View {
        NavigationView {
            Group {
                if store.todos.isEmpty {
                    // 空状态 [v2]
                    EmptyStateView.homeEmpty()
                } else {
                    // 待办列表
                    todoList
                }
            }
            .navigationTitle("VoiceTodo")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !store.todos.isEmpty {
                        statsView
                    }
                }
            }
        }
        .onAppear {
            // 延迟显示录音按钮，避免视觉跳跃
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showRecordingButton = true
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showRecordingButton {
                recordingButton
            }
        }
    }

    // MARK: - Todo List

    private var todoList: some View {
        List {
            ForEach(store.todos) { todo in
                TodoRowView(todo: todo) {
                    toggleTodo(todo.id)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    deleteButton(for: todo.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // 下拉刷新（未来可添加同步功能）
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Stats View

    private var statsView: some View {
        let uncompleted = store.todos.filter { !$0.isCompleted }.count
        return Text("\(uncompleted) 项待办")
            .font(.system(size: 14))
            .foregroundColor(.secondary)
    }

    // MARK: - Recording Button

    private var recordingButton: some View {
        Button(action: {
            // Agent E 会实现录音触发逻辑
            print("Start recording")
        }) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                Text("开始录音")
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            )
        }
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Delete Button

    private func deleteButton(for id: UUID) -> some View {
        Button(role: .destructive) {
            withAnimation(.easeOut(duration: 0.3)) {
                try? store.delete(id)
            }
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func toggleTodo(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            try? store.toggleComplete(id)
        }
    }
}

// MARK: - Todo Row View

struct TodoRowView: View {
    let todo: TodoItemData
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 完成按钮
            Button(action: onToggle) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(todo.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // 内容
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(todo.category.emoji)
                        .font(.system(size: 16))

                    Text(todo.title)
                        .font(.system(size: 17, weight: todo.priority == .high ? .semibold : .regular))
                        .foregroundColor(todo.isCompleted ? .secondary : .primary)
                        .strikethrough(todo.isCompleted)
                        .lineLimit(2)
                }

                // 时间标签
                if let dueHint = todo.dueHint, !todo.isCompleted {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(dueHint)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 优先级标签
            if todo.priority == .high && !todo.isCompleted {
                Text("紧急")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    // Mock Store for Preview
    class MockStore: TodoStoreProtocol {
        @Published var todos: [TodoItemData] = [
            TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
            TodoItemData(title: "准备面试", dueHint: "周三前", priority: .high, category: .work),
            TodoItemData(title: "去健身房", dueHint: nil, priority: .normal, category: .health, isCompleted: true)
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
