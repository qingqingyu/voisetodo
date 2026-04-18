import SwiftUI
import WidgetKit

private let todoDetailDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter
}()

/// 待办详情页
/// 支持查看和编辑待办标题
struct TodoDetailView<Store: TodoStoreProtocol>: View {
    // MARK: - Properties

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: Store
    let todo: TodoItemData

    // 编辑状态
    @State private var editedTitle: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueHint: String
    @State private var showSaveConfirmation = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var hasChanges = false

    // MARK: - Initialization

    init(store: Store, todo: TodoItemData) {
        self.store = store
        self.todo = todo
        _editedTitle = State(initialValue: todo.title)
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueHint = State(initialValue: todo.dueHint ?? "")
    }

    // MARK: - Body

    var body: some View {
        Form {
            // 标题编辑
            Section(header: Text("标题")) {
                TextField("待办标题", text: $editedTitle)
                    .font(.custom("Avenir Next", size: 17))
                    .onChange(of: editedTitle) { _, _ in
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
        .alert("提示", isPresented: $showError) {
            Button("好的") {}
        } message: {
            Text(errorMessage)
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
            let newCategory = editedCategory != todo.category ? editedCategory : nil
            let newPriority = editedPriority != todo.priority ? editedPriority : nil
            let newDueHint: String? = editedDueHint != (todo.dueHint ?? "") ? editedDueHint : nil

            try store.update(
                todo.id,
                title: editedTitle,
                category: newCategory,
                priority: newPriority,
                dueHint: newDueHint
            )

            // 刷新 Widget
            WidgetCenter.shared.reloadAllTimelines()

            showSaveConfirmation = true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            showError = true
        }
    }

    private func formatDate(_ date: Date) -> String {
        todoDetailDateFormatter.string(from: date)
    }
}

