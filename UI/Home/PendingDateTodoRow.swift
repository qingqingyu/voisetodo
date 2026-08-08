import SwiftUI

/// 「待定日期」分组的卡片:有时间信号(timeBucket 或 dueHint)但没具体日期。
///
/// 与正常 WarmTodoCard 的差异:
/// - **左侧带 `CategoryIconView`**(跟 WarmTodoCard 一致),分类视觉语言统一。
/// - 右侧「选日期」按钮为橙描边主级 CTA(primary 1pt 描边 + primary 文字)。
///   样式沿革详见按钮 label 内注释。
/// - chip 用 `.loose` 样式显示时段 / dueHint(如「下午」「这个周末」)。
/// - 标题 `lineLimit(3)`(比 WarmTodoCard 的 nil 紧,因右侧按钮 fixedSize 挤压)。
///
/// 选日期 popover 提交后,该 todo 因 `dueDate != nil` 自动离开 `pendingDateTodos`,
/// 进入 Today 的对应 tier(整天/时段/按时间)。
struct PendingDateTodoRow: View {
    let todo: TodoItemData
    let index: Int
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onPickDate: (Date) -> Void

    @State private var showDatePicker = false
    @State private var pickedDate: Date = Date()

    /// chip 文本拼接规则:
    /// - 有 timeBucket:`bucket.localizedTitle`(如「下午」)
    /// - 有 dueHint 无 timeBucket:`dueHint`(如「等会儿」「这个周末」「月底之前」)
    /// - 都没有:「未定时间」
    ///
    /// 之前每条都带「· 未定哪天」后缀,但分组名 + 右侧「选日期」按钮已经把"未定日期"
    /// 表达清楚,后缀反而冗余。用户 2026-07-26 真机反馈:每行都带显得啰嗦。
    private var looseChipText: String {
        if let bucket = todo.timeBucket {
            return bucket.localizedTitle
        }
        let hint = todo.dueHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hint.isEmpty {
            return hint
        }
        return String(localized: "home.chip.no_time")
    }

    var body: some View {
        Button(action: onOpen) {
            // alignment: .center:checkbox + 「选日期」按钮都垂直居中对齐整个 VStack(标题+chip)。
            // 用户 2026-07-25 真机反馈:之前用 .top 时,标题 1 行卡片扁平,checkbox 与按钮顶部
            // 都贴标题字顶;当标题换 2 行后(AX5 字号/长英文)VStack 拉高,两者贴顶不齐。
            // 改 .center 让两侧控件坐卡片纵向中点,与「视觉居中」预期一致。
            HStack(alignment: .center, spacing: WarmSpacing.sm) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .stroke(WarmTheme.sketch, lineWidth: 2)
                            .frame(width: WarmSize.icon - 4, height: WarmSize.icon - 4)
                        Circle()
                            .fill(WarmTheme.success)
                            .frame(width: WarmSize.icon - 4, height: WarmSize.icon - 4)
                            .opacity(0)
                    }
                    // alignment: .center 让 24pt 圆环居 44pt frame 中央,配合外层 HStack(.center)
                    // 让 checkbox 始终坐卡片纵向中点。44pt frame 保留以撑 HIG hit target。
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PendingDateCheckbox_\(index)")

                CategoryIconView(category: todo.category)

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    Text(todo.title)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        // lineLimit(3):右侧「选日期」按钮 fixedSize + 左侧 CategoryIconView
                        // 双重挤压标题可用宽(AX5 字号下尤其紧张)。原 lineLimit(2) 在加图标后
                        // 会让长标题过早 tail 截断,放宽到 3 行作为对冲——卡片高度有界,
                        // 用户点开详情看完整内容。
                        // 详见 feedback memory「文本截断/换行零容忍」的"有按钮挤压"例外条款。
                        // 与 WarmTodoCard(无「选日期」按钮挤压)的 lineLimit(nil) 无限换行策略区分。
                        .lineLimit(3)
                        .truncationMode(.tail)

                    ChipView(
                        text: looseChipText,
                        style: .loose,
                        accent: WarmTheme.textMuted,
                        // looseChipText 直接来自 AI 原文(timeBucket.localizedTitle 或 dueHint),
                        // 长度无界(如 "by the end of this month")。走 marquee 让 chip 宽度可被
                        // 父压缩,放不下时滚动 —— 不再挤掉标题、不再溢出卡片。
                        overflow: .marquee
                    )
                }

                Spacer(minLength: 0)

                Button {
                    pickedDate = Date()
                    showDatePicker = true
                } label: {
                    Text(String(localized: "home.pending_date.pick"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.primary)
                        // 橙描边主级 CTA:primary 1pt 描边 + primary 文字 + 透明底。
                        // 历史:曾用实心 primary 填充(过重),又改成 sketch 灰描边 + textSecondary 文字
                        // (过弱,视觉上像禁用状态——比 checkbox 灰圈还低)。
                        // 用户 2026-07-27 反馈:作为卡片最重要的动作却长得像 disabled。
                        // 橙描边 + 橙文字是中间方案:有 CTA 色彩语义,但不抢眼到压过标题。
                        // padding 沿用 (10, xxs):跟 .loose chip(9,3) 密度同档,让卡片视觉重量均衡。
                        .padding(.horizontal, 10)
                        .padding(.vertical, WarmSpacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .stroke(WarmTheme.primary, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                // fixedSize 让按钮按 intrinsic 内容宽度参与 layout,不被 HStack 压缩。
                // 否则标题长时(如 "Finish filing taxes")按钮宽度被压到无法容纳 "Pick date",
                // 触发字符级换行 + 裁切(用户真机反馈「Pic k / dat e」竖排)。
                // 按钮稳定等大,标题承担换行(标题已有 .fixedSize(horizontal: false, vertical: true))。
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("PendingDatePick_\(index)")
                .popover(isPresented: $showDatePicker) {
                    VStack(spacing: WarmSpacing.sm) {
                        Text(String(localized: "home.popover.date_title"))
                            .font(WarmFont.headline(14))
                        DatePicker(
                            String(localized: "home.popover.date_picker"),
                            selection: $pickedDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .frame(maxHeight: 280)

                        Button {
                            let startOfDay = Calendar.current.startOfDay(for: pickedDate)
                            onPickDate(startOfDay)
                            showDatePicker = false
                        } label: {
                            Text(String(localized: "home.popover.done"))
                                .font(WarmFont.headline(14))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, WarmSpacing.xs)
                                .background(
                                    RoundedRectangle(cornerRadius: WarmRadius.chip)
                                        .fill(WarmTheme.primary)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(WarmSpacing.md)
                    .frame(width: 320)
                }
            }
            .padding(.horizontal, WarmSpacing.md)
            .padding(.vertical, WarmSpacing.xxs)
            // 不再自带白色圆角卡底 —— 「待定日期」整个分区现在合成一张卡,
            // 底色/圆角/条目间发丝线由调用方的 `groupedCardRow` 统一画。
            // 底透明后空白处不参与 hit test,补 contentShape 让整行都能点开详情。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .accessibilityIdentifier("PendingDateRow_\(index)")
    }
}

// MARK: - Previews

#if DEBUG

/// 行本身已不自带卡底(由 `groupedCardRow` 统一画),所以 Preview 必须放进 `List`
/// 才能看到真实外观 —— `listRowBackground` 在 List 之外是 no-op。
private struct PendingDateRowPreviewList: View {
    let todos: [TodoItemData]

    var body: some View {
        List {
            Section {
                ForEach(Array(todos.enumerated()), id: \.offset) { idx, todo in
                    PendingDateTodoRow(
                        todo: todo,
                        index: idx,
                        onToggle: {}, onOpen: {}, onDelete: {}, onPickDate: { _ in }
                    )
                    .groupedCardRow(
                        GroupedRowPosition(index: idx, count: todos.count),
                        height: .tall
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(WarmTheme.background)
    }
}

#Preview("PendingDateTodoRow — 长 hint EN/ZH") {
    // 复用 MockStore.withLongHints fixture,避免在 Preview 里重复构造相同 TodoItemData。
    // 这也确保 fixture 不变成死代码 —— 任何 withLongHints 的修改都会反映到本 Preview。
    PendingDateRowPreviewList(todos: MockStore.withLongHints.todos)
}

#Preview("PendingDateTodoRow — AX5 字号") {
    // 取 withLongHints 第一条(长 EN hint)做 AX5 字号下单行预览。
    // 单行时 position 是 .only —— 四角全圆、不画发丝线。
    PendingDateRowPreviewList(todos: Array(MockStore.withLongHints.todos.prefix(1)))
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#endif
