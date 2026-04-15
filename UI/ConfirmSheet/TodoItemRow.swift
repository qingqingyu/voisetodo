import SwiftUI

/// 待办条目行视图（Agent D 实现）
/// 用于 ConfirmSheetView 中显示单个待办
struct TodoItemRow: View {
    @Binding var todo: ExtractedTodo
    let onDelete: () -> Void

    // 编辑状态
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @FocusState private var isTextFieldFocused: Bool

    // 删除动画
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 12) {
            // 分类 emoji
            Text(todo.categoryHint.emoji)
                .font(.system(size: 24))

            // 标题和详情
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("待办标题", text: $editedTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            finishEditing()
                        }
                        .onAppear {
                            isTextFieldFocused = true
                        }
                } else {
                    Text(todo.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                // 时间标签
                if let dueHint = todo.dueHint, !dueHint.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(dueHint)
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 优先级标签
            if todo.priority == .high {
                Text("紧急")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red)
                    .cornerRadius(6)
            }

            // 删除按钮
            Button(action: performDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .offset(x: offset)
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                startEditing()
            }
        }
    }

    // MARK: - Actions

    private func startEditing() {
        editedTitle = todo.title
        isEditing = true
    }

    private func finishEditing() {
        if !editedTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            todo.title = editedTitle.trimmingCharacters(in: .whitespaces)
        }
        isEditing = false
        isTextFieldFocused = false
    }

    private func performDelete() {
        // 向右滑出动画
        withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
            offset = 300
            opacity = 0
        }

        // 动画完成后执行删除
        Task {
            try? await Task.sleep(nanoseconds: UInt64(UIConfig.deleteAnimationDuration * 1_000_000_000))
            onDelete()
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var todo1 = ExtractedTodo(
            title: "完成周报",
            detail: "",
            dueHint: "今天",
            priority: .normal,
            categoryHint: .work
        )
        @State var todo2 = ExtractedTodo(
            title: "准备面试",
            detail: "",
            dueHint: "周三前",
            priority: .high,
            categoryHint: .work
        )
        @State var todo3 = ExtractedTodo(
            title: "去健身房",
            detail: "",
            dueHint: nil,
            priority: .normal,
            categoryHint: .health
        )

        var body: some View {
            VStack(spacing: 12) {
                TodoItemRow(todo: $todo1, onDelete: {})
                TodoItemRow(todo: $todo2, onDelete: {})
                TodoItemRow(todo: $todo3, onDelete: {})
            }
            .padding()
            .background(Color(.systemGroupedBackground))
        }
    }

    return PreviewWrapper()
}
