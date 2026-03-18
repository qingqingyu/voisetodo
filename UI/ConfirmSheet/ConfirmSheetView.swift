import SwiftUI
import WidgetKit

/// 确认弹窗视图（Agent D 实现）
/// 语音录入后的确认面板，显示 AI 提取的待办列表
struct ConfirmSheetView: View {
    let transcript: String
    @Binding var todos: [ExtractedTodo]
    let onConfirm: ([ExtractedTodo]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    // 成功状态
    @State private var showSuccess = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 成功动画覆盖层 [v2]
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
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: confirmAction) {
                        Text("确认添加 (\(todos.count))")
                            .bold()
                    }
                    .disabled(todos.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Text(transcript)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
        }
    }

    // MARK: - Todos Section

    private var todosSection: some View {
        VStack(spacing: 12) {
            ForEach(Array(todos.enumerated()), id: \.element.id) { index, _ in
                TodoItemRow(
                    todo: $todos[index],
                    onDelete: {
                        withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                            todos.remove(at: index)
                        }
                    }
                )
            }
        }
    }

    // MARK: - Operation Hint

    private var operationHint: some View {
        Text("点击条目可编辑 · 点 ✕ 可删除")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Success Overlay [v2]

    private var successOverlay: some View {
        VStack(spacing: 16) {
            Spacer()

            // 成功图标
            ZStack {
                Circle()
                    .fill(Color(red: 0.067, green: 0.725, blue: 0.506)) // #10B981
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccess ? 1.0 : 0.5)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showSuccess)

            // 成功文字
            Text(ErrorMessages.addedSuccess)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .opacity(showSuccess ? 1.0 : 0.0)
                .animation(.easeIn(duration: 0.2).delay(0.2), value: showSuccess)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func confirmAction() {
        guard !todos.isEmpty else { return }

        // 显示成功动画
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            showSuccess = true
        }

        // 调用确认回调
        onConfirm(todos)

        // 刷新 Widget
        WidgetCenter.shared.reloadAllTimelines()

        // 1.5 秒后自动关闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var todos = [
            ExtractedTodo(title: "完成周报", detail: "", dueHint: "今天", priority: .normal, categoryHint: .work),
            ExtractedTodo(title: "准备面试", detail: "", dueHint: "周三前", priority: .high, categoryHint: .work),
            ExtractedTodo(title: "去健身房", detail: "", dueHint: nil, priority: .normal, categoryHint: .health)
        ]

        var body: some View {
            ConfirmSheetView(
                transcript: "明天去银行办卡，顺便买菜，晚上给老妈打电话",
                todos: $todos,
                onConfirm: { _ in print("Confirmed") },
                onCancel: { print("Cancelled") }
            )
        }
    }

    return PreviewWrapper()
}
