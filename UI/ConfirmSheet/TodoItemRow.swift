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

    /// 合并所有时间相关字段成一个用户可读的字符串。
    /// 优先级：结构化字段(recurrence + end_date + dueTime) > dueHint > 空（返回 nil 不渲染）。
    /// 这是 P3 修复核心——之前 dueHint + recurrence 分两行且 dueTime 丢失，
    /// 用户看到"未来一个月 · 每天"但"15:00"和"至 8月5日"都丢了。
    ///
    /// 冗余权衡（review 决策）：当结构化字段存在时丢弃 dueHint 原文。
    /// 理由：AI 通常会把同样的时间信息同时写进 dueHint 和结构化字段，
    ///   若再拼上 dueHint 会产生 "每天 · 至 8月5日 · 15:00 · 每天下午3点至8月5日" 这样的冗余串。
    /// 已知代价：dueHint 里偶尔会带结构化字段无法表达的非时间信息（例如"在会议室"），
    ///   这类信息应在 prompt 工程或 detail 字段里解决，而不是在 UI 层用脆弱的字符串去重。
    private var composedTimeText: String? {
        var parts: [String] = []
        if let rule = todo.recurrenceRule {
            parts.append(rule.displayTextWithEndDate)
        }
        if let dueTime = todo.dueTime, !dueTime.isEmpty {
            parts.append(dueTime)
        }
        if parts.isEmpty {
            // 没有结构化字段时退回 dueHint 原文（AI 自由文本，例如"明天下午3点"）。
            if let dueHint = todo.dueHint, !dueHint.isEmpty {
                return dueHint
            }
            return nil
        }
        return parts.joined(separator: " · ")
    }

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

                // 时间行：优先用结构化字段（recurrence + dueTime + end_date）合并成一行，
                // 让用户校对时一眼看到"每天 15:00 · 至 8月5日"而不是模糊的"未来一个月"。
                // 结构化字段全空时退回 dueHint 原文。
                if let timeText = composedTimeText {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(timeText)
                            .font(WarmFont.caption(13))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                    .accessibilityIdentifier("TodoTimeText_\(index)")
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
