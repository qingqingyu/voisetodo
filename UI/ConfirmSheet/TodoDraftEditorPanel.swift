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
        } else if inferredDueDate != nil {
            // 路径 2:dueDate=nil 但 dueHint 可解析 → 显示「AI 推断」日期
            HStack(spacing: WarmSpacing.xs) {
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
                        Capsule().fill(WarmTheme.subtleControlBackground)
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
