import SwiftUI

/// 批量确认视图（用于网络恢复后的补处理）
struct BatchConfirmView: View {
    @Binding var todos: [ExtractedTodo]
    let onConfirm: ([ExtractedTodo]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach($todos) { $todo in
                    BatchTodoItemRow(
                        todo: $todo,
                        todos: $todos
                    )
                }
            }
            .navigationTitle("已整理的待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("跳过") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("全部添加") {
                        onConfirm(todos)
                        dismiss()
                    }
                    .disabled(todos.isEmpty)
                }
            }
        }
    }
}

/// 辅助视图：批量确认中的待办行（使用 ID 删除，避免索引问题）
private struct BatchTodoItemRow: View {
    @Binding var todo: ExtractedTodo
    @Binding var todos: [ExtractedTodo]

    var body: some View {
        TodoItemRow(
            todo: $todo,
            onDelete: {
                withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                    todos.removeAll { $0.id == todo.id }
                }
            }
        )
    }
}
