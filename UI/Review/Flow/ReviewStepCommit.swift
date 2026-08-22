import SwiftUI

/// 第 4 步 · 下周三件事(阶段 3)。
///
/// 从「排进下周的」里挑**最多 3 件**;主按钮闸门在 `ReviewFlowState.canPassCommit`
/// (2026-08-22 拍板放宽:**至少选 1 件**即可过,文案仍鼓励选满 3;候选池为空时放行)。
/// 选中的在过闸时写入 `ReviewPinningStore`(独立置顶标记,不动 sortOrder,拍板 6;
/// 写入在 ReviewFlowView.advanceFromCurrentStep)。
/// (2026-08-22 拍板:规则回访卡与「这次存下的规则」卡随存规则链路一并移除。)
struct ReviewStepCommit: View {
    @Bindable var state: ReviewFlowState

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                if state.scheduled.isEmpty {
                    emptyPool
                } else {
                    hint
                    candidateList
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// 挑选说明:至少选 1 件才放行,建议选满 3 件。
    private var hint: some View {
        Text(String(localized: "review.flow.commit.hint"))
            .font(WarmFont.caption(13))
            .foregroundColor(WarmTheme.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 候选池为空:用户一张都没排进下周,无从挑起(闸门放行,见 State 注释)。
    private var emptyPool: some View {
        EmptyStateView(
            icon: "tray",
            message: String(localized: "review.flow.commit.empty"),
            iconSize: 40,
            opacity: 0.6
        )
    }

    private var candidateList: some View {
        VStack(spacing: WarmSpacing.sm) {
            ForEach(state.scheduled) { todo in
                candidateRow(todo)
            }
        }
    }

    private func candidateRow(_ todo: TodoItemData) -> some View {
        let isSelected = state.commitSelection.contains(where: { $0.id == todo.id })
        let selectionIndex = state.commitSelection.firstIndex(where: { $0.id == todo.id })

        return Button {
            HapticFeedback.selection()
            state.toggleCommitSelection(todo)
        } label: {
            RecapCard {
                HStack(spacing: WarmSpacing.md) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? WarmTheme.primary : WarmTheme.textMuted)
                        .flipsForRightToLeftLayoutDirection(true)

                    Text(todo.title)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)

                    Spacer(minLength: WarmSpacing.xs)

                    if let index = selectionIndex {
                        Text(verbatim: "\(index + 1)")
                            .font(WarmFont.mono(13))
                            .foregroundColor(WarmTheme.primaryText)
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isSelected ? 1 : 0.85)
        .accessibilityIdentifier("ReviewFlowCommitRow_\(todo.id.uuidString)")
    }
}
