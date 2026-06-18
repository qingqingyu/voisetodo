import SwiftUI

/// 待办条目行视图
/// 用于 ConfirmSheetView 中显示单个待办
struct TodoItemRow: View {
    let index: Int
    @Binding var todo: ExtractedTodo
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @FocusState private var isTextFieldFocused: Bool

    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            Text(todo.categoryHint.emoji)
                .font(.system(size: 24))

            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                if isEditing {
                    TextField(String(localized: "confirm.todo_title_placeholder"), text: $editedTitle)
                        .font(WarmFont.headline(17))
                        .foregroundColor(WarmTheme.textPrimary)
                        .focused($isTextFieldFocused)
                        .accessibilityIdentifier("TodoTitle_\(index)")
                        .onSubmit { finishEditing() }
                        .onAppear { isTextFieldFocused = true }
                } else {
                    Text(todo.title)
                        .font(WarmFont.headline(17))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .accessibilityIdentifier("TodoTitleText_\(index)")
                }

                if let dueHint = todo.dueHint, !dueHint.isEmpty {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(dueHint)
                            .font(WarmFont.caption(13))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                }

                if let recurrenceRule = todo.recurrenceRule {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .semibold))
                        Text(recurrenceRule.displayText)
                            .font(WarmFont.caption(13))
                    }
                    .foregroundColor(WarmTheme.primaryDark)
                }
            }

            Spacer()

            if todo.priority == .high {
                Text(String(localized: "confirm.urgent"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(.white)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.chip)
                            .fill(WarmTheme.urgent)
                    )
                    .accessibilityIdentifier("PriorityLabel")
                    .accessibilityLabel(String(localized: "a11y.high_priority"))
            }

            Button(action: performDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(WarmTheme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("DeleteTodo_\(index)")
            .accessibilityLabel(String(localized: "a11y.delete"))
            .accessibilityHint(String(localized: "a11y.delete_todo"))
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card)
                .fill(WarmTheme.secondaryBackground)
        )
        .offset(x: offset)
        .opacity(opacity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("TodoRow_\(index)")
        .accessibilityHint(String(localized: "a11y.edit_todo_title"))
        .onTapGesture {
            if !isEditing { startEditing() }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused && isEditing {
                finishEditing()
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
        withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
            offset = 300
            opacity = 0
        }

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

        var body: some View {
            VStack(spacing: 12) {
                TodoItemRow(index: 0, todo: $todo1, onDelete: {})
                TodoItemRow(index: 1, todo: $todo2, onDelete: {})
            }
            .padding()
            .background(WarmTheme.background)
        }
    }

    return PreviewWrapper()
}
