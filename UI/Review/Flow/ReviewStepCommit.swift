import SwiftUI

/// 第 4 步 · 下周三件事(阶段 3;2026-09-01 v2:候选池并集)。
///
/// 候选池 = 本会话排进下周的 ∪ **本来就排在下周的**(`commitPool`)——
/// 第 2 步被跳过时池子照样有内容,空池死路消失;「不选进来的不会消失」
/// 也因此成立(走查稿原话)。两组分组渲染,来源一目了然。
/// 从池子里挑**最多 3 件**;主按钮闸门在 `ReviewFlowState.canPassCommit`
/// (2026-08-22 拍板放宽:**至少选 1 件**即可过,文案仍鼓励选满 3;候选池
/// 为空时放行)。选中的在过闸时写入 `ReviewPinningStore`(独立置顶标记,
/// 不动 sortOrder,拍板 6;写入在 ReviewFlowView.advanceFromCurrentStep)。
/// (2026-08-22 拍板:规则回访卡与「这次存下的规则」卡随存规则链路一并移除。)
struct ReviewStepCommit: View {
    @Bindable var state: ReviewFlowState

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                if state.commitPool.isEmpty {
                    emptyPool
                } else {
                    hint
                    if !state.scheduled.isEmpty {
                        groupHeader(String(localized: "review.flow.commit.group.scheduled"))
                        candidateList(state.scheduled)
                    }
                    if !state.preexistingNextWeek.isEmpty {
                        groupHeader(String(localized: "review.flow.commit.group.existing"))
                        candidateList(state.preexistingNextWeek)
                    }
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

    /// 候选池为空:下周一张都没有,无从挑起(闸门放行,见 State 注释)。
    private var emptyPool: some View {
        EmptyStateView(
            icon: "tray",
            message: String(localized: "review.flow.commit.empty"),
            iconSize: 40,
            opacity: 0.6
        )
    }

    /// 分组小标题(两组同显时才需要;单组场景由上下文自明,标题照样显示——
    /// 来源信息让「不选进来的不会消失」可被验证)。
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(WarmFont.caption(12))
            .foregroundColor(WarmTheme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateList(_ todos: [TodoItemData]) -> some View {
        VStack(spacing: WarmSpacing.sm) {
            ForEach(todos) { todo in
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
