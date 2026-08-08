import SwiftUI

/// 改时间 popover —— 时间 chip 点击后弹出,只编辑钟点。
///
/// 单一 `DatePicker(.hourAndMinute).wheel`,「完成」按钮把新钟点回传调用方写库。
/// 之前曾用 segmented picker 切「精确时间 / 时段 / 整天」,已移至 `WarmTodoCard`
/// 的 contextMenu,这里只留钟点编辑。
struct TimeEditPopover: View {
    /// timed 模式下绑定钟点(包含小时分钟)。调用方传入 `todo.dueDate ?? Date()`。
    @Binding var date: Date

    let onCommit: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        date: Binding<Date>,
        onCommit: @escaping (Date) -> Void
    ) {
        self._date = date
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: WarmSpacing.lg) {
            Text(String(localized: "home.popover.time_title"))
                .font(WarmFont.headline(16))
                .foregroundColor(WarmTheme.textPrimary)

            DatePicker(
                String(localized: "home.popover.time_picker"),
                selection: $date,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .frame(maxHeight: 120)

            Button {
                onCommit(date)
                dismiss()
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
            .accessibilityIdentifier("TimeEditPopoverDone")
        }
        .padding(WarmSpacing.md)
        .frame(width: 280)
    }
}
