import SwiftUI

/// 确认弹窗视图 - 温暖友好风格
/// 语音录入后的确认面板， 显示 AI 提取的待办列表
struct ConfirmSheetView: View {
    let transcript: String
    @Binding var todos: [ExtractedTodo]
    let onConfirm: ([ExtractedTodo]) -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    // 成功状态
    @State private var showSuccess = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 成功动画覆盖层
                if showSuccess {
                    successOverlay
                } else {
                    mainContent
                }
            }
            .navigationTitle("确认待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("CancelButton")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        Text("确认添加 (\(todos.count))")
                            .bold()
                    }
                    .disabled(todos.isEmpty)
                    .accessibilityIdentifier("ConfirmAddButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConfirmSheet")
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 语音原文区
                transcriptSection

                // 提取结果列表
                if !todos.isEmpty {
                    todosSection
                }

                // 操作提示
                if !todos.isEmpty {
                    operationHint
                }
            }
            .padding()
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语音原文")
                .font(.custom("Avenir Next", size: 13))
                .fontWeight(.medium)
                .foregroundColor(WarmTheme.textSecondary)

            Text(transcript)
                .font(.custom("Avenir Next", size: 14))
                .foregroundColor(WarmTheme.textSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemGroupedBackground))
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
            }
        }
        .accessibilityIdentifier("ExtractedTodoList")
    }

    // MARK: - Operation Hint

    private var operationHint: some View {
        Text("点击条目可编辑 · 点 ✕ 可删除")
            .font(.custom("Avenir Next", size: 13))
            .foregroundColor(WarmTheme.textSecondary)
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
                .font(.custom("Avenir Next", size: 18))
                .fontWeight(.semibold)
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

        // 执行存储操作，根据结果决定是否显示成功动画
        let success = onConfirm(todos)

        if success {
            // 存储成功，显示成功动画
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                showSuccess = true
            }

            // 1.5 秒后自动关闭（使用 Task 支持 Cancel）
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
            }
        }
        // 存储失败时 onConfirm 内部已显示 toast，保持 sheet 不关闭让用户可重试
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
