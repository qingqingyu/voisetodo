import SwiftUI

/// 「没能识别」卡片的转写原文编辑 sheet。
///
/// 保存语义(2026-10 用户决策):编辑后文本**先落库**再立即自动重解析——
/// 编辑的动机大概率是修正语音识别错字后让 AI 解析成功。
/// 永不丢话契约:取消不写库;保存(无论解析成败)编辑后文本已在库中。
///
/// 保存按钮行为:
/// - trim 后为空 → 禁用(硬规则)
/// - 文本未变 → 仅关闭,不触发解析(省一次模型调用;要重试有「重新解析」按钮)
/// - 文本有变化 → `onSave(原文本)`,dismiss 由调用方(HomeView)闭包负责
///   (先收键盘再启动解析,卡片随即进入 reextracting 态)
struct UnparsedTranscriptEditSheet: View {
    let todo: TodoItemData
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftText: String

    private var originalText: String { todo.rawTranscript ?? todo.title }
    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmedDraft.isEmpty }

    init(todo: TodoItemData, onSave: @escaping (String) -> Void) {
        self.todo = todo
        self.onSave = onSave
        _draftText = State(initialValue: todo.rawTranscript ?? todo.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                Text(String(localized: "home.unparsed.edit.title"))
                    .font(WarmFont.headline(18))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(String(localized: "home.unparsed.edit.hint"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FocusableTextView(
                text: $draftText,
                fontSize: 15,
                accessibilityIdentifier: "UnparsedEditEditor"
            )
            .frame(minHeight: 140)
            .padding(WarmSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.chip)
                    .fill(WarmTheme.sketch.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WarmRadius.chip)
                    .stroke(
                        WarmTheme.sketch,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )

            HStack(spacing: WarmSpacing.sm) {
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "common.cancel"))
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, WarmSpacing.md)
                        .padding(.vertical, WarmSpacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.sketch.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("UnparsedEditCancel")

                Spacer()

                Button {
                    // 未变:仅关闭,不触发解析(省模型调用;重试走「重新解析」按钮)
                    guard trimmedDraft != originalText else {
                        dismiss()
                        return
                    }
                    onSave(draftText)
                } label: {
                    Text(String(localized: "home.unparsed.edit.save"))
                        .font(WarmFont.body(15))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, WarmSpacing.md)
                        .padding(.vertical, WarmSpacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.primary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
                .accessibilityIdentifier("UnparsedEditSave")
            }
        }
        .padding(WarmSpacing.lg)
        // 不在根上挂 accessibilityIdentifier:容器级 identifier 会污染整个子树
        // (见 UnparsedTodoCard 的 UnparsedCard_ 前缀污染),内部元素靠各自 identifier 查询。
    }
}
