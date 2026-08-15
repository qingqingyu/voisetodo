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
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            titleEditor

            editorSection(
                icon: "calendar.badge.clock",
                title: "confirm.editor.section.time",
                tint: ConfirmEditorTheme.accent,
                surface: ConfirmEditorTheme.accentSurface
            ) {
                dateRow

                Rectangle()
                    .fill(ConfirmEditorTheme.accent.opacity(0.12))
                    .frame(height: 1)

                TodoClockTimeRow(
                    dueDate: clockDueDate,
                    hasDueTime: clockHasDueTime,
                    timeBucket: $todo.timeBucket,
                    recurrenceFrequency: todo.recurrenceRule?.frequency,
                    appearance: .confirmation,
                    onEdit: { }
                )

                // 提前提醒行:只在带钟点时出现,与日期行同款分隔线。
                if todo.dueTime != nil {
                    Rectangle()
                        .fill(ConfirmEditorTheme.accent.opacity(0.12))
                        .frame(height: 1)

                    TodoReminderOffsetRow(
                        offsetMinutes: $todo.reminderOffsetMinutes,
                        appearance: .confirmation,
                        onEdit: { }
                    )
                }
            }

            editorSection(
                icon: "square.grid.2x2.fill",
                title: "confirm.editor.section.category",
                tint: WarmTheme.color(for: todo.categoryHint),
                surface: ConfirmEditorTheme.neutralSurface
            ) {
                TodoCategoryGrid(
                    selection: $todo.categoryHint,
                    appearance: .confirmation,
                    onEdit: { }
                )
            }

            editorSection(
                icon: "sparkles",
                title: "confirm.editor.section.priority",
                tint: priorityAccent,
                surface: ConfirmEditorTheme.warmSurface
            ) {
                TodoPriorityPicker(
                    selection: $todo.priority,
                    appearance: .confirmation,
                    onEdit: { }
                )
            }

            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "lightbulb.min.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ConfirmEditorTheme.accent)
                Text(String(localized: "confirm.editor.more_in_detail"))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(WarmTheme.textMuted)
            .padding(.horizontal, WarmSpacing.sm)

            collapseButton
        }
        .onAppear { titleFocused = true }
        .tint(ConfirmEditorTheme.accentFill)
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ConfirmEditorTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ConfirmEditorTheme.raisedSurface))

                Text(String(localized: "detail.section.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ConfirmEditorTheme.accent)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            TextField("", text: $todo.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(WarmTheme.textPrimary)
                .focused($titleFocused)
                .accessibilityIdentifier("TodoTitle_\(index)")

            Capsule()
                .fill(ConfirmEditorTheme.accentFill)
                .frame(width: 42, height: 3)
        }
        .padding(WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(
                    LinearGradient(
                        colors: [
                            ConfirmEditorTheme.accentSurface,
                            ConfirmEditorTheme.accentSurface.opacity(0.52)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private func editorSection<Content: View>(
        icon: String,
        title: LocalizedStringKey,
        tint: Color,
        surface: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tint.opacity(0.12)))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            content()
        }
        .padding(WarmSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(surface)
        )
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                Text(String(localized: "confirm.collapse"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(ConfirmEditorTheme.selectedText)
            .frame(maxWidth: .infinity, minHeight: WarmSize.touch)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .fill(ConfirmEditorTheme.accentFill)
            )
            .shadow(color: ConfirmEditorTheme.accentFill.opacity(0.24), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var priorityAccent: Color {
        switch todo.priority {
        case .low: return ConfirmEditorTheme.lowFill
        case .normal: return ConfirmEditorTheme.accent
        case .high: return WarmTheme.urgent
        }
    }

    // MARK: - 日期行

    /// 日期行三态:
    /// 1. `todo.dueDate != nil`(用户已确认 / AI 直接给了 ISO 日期) → 显示日期 popover + ✕
    /// 2. `todo.dueDate == nil` 但 dueHint 可解析 → 显示「AI 推断」日期 + ✕(清推断)
    /// 3. 全空 → 「添加日期」按钮
    ///
    /// 路径 2 解决的 bug:AI 经常只返回 `due_hint="下周三"` 不给 ISO `due_date`,
    /// `TodoItemRow` 列表卡片用 dueHint 兜底显示"下周三"(看似对),
    /// 但编辑面板原判断 `todo.dueDate != nil` 走路径 3 → 显示「添加日期」(看似空)。
    /// 用户点 Add 后,`TodoItem.from` 才用 `TodoDueDateResolver.resolve` 把 dueHint
    /// 换算成 Date → 写入日历正确 → 用户困惑「列表对、面板空、日历又对」。
    /// 路径 2 让面板跟列表/最终落库一致:展示换算后的日期,标注「AI 推断」让用户知道
    /// 这是 AI 算的、可以改/可以否。
    @ViewBuilder
    private var dateRow: some View {
        if todo.dueDate != nil {
            // 路径 1:已确认日期
            HStack(spacing: WarmSpacing.xs) {
                dateIcon
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
        } else if inferredDueDate != nil {
            // 路径 2:dueDate=nil 但 dueHint 可解析 → 显示「AI 推断」日期
            HStack(spacing: WarmSpacing.xs) {
                dateIcon
                TodoDatePopoverTrigger(date: inferredDateBinding, onEdit: { })
                // 「AI 推断」徽标:跟紧急徽标同档(12pt regular),色用 textMuted
                // (派生信息层,跟 sectionHeader / ℹ 提示一致),不抢主操作焦点。
                Text(String(localized: "confirm.editor.inferred"))
                    .font(.system(size: 12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(ConfirmEditorTheme.raisedSurface)
                    )
                Spacer()
                // ✕ 清 dueHint(让推断的源头消失),dueDate 仍保持 nil
                Button {
                    todo.dueHint = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(WarmTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "a11y.clear_inferred_date"))
            }
        } else {
            // 路径 3:无日期无 dueHint → 「添加日期」
            Button {
                todo.dueDate = DayClock.startOfUserDay(for: Date())
                todo.dueDateUserEdited = true
            } label: {
                HStack(spacing: WarmSpacing.xs) {
                    dateIcon
                    Text(String(localized: "detail.add_date"))
                        // 15pt(比"添加钟点"14pt 大一级):日期是主操作,
                        // 钟点是次要操作 —— 字号差承担主次表达。
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
                // accent 青绿(确认页清新风的主操作色)
                .foregroundColor(ConfirmEditorTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var dateIcon: some View {
        Image(systemName: "calendar")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ConfirmEditorTheme.accent)
            .frame(width: 28, height: 28)
            .background(Circle().fill(ConfirmEditorTheme.raisedSurface))
    }

    /// 当 dueDate=nil 但 dueHint 可解析时,实时换算出的日期(只读展示用)。
    /// 不写入 todo.dueDate —— 避免污染 ExtractedTodo 状态(用户没改也算他改了)。
    /// 用户在 popover 里选日期时,setter 才把值真正落到 todo.dueDate。
    private var inferredDueDate: Date? {
        guard todo.dueDate == nil,
              let hint = todo.dueHint, !hint.isEmpty else { return nil }
        return TodoDueDateResolver.resolve(dueHint: hint, title: todo.title, detail: todo.detail)
    }

    /// AI 推断日期的 Binding:
    /// - get: 复用 `inferredDueDate`(单一换算入口,避免两处各算一份)
    /// - set: 用户改日期 → 直接赋给 todo.dueDate + 标记 userEdited,从此走路径 1
    ///
    /// setter 只处理 newValue 非空:popover 里的 DatePicker 只选日期不清日期,
    /// 清日期走旁边的 ✕ 按钮(对应清 dueHint)。
    private var inferredDateBinding: Binding<Date?> {
        Binding(
            get: { inferredDueDate },
            set: { newValue in
                guard let newValue else { return }
                todo.dueDate = newValue
                todo.dueDateUserEdited = true
            }
        )
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
