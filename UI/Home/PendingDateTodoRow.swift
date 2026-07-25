import SwiftUI

/// 「待定日期」分组的卡片:有时间信号(timeBucket 或 dueHint)但没具体日期。
///
/// 与正常 WarmTodoCard 的差异:
/// - 右侧加珊瑚色实心「选日期」按钮(remedial 强暗示,与今日可点 chip 的 optional 弱暗示形成对比)
/// - chip 用 `.loose` 样式显示「时段 · 未定哪天」(HTML line 408-413)
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

    /// chip 文本拼接规则(HTML line 411, 423, 436):
    /// - 有 timeBucket:「`bucket.localizedTitle` · 未定哪天」(如「下午 · 未定哪天」)
    /// - 有 dueHint 无 timeBucket:「`dueHint` · 未定哪天」(如「等会儿 · 未定哪天」)
    /// - 都没有:「未定时间」
    private var looseChipText: String {
        if let bucket = todo.timeBucket {
            return "\(bucket.localizedTitle) · \(String(localized: "home.chip.undated"))"
        }
        let hint = todo.dueHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hint.isEmpty {
            return "\(hint) · \(String(localized: "home.chip.undated"))"
        }
        return String(localized: "home.chip.no_time")
    }

    var body: some View {
        Button(action: onOpen) {
            // alignment: .top:checkbox frame 顶部对齐 VStack 顶部(第一行标题顶部),
            // 避免 .center 时 checkbox 居中对齐整个 VStack(标题+chip)低于第一行标题中心。
            HStack(alignment: .top, spacing: WarmSpacing.sm) {
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
                    // alignment: .top 让 24pt 圆环居 44pt frame 顶部,
                    // offset 上移让圆心(原在 +12pt)对齐第一行标题视觉中心(约 +9pt)。
                    // 偏移量抽到 HomeLayoutMetrics.checkboxTitleAlignmentOffset,
                    // 与 WarmTodoCard 共用同一经验值,改一处同步生效。
                    .frame(width: 44, height: 44, alignment: .top)
                    .offset(y: HomeLayoutMetrics.checkboxTitleAlignmentOffset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PendingDateCheckbox_\(index)")

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    Text(todo.title)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        // lineLimit(2):右侧「选日期」按钮加了 fixedSize 后会按 intrinsic 宽度
                        // 参与布局,在 AX5 字号 + 长标题场景下挤压标题空间(可用宽可能只剩 50pt,
                        // 中文 1-2 字/行,长标题会换 5+ 行撑高卡片)。
                        // 用户决定限 2 行后 tail 截断——卡片高度有界,用户点开详情看完整内容。
                        // 详见 feedback memory「文本截断/换行零容忍」的"有按钮挤压"例外条款。
                        // 与 WarmTodoCard(无按钮挤压)的 lineLimit(nil) 无限换行策略区分。
                        .lineLimit(2)
                        .truncationMode(.tail)

                    ChipView(
                        text: looseChipText,
                        style: .loose,
                        accent: WarmTheme.textMuted
                    )
                }

                Spacer(minLength: 0)

                Button {
                    pickedDate = Date()
                    showDatePicker = true
                } label: {
                    Text(String(localized: "home.pending_date.pick"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(.white)
                        // padding 对齐 ChipView 的密度(horizontal 9 / vertical 3),
                        // 避免垂直留白过厚让字看起来"浮"在橙色块中间产生断层感。
                        // 略比 chip 大一档(10/4 vs 9/3)是因为它是 primary CTA,
                        // 视觉权重需要稍强于纯展示 chip。
                        // 说明:10 与 ChipView 的 9 一样偏离 WarmSpacing 的「4 借数系统」,
                        // 是 chip 系视觉一致性的有意破例(WarmSpacing 无 9/10 档位,强行归档会破坏 chip 密度)。
                        .padding(.horizontal, 10)
                        .padding(.vertical, WarmSpacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.primary)
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
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.chip)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 4, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xxs,
                                  leading: WarmSpacing.lg,
                                  bottom: WarmSpacing.xxs,
                                  trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
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
