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
            HStack(spacing: WarmSpacing.sm) {
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PendingDateCheckbox_\(index)")

                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    Text(todo.title)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

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
                        .padding(.horizontal, WarmSpacing.sm)
                        .padding(.vertical, WarmSpacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.primary)
                        )
                }
                .buttonStyle(.plain)
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
