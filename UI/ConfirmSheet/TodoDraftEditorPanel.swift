import SwiftUI

/// 确认页卡片就地展开的编辑面板。
///
/// 录音解析后 ConfirmSheet 的卡片点击展开此面板,编辑标题/日期/钟点/时段/分类/优先级。
/// 改动直接写回 @Binding todo(ExtractedTodo),点 Add N 时随 coordinator.extractedTodos
/// 一并提交。复用详情页抽出的共享组件(TodoFieldEditors),样式与详情页一致。
///
/// 模型桥接:ExtractedTodo 用 dueDate(日期)+ dueTime("HH:mm") 分离存储,
/// 详情页组件用 dueDate(含时分)+ hasDueTime(Bool)。本面板用计算 Binding 桥接,
/// 复用 TodoDueTimeResolver.combine 合并读、拆分写。
struct TodoDraftEditorPanel: View {
    @Binding private var todo: ExtractedTodo
    private let onCollapse: () -> Void
    /// 卡片在 ConfirmGroupedList 中的 index,用于 a11y id 命名(TodoTitle_\(index)),
    /// 让 UI 测试(AppLaunchHelper.editTodoInSheet)在新流程下仍可定位标题输入框。
    private let index: Int

    @FocusState private var titleFocused: Bool

    init(todo: Binding<ExtractedTodo>, index: Int, onCollapse: @escaping () -> Void) {
        self._todo = todo
        self.index = index
        self.onCollapse = onCollapse
    }

    var body: some View {
        // 外层 spacing=md(16) 组间距:取代旧 sm(12),让分组之间有更明确的视觉分隔,
        // 配合"分组标题 12pt + 控件 14pt"的字号层级,整体节奏更舒展。
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            // 1. 标题 —— 进入时自动聚焦,承接原「点卡片一步改名」的效率
            // 标题 TextField 沿用旧内联编辑的 a11y id TodoTitle_\(index),
            // 让 UI 测试(AppLaunchHelper.editTodoInSheet:点 TodoTitleText 后查 TodoTitle_)
            // 在新「展开面板」流程下仍可命中——点 staticText 触发卡片展开,
            // 面板内此 TextField 带同 index id,helper 第二步直接定位到。
            //
            // 字号 20pt(基准 14 + 6,比旧 22pt 收一级):仍是面板唯一大字号,
            // 强化「主内容」锚点,但 22pt 在紧凑编辑卡片里略大、压属性;
            // 20pt 后任务名仍突出,又不抢下方控件视觉空间。
            TextField("", text: $todo.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(WarmTheme.textPrimary)
                .focused($titleFocused)
                .accessibilityIdentifier("TodoTitle_\(index)")

            // 2. 日期行 —— 有日期:popover + ✕;无日期:「添加日期」
            dateRow

            Divider()

            // 3-5. 三组属性区:每组用内层 VStack(spacing: xs=8) 把「标题 + 控件」紧贴,
            // 组与组之间靠外层 spacing=md(16) 拉开(16 vs 8 = 2x 视觉差)—— 标题紧贴它管的那组,
            // 不会跟"上一组控件"凑近造成归属歧义。
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                sectionHeader("confirm.editor.section.time")
                TodoClockTimeRow(
                    dueDate: clockDueDate,
                    hasDueTime: clockHasDueTime,
                    timeBucket: $todo.timeBucket,
                    recurrenceFrequency: todo.recurrenceRule?.frequency,
                    onEdit: { }
                )
            }

            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                sectionHeader("confirm.editor.section.category")
                TodoCategoryGrid(selection: $todo.categoryHint, onEdit: { })
            }

            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                sectionHeader("confirm.editor.section.priority")
                TodoPriorityPicker(selection: $todo.priority, onEdit: { })
            }

            // 6. 收起 —— 14pt semibold(与控件同级,只是 weight 更重 + 主操作色)
            // 收起是辅助操作不是主内容,不需要比控件大;跟任务名(20pt)拉开明显差距。
            Button(action: onCollapse) {
                Text(String(localized: "confirm.collapse"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)

            // 7. 友善提示:面板只覆盖最高频字段(标题/日期/时间/分类/优先级),
            // 备注(detail)和重复规则(recurrenceRule)需要先 Add 进列表,
            // 从 HomeView 点卡片进详情页才能改——避免用户在面板里找不着这两个字段。
            // 放最底部、textMuted,作为补充信息出现,不抢主操作焦点。
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text(String(localized: "confirm.editor.more_in_detail"))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(WarmTheme.textMuted)
        }
        .onAppear { titleFocused = true }
    }

    // MARK: - 分组小标题

    /// 分组标题(「时间 / 分类 / 优先级」)。
    ///
    /// 字号 12pt、semibold、textMuted 灰色 —— 与 ℹ 提示同档(派生信息层),
    /// 但用 semibold(提示用 regular)区分"导航锚点" vs "辅助说明"。
    /// 视觉重量刻意轻:它是导航锚点不是内容,不能抢属性控件(14pt)的焦点。
    /// 三组共用同一样式保持一致,但下方控件形态各异(segmented/chips/浅底),
    /// 避免用户误判为同一组控件。
    @ViewBuilder
    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(WarmTheme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - 日期行

    @ViewBuilder
    private var dateRow: some View {
        if todo.dueDate != nil {
            HStack {
                TodoDatePopoverTrigger(date: dateRowDate, onEdit: { })
                Spacer()
                Button {
                    todo.dueDate = nil
                    todo.dueTime = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(WarmTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                todo.dueDate = DayClock.startOfUserDay(for: Date())
                todo.dueDateUserEdited = true
            } label: {
                HStack(spacing: WarmSpacing.xs) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15))
                    Text(String(localized: "detail.add_date"))
                        // 15pt(比"添加钟点"14pt 大一级):日期是主操作,
                        // 钟点是次要操作 —— 字号差承担主次表达。
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
                // primaryText 深橙(浅底文字对比度优于直接 primary)
                .foregroundColor(WarmTheme.primaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private var dateRowDate: Binding<Date?> {
        Binding(
            get: { todo.dueDate },
            set: { newValue in
                todo.dueDate = newValue
                todo.dueDateUserEdited = true
            }
        )
    }

    // MARK: - 钟点 + 时段 模型桥接(ExtractedTodo ↔ TodoClockTimeRow)

    /// TodoClockTimeRow 用的 dueDate(含时分)。
    /// - get: combine(todo.dueDate, todo.dueTime) 合并出含时分的 Date。
    /// - set: 拆回 —— todo.dueDate 存日期部分(startOfDay);若 hasDueTime
    ///   (todo.dueTime != nil)同步更新 todo.dueTime 为新钟点。
    private var clockDueDate: Binding<Date?> {
        Binding(
            get: {
                TodoDueTimeResolver.combine(date: todo.dueDate, dueTime: todo.dueTime).date
            },
            set: { newValue in
                guard let newValue else {
                    todo.dueDate = nil
                    return
                }
                let calendar = Calendar.current
                todo.dueDate = calendar.startOfDay(for: newValue)
                if todo.dueTime != nil {
                    todo.dueTime = String(
                        format: "%02d:%02d",
                        calendar.component(.hour, from: newValue),
                        calendar.component(.minute, from: newValue)
                    )
                }
                todo.dueDateUserEdited = true
            }
        )
    }

    /// TodoClockTimeRow 用的 hasDueTime。
    /// - get: todo.dueTime != nil(有钟点 = 有 due time)。
    /// - set(true): 设 todo.dueTime 为当前时刻,清 timeBucket(维持互斥)。
    /// - set(false): 清 todo.dueTime。
    private var clockHasDueTime: Binding<Bool> {
        Binding(
            get: { todo.dueTime != nil },
            set: { newHasDueTime in
                if newHasDueTime {
                    let calendar = Calendar.current
                    let now = Date()
                    todo.dueTime = String(
                        format: "%02d:%02d",
                        calendar.component(.hour, from: now),
                        calendar.component(.minute, from: now)
                    )
                    // 维持 ExtractedTodo.init 的不变式:dueTime 与 timeBucket 互斥。
                    // 面板绕过 init 直接改字段,这里显式清 timeBucket。
                    todo.timeBucket = nil
                } else {
                    todo.dueTime = nil
                }
            }
        )
    }
}
