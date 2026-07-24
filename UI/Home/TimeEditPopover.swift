import SwiftUI

/// 改时间 popover —— 时间 chip 点击后弹出(HTML 设计稿 line 543-552 的"改时间"占位实现)。
///
/// 内容三段式:
/// 1. segmented picker 切「精确时间 / 时段 / 整天」——让用户从任何起点(钟点/时段/无)切到任何终点
/// 2. 主控件:timed 模式给 `DatePicker(.hourAndMinute).wheel`,period 模式给时段 Picker,allDay 模式无控件
/// 3. 「完成」按钮调 `onCommit`,把结果回传调用方写库
///
/// 设计取舍:单一 popover 覆盖三种切换路径,避免「时段 chip 弹时段 picker / 钟点 chip 弹 wheel picker」
/// 这种按 chip 类型分支的设计——会让"想给下午加个具体时间"这种升级流程无法走通。
struct TimeEditPopover: View {
    enum Mode: Hashable, Sendable {
        case timed
        case period
        case allDay
    }

    /// 进 popover 时显示的初始模式(由调用方根据 todo 当前状态推导)。
    @State var mode: Mode
    /// timed 模式下绑定钟点(包含小时分钟)。调用方传入 `todo.dueDate ?? Date()`。
    @Binding var date: Date
    /// period 模式下绑定时段。
    @Binding var period: TimeBucket?

    let onCommit: (Mode, Date, TimeBucket?) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        initialMode: Mode,
        date: Binding<Date>,
        period: Binding<TimeBucket?>,
        onCommit: @escaping (Mode, Date, TimeBucket?) -> Void
    ) {
        self._mode = State(initialValue: initialMode)
        self._date = date
        self._period = period
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: WarmSpacing.sm) {
            Text(String(localized: "home.popover.time_title"))
                .font(WarmFont.headline(14))
                .foregroundColor(WarmTheme.textPrimary)

            Picker(String(localized: "home.popover.mode"), selection: $mode) {
                Text(String(localized: "home.tier.timed")).tag(Mode.timed)
                Text(String(localized: "home.tier.all_day")).tag(Mode.allDay)
                Text(String(localized: "home.popover.mode.period")).tag(Mode.period)
            }
            .pickerStyle(.segmented)

            switch mode {
            case .timed:
                DatePicker(
                    String(localized: "home.popover.time_picker"),
                    selection: $date,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .frame(maxHeight: 120)
            case .period:
                Picker(
                    String(localized: "home.popover.period_picker"),
                    selection: $period
                ) {
                    Text(String(localized: "home.tier.period.morning")).tag(TimeBucket?.some(.morning))
                    Text(String(localized: "home.tier.period.afternoon")).tag(TimeBucket?.some(.afternoon))
                    Text(String(localized: "home.tier.period.evening")).tag(TimeBucket?.some(.evening))
                }
                .pickerStyle(.segmented)
            case .allDay:
                Text(String(localized: "home.popover.all_day_hint"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, WarmSpacing.md)
            }

            Button {
                onCommit(mode, date, period)
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
