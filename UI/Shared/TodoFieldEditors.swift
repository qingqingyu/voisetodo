import SwiftUI
import UIKit

/// 日期 popover 入口文本 formatter(跟随系统 locale)。
/// 从 TodoDetailView 抽出 —— 原为 file-private 顶层(泛型类型不许 static stored properties),
/// 此处同样放 file-private 顶层供 TodoDatePopoverTrigger 使用。
private let todoFieldEditorDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

// MARK: - 分类网格

/// 分类选择网格(自适应 LazyVGrid,7 个分类按屏宽换行)。
///
/// 从 `TodoDetailView.categoryChip` + body 的 `LazyVGrid` 抽出。
/// 纯 UI + Binding,不含标题 Text 与 detailCard 外壳 —— 调用方自行包裹。
/// 视觉与 a11y 与原详情页逐项一致。
struct TodoCategoryGrid: View {
    @Binding private var selection: TodoCategory
    private let onEdit: () -> Void

    init(selection: Binding<TodoCategory>, onEdit: @escaping () -> Void) {
        self._selection = selection
        self.onEdit = onEdit
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64), spacing: WarmSpacing.xs)],
            spacing: WarmSpacing.xs
        ) {
            ForEach(TodoCategory.allCases, id: \.self) { category in
                chip(category)
            }
        }
    }

    private func chip(_ category: TodoCategory) -> some View {
        let isSelected = selection == category
        return Button {
            withAnimation(WarmAnimation.springStandard) {
                selection = category
                onEdit()
            }
        } label: {
            Text(category.displayName)
                .font(WarmFont.caption(13))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground)
                )
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 优先级选择器

/// 优先级三档选择器(HStack:低/普通/高)。
///
/// 从 `TodoDetailView.priorityButton` + `priorityButtonBackground` + body 的 `HStack` 抽出。
/// 颜色语义:High 选中→实心 urgent(红)+白字;Normal 选中→实心 primary +白字;
/// Low 选中→实心 primaryLight + textPrimary;未选中→浅灰底 + textSecondary。
struct TodoPriorityPicker: View {
    @Binding private var selection: Priority
    private let onEdit: () -> Void

    init(selection: Binding<Priority>, onEdit: @escaping () -> Void) {
        self._selection = selection
        self.onEdit = onEdit
    }

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            button(.low, label: String(localized: "detail.priority.low"), icon: "arrow.down")
            button(.normal, label: String(localized: "detail.priority.normal"), icon: "minus")
            button(.high, label: String(localized: "detail.priority.high"), icon: "exclamationmark")
        }
    }

    private func button(_ priority: Priority, label: String, icon: String) -> some View {
        let isSelected = selection == priority
        return Button {
            withAnimation(WarmAnimation.springStandard) {
                selection = priority
                onEdit()
            }
        } label: {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(WarmFont.caption(13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WarmSpacing.sm)
            .background(background(isSelected: isSelected, priority: priority))
            .foregroundColor(
                isSelected
                    ? (priority == .low ? WarmTheme.textPrimary : .white)
                    : WarmTheme.textSecondary
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func background(isSelected: Bool, priority: Priority) -> some View {
        let shape = RoundedRectangle(cornerRadius: WarmRadius.card)
        if isSelected {
            switch priority {
            case .high:
                shape.fill(WarmTheme.urgent)
            case .normal:
                shape.fill(WarmTheme.primary)
            case .low:
                shape.fill(WarmTheme.primaryLight)
            }
        } else {
            shape.fill(WarmTheme.secondaryBackground)
        }
    }
}

// MARK: - 时段 chip 行

/// 模糊时段 chip 行(FlowLayout,按 TimeBucket.chronologicalOrder 排列)。
///
/// 从 `TodoDetailView.timeBucketButton` + `chipRow` 抽出。
/// `.anytime` 选中时写回 nil(与原 timeBucketButton 语义一致)。
struct TodoTimeBucketChipRow: View {
    @Binding private var selection: TimeBucket?
    private let onEdit: () -> Void

    init(selection: Binding<TimeBucket?>, onEdit: @escaping () -> Void) {
        self._selection = selection
        self.onEdit = onEdit
    }

    var body: some View {
        FlowLayout(horizontalSpacing: WarmSpacing.xs, verticalSpacing: WarmSpacing.xs) {
            ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                chip(bucket)
            }
        }
    }

    private func chip(_ bucket: TimeBucket) -> some View {
        let selectedBucket = selection ?? .anytime
        let isSelected = selectedBucket == bucket
        return Button {
            withAnimation(WarmAnimation.springFast) {
                selection = bucket == .anytime ? nil : bucket
                onEdit()
            }
        } label: {
            Text(bucket.localizedTitle)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 日期 popover 触发器

/// 日期触发器(app 自控 .popover + .graphical,选中即收)。
///
/// 从 `TodoDetailView.datePopoverTrigger` + `datePopoverBinding` + `schedulePopoverDismiss` 抽出。
/// popover 显隐、fallback 锚点、dismiss Task、haptic generator 全部随组件内部 @State 管理。
/// a11y id `DetailDatePopoverTrigger` 保留。
struct TodoDatePopoverTrigger: View {
    @Binding private var date: Date?
    private let onEdit: () -> Void

    @State private var showDatePickerPopover = false
    @State private var popoverFallbackAnchor: Date?
    @State private var popoverDismissTask: Task<Void, Never>?
    @State private var selectionFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    init(date: Binding<Date?>, onEdit: @escaping () -> Void) {
        self._date = date
        self.onEdit = onEdit
    }

    var body: some View {
        trigger
    }

    private var trigger: some View {
        Button {
            // 打开瞬间捕获回退锚点:之后 popover 内 getter / 标签都用这一份稳定值,
            // 避免 SwiftUI body 重建时反复调 Date() 导致跨用户日起点漂移。
            if popoverFallbackAnchor == nil {
                popoverFallbackAnchor = DayClock.startOfUserDay(for: Date())
            }
            showDatePickerPopover = true
        } label: {
            HStack(spacing: WarmSpacing.xxs) {
                Text(todoFieldEditorDateFormatter.string(from: date ?? popoverFallbackAnchor ?? DayClock.startOfUserDay(for: Date())))
                    .font(WarmFont.body(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(WarmTheme.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "detail.time"))
        .accessibilityValue(todoFieldEditorDateFormatter.string(from: date ?? popoverFallbackAnchor ?? DayClock.startOfUserDay(for: Date())))
        .accessibilityIdentifier("DetailDatePopoverTrigger")
        .popover(isPresented: $showDatePickerPopover) {
            VStack(spacing: WarmSpacing.sm) {
                DatePicker(
                    "",
                    selection: popoverBinding,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
            }
            .padding(WarmSpacing.md)
            .frame(width: 320)
            .onAppear {
                // 预热 haptic engine —— 首次 impactOccurred() 才不会因 engine 冷启动延迟/丢失。
                selectionFeedbackGenerator.prepare()
            }
        }
        .onDisappear {
            // 日期 popover 自动收起 task 一并 cancel —— 组件已退出,防止 task 在 dismiss 后
            // 仍触发 showDatePickerPopover 写入(虽无害,但状态干净更可预测)。
            // 与原 TodoDetailView.onDisappear 行为对齐,行为零回归。
            popoverDismissTask?.cancel()
            popoverDismissTask = nil
        }
    }

    /// 日期 popover 内 DatePicker 的双向绑定。setter 三件事:
    /// 1) 写入 date + onEdit;2) 触觉反馈;3) schedulePopoverDismiss。
    /// 边界:点已选中的同一日期时值不变,setter 不触发,popover 不收 —— 用户可点别处兜底,
    /// 与原系统 compact 行为一致。
    private var popoverBinding: Binding<Date> {
        Binding(
            get: { date ?? popoverFallbackAnchor ?? DayClock.startOfUserDay(for: Date()) },
            set: { newValue in
                date = newValue
                onEdit()
                selectionFeedbackGenerator.impactOccurred()
                selectionFeedbackGenerator.prepare()
                schedulePopoverDismiss()
            }
        )
    }

    /// 选完日期后延迟 ~0.18s 收起 popover,留时间让 .graphical 的选中黑圈动画播完。
    /// 用 Task 而非 DispatchQueue.main.asyncAfter —— 可取消:连续选不同日期时 cancel 上一次。
    private func schedulePopoverDismiss() {
        popoverDismissTask?.cancel()
        popoverDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showDatePickerPopover = false
            }
        }
    }
}

// MARK: - 钟点 + 时段行

/// 钟点 + 时段合并行。
///
/// 从 `TodoDetailView.timeSection` 抽出。两种状态由 `hasDueTime` 决定:
/// - hasDueTime=true:钟点 DatePicker + 派生 TimeBucket 只读 + 清除钟点按钮
/// - hasDueTime=false:「添加钟点」按钮(canAddClockTime 守门)+ 时段 chip 行(复用 TodoTimeBucketChipRow)
///
/// 不变式:hasDueTime == true ⇒ dueDate != nil —— UI 侧维持。
/// a11y id `DetailAddTimeButton` 保留。
struct TodoClockTimeRow: View {
    @Binding private var dueDate: Date?
    @Binding private var hasDueTime: Bool
    @Binding private var timeBucket: TimeBucket?
    private let recurrenceFrequency: RecurrenceFrequency?
    private let onEdit: () -> Void

    init(
        dueDate: Binding<Date?>,
        hasDueTime: Binding<Bool>,
        timeBucket: Binding<TimeBucket?>,
        recurrenceFrequency: RecurrenceFrequency?,
        onEdit: @escaping () -> Void
    ) {
        self._dueDate = dueDate
        self._hasDueTime = hasDueTime
        self._timeBucket = timeBucket
        self.recurrenceFrequency = recurrenceFrequency
        self.onEdit = onEdit
    }

    var body: some View {
        if hasDueTime {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                HStack {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { dueDate ?? Date() },
                            set: { newTime in
                                // DatePicker(.hourAndMinute) 的 set 给的是完整 Date,
                                // 但只有钟点部分有意义——把它合并到 dueDate 的日期部分。
                                let calendar = Calendar.current
                                var components = calendar.dateComponents([.year, .month, .day], from: dueDate ?? Date())
                                components.hour = calendar.component(.hour, from: newTime)
                                components.minute = calendar.component(.minute, from: newTime)
                                dueDate = calendar.date(from: components)
                                onEdit()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()

                    Spacer()

                    // 清除钟点:保留 dueDate(日期部分) 和 timeBucket(手动选择),
                    // 只切 hasDueTime=false。下次再点"添加钟点"会从当前时刻开始。
                    Button {
                        hasDueTime = false
                        onEdit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                // 派生 TimeBucket 只读显示:不写回 timeBucket,清钟点后会自然回到手动模式。
                let derived = TimeBucketResolver.effective(
                    explicitBucket: timeBucket,
                    dueDate: dueDate,
                    hasDueTime: hasDueTime
                )
                Text(derived.localizedTitle)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                // 「添加钟点」可见性:有 dueDate 或有重复规则即可。
                if RecurrenceAnchorPolicy.canAddClockTime(
                    dueDate: dueDate,
                    frequency: recurrenceFrequency
                ) {
                    // "添加钟点":首次按下时把钟点设为当前时刻,避免显示 startOfDay 的 00:00。
                    Button {
                        let calendar = Calendar.current
                        let now = Date()
                        var components = calendar.dateComponents([.year, .month, .day], from: dueDate ?? now)
                        components.hour = calendar.component(.hour, from: now)
                        components.minute = calendar.component(.minute, from: now)
                        dueDate = calendar.date(from: components)
                        hasDueTime = true
                        onEdit()
                    } label: {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                            Text(String(localized: "detail.add_time"))
                                .font(WarmFont.body(15))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .layoutPriority(1)
                        }
                        .foregroundColor(WarmTheme.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DetailAddTimeButton")
                }

                TodoTimeBucketChipRow(selection: $timeBucket, onEdit: onEdit)
            }
        }
    }
}
