import SwiftUI

/// 确认弹窗视图 - 温暖友好风格
/// 语音录入后的确认面板， 显示 AI 提取的待办列表
struct ConfirmSheetView: View {
    let transcript: String
    @Binding var todos: [ExtractedTodo]
    let isStreaming: Bool
    let onConfirm: ([ExtractedTodo]) -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 成功动画覆盖层
                if showSuccess {
                    successOverlay
                } else {
                    mainContent
                }
            }
            .navigationTitle(String(localized: "confirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "confirm.cancel")) {
                        onCancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("CancelButton")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        Text(String(localized: "confirm.add \(todos.count)"))
                            .bold()
                    }
                    .disabled(todos.isEmpty || isStreaming)
                    .accessibilityIdentifier("ConfirmAddButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConfirmSheet")
        .task(id: showSuccess) {
            guard showSuccess else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                transcriptSection

                if !todos.isEmpty {
                    operationHint

                    todosSection
                }
            }
            .padding()
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "confirm.transcript"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)

            Text(transcript)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WarmTheme.secondaryBackground)
                )
                .accessibilityIdentifier("TranscriptArea")
        }
    }

    // MARK: - Todos Section

    private var todosSection: some View {
        VStack(spacing: 12) {
            ForEach(Array($todos.enumerated()), id: \.element.id) { index, $todo in
                TodoItemRowWithDelete(
                    index: index,
                    todo: $todo,
                    todos: $todos
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isStreaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                        .scaleEffect(0.8)
                    Text(String(localized: "confirm.streaming"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                }
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: todos.count)
        .accessibilityIdentifier("ExtractedTodoList")
    }

    // MARK: - Operation Hint

    private var operationHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
                .font(.system(size: 12))
            Text(String(localized: "confirm.hint"))
                .font(WarmFont.caption(13))
        }
        .foregroundColor(WarmTheme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(WarmTheme.secondaryBackground)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Success Overlay

    private var successOverlay: some View {
        VStack(spacing: 16) {
            Spacer()

            // 成功图标
            ZStack {
                Circle()
                    .fill(WarmTheme.success)
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccess ? 1.0 : 0.5)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showSuccess)

            // 成功文字
            Text(ErrorMessages.addedSuccess)
                .font(WarmFont.headline(18))
                .foregroundColor(WarmTheme.textPrimary)
                .opacity(showSuccess ? 1.0 : 0.0)
                .animation(.easeIn(duration: 0.2).delay(0.2), value: showSuccess)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WarmTheme.background)
        .accessibilityIdentifier("SuccessAnimation")
    }

    // MARK: - Actions

    private func confirmAction() {
        guard !todos.isEmpty else { return }

        let success = onConfirm(todos)

        if success {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                showSuccess = true
            }
        }
        // 失败时不 dismiss：保留编辑上下文；Coordinator 已通过 Toast 等方式反馈错误。
    }
}

// MARK: - Helper View

/// 辅助视图：处理待办删除逻辑
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
