import SwiftUI

/// 第 4 步 · 下周三件事(阶段 3;2026-09-01 v2:候选池并集;v6 A2:分
/// 「下周重点 / 也排在下周」两组,勾选的按勾选顺序升入上组)。
///
/// 候选池 = 本会话排进下周的 ∪ **本来就排在下周的**(`commitPool`)——
/// 第 2 步被跳过时池子照样有内容,空池死路消失;「不选进来的不会消失」
/// 也因此成立(走查稿原话)。两组分组渲染,来源写在每项下方。
/// 从池子里挑**最多 3 件**;主按钮闸门在 `ReviewFlowState.canPassCommit`
/// (2026-08-22 拍板放宽:**至少选 1 件**即可过,文案仍鼓励选满 3;候选池
/// 为空时放行)。选中的在过闸时写入 `ReviewPinningStore`(独立置顶标记,
/// 不动 sortOrder,拍板 6;写入在 ReviewFlowView.advanceFromCurrentStep)。
/// v6:去掉选中序号与任何「Focus」标签——勾选圆圈 + 分组已说明一切。
struct ReviewStepCommit: View {
    @Bindable var state: ReviewFlowState

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                if state.commitPool.isEmpty {
                    emptyPool
                } else {
                    hint
                    focusGroup
                    othersGroup
                }
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// 挑选说明:至少选 1 件才放行,建议选满 3 件(文案不变)。
    private var hint: some View {
        Text(String(localized: "review.flow.commit.hint"))
            .font(WarmFont.caption(13))
            .foregroundColor(WarmTheme.textSecondary)
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

    // MARK: 下周重点(勾选的,按勾选顺序)

    /// 上组「下周重点 n/3」:勾选的按勾选顺序(`commitSelection` 即插入序);
    /// 空 = 一行灰字提示「点下面的任务,设为重点」。
    private var focusGroup: some View {
        VStack(spacing: WarmSpacing.sm) {
            groupHeader(
                title: String(localized: "review.flow.commit.group.focus"),
                trailing: "\(state.commitSelection.count)/3"
            )

            if state.commitSelection.isEmpty {
                Text(String(localized: "review.flow.commit.tap_to_focus"))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WarmSpacing.xxs)
            } else {
                ForEach(state.commitSelection) { todo in
                    candidateRow(todo, source: sourceLabel(for: todo))
                }
            }
        }
    }

    // MARK: 也排在下周(未勾选的)

    /// 下组「也排在下周」:候选池里未勾选的。组内顺序沿用 v3 拍板 8 的呈现
    /// 原语——本会话排的按停滞天数降序在前,原本就在下周的随后。
    /// 选满 3 件后其余变灰不可点,组标题右侧出「最多选 3 件」。
    private var othersGroup: some View {
        let unselectedScheduled = TriageRanking.sortByStagnation(
            state.scheduled.filter { todo in
                !state.commitSelection.contains(where: { $0.id == todo.id })
            },
            now: Date()
        )
        let unselectedPreexisting = state.preexistingNextWeek.filter { todo in
            !state.commitSelection.contains(where: { $0.id == todo.id })
        }
        let others = unselectedScheduled + unselectedPreexisting
        return Group {
            if !others.isEmpty {
                VStack(spacing: WarmSpacing.sm) {
                    groupHeader(
                        title: String(localized: "review.flow.commit.group.others"),
                        trailing: isFull
                            ? String(localized: "review.flow.commit.cap_hint")
                            : nil
                    )

                    ForEach(others) { todo in
                        candidateRow(todo, source: sourceLabel(for: todo))
                    }
                }
                .opacity(isFull ? 0.85 : 1)
            }
        }
    }

    private var isFull: Bool {
        state.commitSelection.count >= 3
    }

    /// 每项的来源行:本次排进来的 → 「你刚排进下周的」;原本就在下周的 →
    /// 「已排在下周」(v6 改值,去掉「(还没选为重点)」)。
    private func sourceLabel(for todo: TodoItemData) -> String {
        if state.scheduled.contains(where: { $0.id == todo.id }) {
            return String(localized: "review.flow.commit.group.scheduled")
        }
        return String(localized: "review.flow.commit.group.existing")
    }

    /// 组标题:左侧小标题,右侧 n/3(上组)或「最多选 3 件」(下组满员时)。
    @ViewBuilder
    private func groupHeader(title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ReviewEyebrow(text: title)
                .layoutPriority(1)

            Spacer(minLength: WarmSpacing.xs)

            if let trailing {
                Text(verbatim: trailing)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, WarmSpacing.xxs)
    }

    /// 候选行:勾选圆圈 + 标题 + 来源灰字。选中只用圆圈表示(v6:无序号、
    /// 无 Focus 标签);未选中且已满 3 件 → 不可点。
    private func candidateRow(_ todo: TodoItemData, source: String) -> some View {
        let isSelected = state.commitSelection.contains(where: { $0.id == todo.id })
        let disabled = !isSelected && isFull

        return Button {
            guard !disabled else { return }
            HapticFeedback.selection()
            state.toggleCommitSelection(todo)
        } label: {
            RecapCard {
                HStack(spacing: WarmSpacing.md) {
                    selectionCircle(isSelected: isSelected)

                    VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                        Text(todo.title)
                            .font(WarmFont.headline(16))
                            .foregroundColor(WarmTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(source)
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: WarmSpacing.xs)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("ReviewFlowCommitRow_\(todo.id.uuidString)")
    }

    /// 勾选圆圈(24pt;选中 = 珊瑚底白勾,未选 = 灰圈)。
    private func selectionCircle(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? WarmTheme.primary : WarmTheme.textMuted, lineWidth: 2)
                .background(
                    Circle().fill(isSelected ? WarmTheme.primary : .clear)
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 24, height: 24)
        .flipsForRightToLeftLayoutDirection(true)
    }
}
