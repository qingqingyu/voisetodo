import SwiftUI
import WidgetKit

/// 待办详情页
/// 支持查看和编辑待办标题
struct TodoDetailView: View {
    // MARK: - Properties

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: any TodoStoreProtocol
    let todo: TodoItemData

    // 编辑状态
    @State private var editedTitle: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueHint: String
    @State private var showSaveConfirmation = false
    @State private var hasChanges = false

    // MARK: - Initialization

    init(store: some TodoStoreProtocol, todo: TodoItemData) {
        self.store = store
        self.todo = todo
        _editedTitle = State(initialValue: todo.title)
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueHint = State(initialValue: todo.dueHint ?? "")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // 标题编辑
                Section(header: Text("标题")) {
                    TextField("待办标题", text: $editedTitle)
                        .font(.custom("Avenir Next", size: 17))
                        .onChange(of: editedTitle) { _, newValue in
                            checkForChanges()
                        }
                }

                // 分类选择
                Section(header: Text("分类")) {
                    Picker("分类", selection: $editedCategory) {
                        ForEach(TodoCategory.allCases, id: \.self) { category in
                            HStack {
                                Text(category.emoji)
                                Text(category.displayName)
                            }
                            .tag(category)
                        }
                    }
                    .onChange(of: editedCategory) { _, _ in
                        checkForChanges()
                    }
                }

                // 优先级选择
                Section(header: Text("优先级")) {
                    Picker("优先级", selection: $editedPriority) {
                        Text("普通").tag(Priority.normal)
                        Text("高优先级").tag(Priority.high)
                    }
                    .onChange(of: editedPriority) { _, _ in
                        checkForChanges()
                    }
                }

                // 时间提示
                Section(header: Text("时间提示")) {
                    TextField("例如：明天、周三前", text: $editedDueHint)
                        .font(.custom("Avenir Next", size: 17))
                        .onChange(of: editedDueHint) { _, _ in
                            checkForChanges()
                        }
                }

                // 元信息
                Section(header: Text("信息")) {
                    HStack {
                        Text("创建时间")
                        Spacer()
                        Text(formatDate(todo.createdAt))
                            .foregroundColor(WarmTheme.textSecondary)
                    }

                    if todo.needsAIProcessing {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("待 AI 整理")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle("待办详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(!hasChanges || editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .alert("已保存", isPresented: $showSaveConfirmation) {
                Button("好的") {
                    dismiss()
                }
            } message: {
                Text("待办已更新")
            }
        }
    }

    // MARK: - Private Methods

    /// 检查是否有变更
    private func checkForChanges() {
        hasChanges = editedTitle != todo.title ||
                     editedCategory != todo.category ||
                     editedPriority != todo.priority ||
                     editedDueHint != (todo.dueHint ?? "")
    }

    /// 保存变更
    private func saveChanges() {
        do {
            // 更新标题（通过 TodoStore 的 update 方法）
            if editedTitle != todo.title {
                try store.update(todo.id, title: editedTitle)
            }

            // TODO: 如果需要更新其他字段，需要扩展 TodoStore
            // 目前只支持更新标题

            // 刷新 Widget
            WidgetCenter.shared.reloadAllTimelines()

            showSaveConfirmation = true
        } catch {
            print("Failed to save changes: \(error)")
        }
    }

    /// 格式化日期
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @StateObject var store = MockStore.preview

        var body: some View {
            TodoDetailView(store: store, todo: store.todos[0])
        }
    }

    return PreviewWrapper()
}
