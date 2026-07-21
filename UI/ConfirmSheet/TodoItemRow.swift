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
    /// 删除动画的 unstructured task 句柄。视图销毁 / 重复点击时必须 cancel,
    /// 否则 sleep 结束后仍会调 onDelete()——闭包捕获的 @Binding todo 可能已失效。
    /// 用 `Task<Void, Error>` 而非 `Never`:Task.sleep 闭包 throwing(只 throw
    /// CancellationError),Failure=Never 编译失败。
    @State private var deleteTask: Task<Void, Error>?
    /// 删除动画的 generation 计数。每次 performDelete 递增,catch 块用它判断
    /// 「自己是否还是最新 task」。
    /// **为什么不用 `Task === task`**:`Task` 是 struct,Swift 不允许 struct 用
    /// `===` 比较句柄;`Task` 也没有公开的 `id` 属性。改用整数 generation 计数,
    /// 捕获时拷贝当前值,catch 时跟 @State 当前值比较。
    @State private var deleteTaskGeneration: Int = 0

    /// 合并所有时间相关字段成一个用户可读的字符串。
    /// 拼装规则抽到了 `TodoTimeDisplayComposer`（与 HomeView WarmTodoCard 共用），
    /// 这里只负责"从 ExtractedTodo 取出 AI 给的 dueTime 字符串"作为钟点源。
    ///
    /// 冗余权衡（review 决策，详见 TodoTimeDisplayComposer 文档）：
    /// 当结构化字段存在时丢弃 dueHint 原文，避免冗余串。
    private var composedTimeText: String? {
        TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: todo.dueTime,
            dueHint: todo.dueHint,
            timeBucketText: todo.timeBucket?.localizedTitle
        )
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

                if todo.dueTime == nil {
                    Menu {
                        ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                            Button {
                                todo.timeBucket = bucket == .anytime ? nil : bucket
                            } label: {
                                if todo.timeBucket == bucket || (todo.timeBucket == nil && bucket == .anytime) {
                                    Label(bucket.localizedTitle, systemImage: "checkmark")
                                } else {
                                    Text(bucket.localizedTitle)
                                }
                            }
                        }
                    } label: {
                        Label(
                            (todo.timeBucket ?? .anytime).localizedTitle,
                            systemImage: "sun.max"
                        )
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.primaryDark)
                    }
                    .accessibilityIdentifier("TodoTimeBucketPicker_\(index)")
                    .accessibilityLabel(String(localized: "time_bucket.accessibility_label"))
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
        .onDisappear {
            deleteTask?.cancel()
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
        // 重复点击或动画途中再次触发:cancel 旧 task(旧 task 的 catch 会判断
        // "自己是否还是 deleteTask 最新值",是才复位视觉状态,避免与新 task 的
        // 动画打架),再起新 task。保持删除动画可打断 + 不累积多个 onDelete 调用。
        deleteTask?.cancel()
        deleteTaskGeneration += 1
        let generation = deleteTaskGeneration
        let task = Task { @MainActor in
            withAnimation(WarmAnimation.springFast) {
                offset = 300
                opacity = 0
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(UIConfig.deleteAnimationDuration * 1_000_000_000))
            } catch is CancellationError {
                // 不静默吞(违反 CLAUDE.md 错误显式传播),显式 catch CancellationError。
                // 仅当当前 generation 仍是最新值(即视图未销毁且未被新 performDelete
                // 覆盖)时才复位视觉状态:若已被新 task 覆盖,让新 task 的 withAnimation 独占,
                // 避免连击时旧 task 的复位与新 task 的位移动画互相打架。
                guard deleteTaskGeneration == generation else { return }
                withAnimation(WarmAnimation.springFast) {
                    offset = 0
                    opacity = 1
                }
                return
            }
            // 双重 guard:await 后视图可能已销毁(虽然 onDisappear cancel 了 task,
            // 但 cancel 信号送达有窗口),用 Task.isCancelled 兜底防止调用已失效闭包。
            guard !Task.isCancelled else { return }
            onDelete()
        }
        deleteTask = task
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
