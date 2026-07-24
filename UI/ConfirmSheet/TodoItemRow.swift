import SwiftUI

/// 待办条目行视图。
/// 用于 ConfirmSheetView 中显示单个待办。
///
/// 重设计(2026-07):对齐 jul-redesign.html 参考。
/// - 左侧 4pt 分类色条(对齐 HTML .item::before)
/// - 时间字段改胶囊底色,颜色与色条同系(对齐 HTML .time)
/// - emoji 入场缩放动画(对齐 HTML .emoji bump)
/// - 删除按钮 28×28 圆形灰底(对齐 HTML .del)
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

    /// 卡片内的时间串:不传 relativeDateText(分组标题已带日期,避免冗余),
    /// 让 composer 只拼「钟点 / 模糊时段 / dueHint 兜底」。
    private var composedTimeText: String? {
        TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: todo.dueTime,
            dueHint: todo.dueHint,
            timeBucketText: todo.timeBucket?.localizedTitle
        )
    }

    private var categoryColor: Color {
        WarmTheme.color(for: todo.categoryHint)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧分类色条:4pt 宽,圆角小条,对齐 HTML .item::before
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor)
                .frame(width: 4)
                .padding(.vertical, 4)

            HStack(alignment: .center, spacing: WarmSpacing.sm) {
                Text(todo.categoryHint.emoji)
                    .font(.system(size: 22))
                    .id(todo.id)
                    .modifier(EmojiBumpModifier())
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    if isEditing {
                        TextField(String(localized: "confirm.todo_title_placeholder"), text: $editedTitle)
                            .font(WarmFont.headline(16))
                            .foregroundColor(WarmTheme.textPrimary)
                            .focused($isTextFieldFocused)
                            .accessibilityIdentifier("TodoTitle_\(index)")
                            .onSubmit { finishEditing() }
                            .onAppear { isTextFieldFocused = true }
                    } else {
                        Text(todo.title)
                            .font(WarmFont.headline(16))
                            .foregroundColor(WarmTheme.textPrimary)
                            // 主内容不允许截断:用户在校对 AI 提取的内容,看全是关键。
                            // 长标题靠自然换行承接,sheet 内容可滚动。
                            .accessibilityIdentifier("TodoTitleText_\(index)")
                    }

                    // 时间行:钟点 / 模糊时段 / dueHint 兜底。
                    // 拼装逻辑抽到 TodoTimeDisplayComposer,这里只渲染。
                    if let timeText = composedTimeText {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(timeText)
                                .font(WarmFont.caption(12))
                        }
                        .foregroundColor(categoryColor)
                        .padding(.horizontal, WarmSpacing.xs)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(WarmTheme.categoryBackground(for: todo.categoryHint))
                        )
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

                Spacer(minLength: WarmSpacing.xs)

                if todo.priority == .high {
                    Text(String(localized: "confirm.urgent"))
                        .font(WarmFont.caption(11))
                        .foregroundColor(.white)
                        .padding(.horizontal, WarmSpacing.xs)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.urgent)
                        )
                        .accessibilityIdentifier("PriorityLabel")
                        .accessibilityLabel(String(localized: "a11y.high_priority"))
                }

                Button(action: performDelete) {
                    ZStack {
                        Circle()
                            .fill(WarmTheme.subtleControlBackground)
                            .frame(width: 28, height: 28)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DeleteTodo_\(index)")
                .accessibilityLabel(String(localized: "a11y.delete"))
                .accessibilityHint(String(localized: "a11y.delete_todo"))
            }
            .padding(.leading, WarmSpacing.xs)
            .padding(.trailing, WarmSpacing.md)
            .padding(.vertical, WarmSpacing.sm)
        }
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 2, y: 1)
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

// MARK: - Helper:Delete Wrapper

/// 辅助视图:处理待办删除逻辑。从原 ConfirmSheetView.swift 移入,
/// 让删除逻辑与 row 视图同文件管理。
struct TodoItemRowWithDelete: View {
    let index: Int
    @Binding var todo: ExtractedTodo
    @Binding var todos: [ExtractedTodo]

    var body: some View {
        TodoItemRow(
            index: index,
            todo: $todo,
            onDelete: {
                withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                    todos.removeAll { $0.id == todo.id }
                }
            }
        )
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
