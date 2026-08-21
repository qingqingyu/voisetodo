import SwiftUI

/// 第 4 步 · 下周三件事 + 本次存下的规则(阶段 3)。
///
/// 从「排进下周的」里挑**最多 3 件**;主按钮闸门在 `ReviewFlowState.canPassCommit`
/// (不选够不给过)。选中的在过闸时写入 `ReviewPinningStore`(独立置顶标记,
/// 不动 sortOrder,拍板 6;写入在 ReviewFlowView.advanceFromCurrentStep)。
struct ReviewStepCommit: View {
    @Bindable var state: ReviewFlowState

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                hint

                if state.scheduled.isEmpty {
                    emptyPool
                } else {
                    candidateList
                }

                if !state.rulesToRevisit.isEmpty {
                    ruleFollowUpSection
                }

                if !state.savedRules.isEmpty {
                    savedRulesSection
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    @ViewBuilder
    private var hint: some View {
        // 空池放行时 requiredCount == 0:「挑 0 件」是噪音,只显示空池说明卡。
        if state.commitRequiredCount > 0 {
            Text(String(localized: "review.flow.commit.hint_\(state.commitRequiredCount)"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    /// 规则回访(阶段 4):上次会话存下且仍 pending 的规则,问「这条生效了吗」。
    /// 答案 `state.setRuleOutcome` 写入,收尾随 session 落库,并由
    /// `ReviewSessionStore.recordRuleOutcomes` 同步改写历史规则状态(下次不再问)。
    /// 放在本步而非第 3 步:规则是从洞察「存下的决定」,和三件事同属「对决定负责」
    /// 的一步;第 3 步已经有跨期对照 + 卡堆,再叠回访会拥挤。
    private var ruleFollowUpSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "review.flow.followup.title"))
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(state.rulesToRevisit) { rule in
                    ruleFollowUpRow(rule)
                }
            }
        }
    }

    private func ruleFollowUpRow(_ rule: ReviewRule) -> some View {
        let current = state.ruleOutcomes[rule.id] ?? .pending
        return VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Text(rule.text)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Picker(String(localized: "review.flow.followup.title"), selection: Binding(
                get: { current },
                set: { state.setRuleOutcome(ruleID: rule.id, status: $0) }
            )) {
                Text(String(localized: "review.flow.followup.status.pending")).tag(ReviewRuleStatus.pending)
                Text(String(localized: "review.flow.followup.status.working")).tag(ReviewRuleStatus.working)
                Text(String(localized: "review.flow.followup.status.not_working")).tag(ReviewRuleStatus.notWorking)
                Text(String(localized: "review.flow.followup.status.retired")).tag(ReviewRuleStatus.retired)
            }
            .pickerStyle(.menu)
            .frame(minWidth: 44, alignment: .leading)
        }
        .accessibilityIdentifier("ReviewFlowFollowUp_\(rule.id.uuidString)")
    }

    /// 本次存下的规则(洞察卡规则按钮的落点;持久化在阶段 4)。
    private var savedRulesSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "review.flow.commit.rules_title"))
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                ForEach(state.savedRules) { rule in
                    HStack(alignment: .top, spacing: WarmSpacing.sm) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12))
                            .foregroundColor(WarmTheme.primary)
                        Text(rule.text)
                            .font(WarmFont.body(14))
                            .foregroundColor(WarmTheme.textSecondary)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }
}
