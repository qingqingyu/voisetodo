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

/// 钟点 popover 入口文本 formatter(跟随系统 locale,12/24h 制由系统决定)。
/// 与 `todoFieldEditorDateFormatter` 同样的 file-private 顶层套路,供 `TodoTimePopoverTrigger` 使用。
private let todoFieldEditorTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

/// 字段编辑器的视觉上下文。默认值保持详情页现有样式，确认页仅切换外观，
/// 不改变任何 Binding、回调或字段写回行为。
enum TodoFieldEditorAppearance {
    case standard
    case confirmation
}

/// 确认页编辑面板专用的清新配色。
/// 青绿负责“正在整理 / 已选中”的积极反馈，暖色只留给高优先级等提醒语义。
enum ConfirmEditorTheme {
    static let accent = Color(light: "16785F", dark: "70DEBA")
    static let accentFill = Color(light: "17866A", dark: "58D4AC")
    static let selectedText = Color(light: "FFFFFF", dark: "102B24")
    static let accentSurface = Color(light: "EFF9F5", dark: "20352F")
    static let neutralSurface = Color(light: "F4F7F8", dark: "2B3033")
    static let warmSurface = Color(light: "FFF6F1", dark: "392D29")
    static let raisedSurface = Color(light: "FFFFFF", dark: "30443E")
    static let lowFill = Color(light: "647184", dark: "A9B5C5")
    static let lowSelectedText = Color(light: "FFFFFF", dark: "1E2A3A")
    static let categorySelectedText = Color(light: "172536", dark: "FFFFFF")
}

// MARK: - 分类网格

/// 分类选择网格(自适应 LazyVGrid,7 个分类按屏宽换行)。
///
/// 从 `TodoDetailView.categoryChip` + body 的 `LazyVGrid` 抽出。
/// 纯 UI + Binding,不含标题 Text 与 detailCard 外壳 —— 调用方自行包裹。
/// 视觉与 a11y 与原详情页逐项一致。
struct TodoCategoryGrid: View {
    @Binding private var selection: TodoCategory
    private let onEdit: () -> Void
    private let appearance: TodoFieldEditorAppearance

    init(
        selection: Binding<TodoCategory>,
        appearance: TodoFieldEditorAppearance = .standard,
        onEdit: @escaping () -> Void
    ) {
        self._selection = selection
        self.appearance = appearance
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
                // .system 而非 WarmFont(Avenir Next 无中文字形,中文回退苹方造成混排基线不一致)。
                // 编辑面板以中文为主,统一走 iOS 系统字体让中文走苹方、英文数字走系统匹配。
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .foregroundColor(categoryForeground(isSelected: isSelected))
                .background(
                    RoundedRectangle(cornerRadius: categoryCornerRadius)
                        .fill(categoryBackground(category, isSelected: isSelected))
                )
                .overlay {
                    if appearance == .standard {
                        RoundedRectangle(cornerRadius: WarmRadius.chip)
                            .strokeBorder(
                                isSelected ? WarmTheme.primaryText : WarmTheme.sketch.opacity(0.4),
                                lineWidth: 1
                            )
                    }
                }
                .shadow(
                    color: appearance == .confirmation && isSelected
                        ? WarmTheme.color(for: category).opacity(0.22)
                        : .clear,
                    radius: 5,
                    y: 2
                )
        }
        .buttonStyle(.plain)
    }

    private var categoryCornerRadius: CGFloat {
        appearance == .confirmation ? WarmRadius.segmentedTrack : WarmRadius.chip
    }

    private func categoryForeground(isSelected: Bool) -> Color {
        guard appearance == .confirmation else {
            return isSelected ? WarmTheme.primaryText : WarmTheme.textSecondary
        }
        return isSelected ? ConfirmEditorTheme.categorySelectedText : WarmTheme.textSecondary
    }

    private func categoryBackground(_ category: TodoCategory, isSelected: Bool) -> Color {
        guard appearance == .confirmation else {
            return isSelected ? WarmTheme.primary.opacity(0.12) : .clear
        }
        return isSelected
            ? WarmTheme.color(for: category)
            : WarmTheme.color(for: category).opacity(0.10)
    }
}

// MARK: - 优先级选择器

/// 优先级三档选择器(HStack:低/普通/高)。
///
/// 从 `TodoDetailView.priorityButton` + `priorityButtonBackground` + body 的 `HStack` 抽出。
///
/// 视觉重设计(2026-08):去实心色块,改"浅底 + 深字 + 图标"。
/// - High 选中:浅红底 + urgentText 深红字 + `!`
/// - Normal 选中:浅橙底 + primaryText 深橙字 + `−`
/// - Low 选中:浅灰底 + textSecondary 灰字 + `↓`(low 不强调,跟未选近似)
/// - 未选:Color.clear 透明底 + sketch 浅墨描边 + textMuted
/// 理由:实心色块(尤其红色 high)会跟主操作按钮(实心橙)抢焦点;
/// 浅底方案让「优先级 = 状态指示」跟「主操作 = 实心橙」视觉层级分开,
/// 而且不只靠颜色——图标(! / − / ↓)承担主要语义。
struct TodoPriorityPicker: View {
    @Binding private var selection: Priority
    private let onEdit: () -> Void
    private let appearance: TodoFieldEditorAppearance

    init(
        selection: Binding<Priority>,
        appearance: TodoFieldEditorAppearance = .standard,
        onEdit: @escaping () -> Void
    ) {
        self._selection = selection
        self.appearance = appearance
        self.onEdit = onEdit
    }

    var body: some View {
        // spacing 用 sm(12):优先级是独立按钮组(各自底色填充),段间留明显缝;
        // 区别于时间 segmented 的 xxs(4)——后者靠轨道容器统一,段本身不需要大缝。
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
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WarmSpacing.sm)
            .background(background(isSelected: isSelected, priority: priority))
            .overlay {
                if appearance == .standard {
                    RoundedRectangle(cornerRadius: WarmRadius.chip)
                        .strokeBorder(
                            borderColor(isSelected: isSelected, priority: priority),
                            lineWidth: 1
                        )
                }
            }
            .foregroundColor(foregroundLabel(isSelected: isSelected, priority: priority))
            .shadow(
                color: appearance == .confirmation && isSelected
                    ? selectedFill(priority).opacity(0.20)
                    : .clear,
                radius: 5,
                y: 2
            )
        }
        .buttonStyle(.plain)
    }

    /// 选中/未选的背景色:浅底 + 深字方案(替代原实心)。
    /// 未选态不再用 subtleControlBackground 灰填充(在白卡上"显浑")→ 改成 Color.clear,
    /// 描边在 button 的 overlay 层处理。low 选中保留 subtleControlBackground 浅底:
    /// 让 low 至少有一点视觉差异(否则跟未选完全一样,反馈太弱)。
    @ViewBuilder
    private func background(isSelected: Bool, priority: Priority) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: appearance == .confirmation ? WarmRadius.segmentedTrack : WarmRadius.chip
        )
        if appearance == .confirmation {
            shape.fill(isSelected ? selectedFill(priority) : ConfirmEditorTheme.neutralSurface)
        } else if isSelected {
            switch priority {
            case .high:
                shape.fill(WarmTheme.urgent.opacity(0.12))
            case .normal:
                shape.fill(WarmTheme.primary.opacity(0.12))
            case .low:
                shape.fill(WarmTheme.subtleControlBackground)
            }
        } else {
            shape.fill(Color.clear)
        }
    }

    /// 描边色:未选 = sketch 浅墨(0.4 opacity);选中 = 同色系深字色。
    private func borderColor(isSelected: Bool, priority: Priority) -> Color {
        if isSelected {
            switch priority {
            case .high:   return WarmTheme.urgentText
            case .normal: return WarmTheme.primaryText
            case .low:    return WarmTheme.sketch.opacity(0.5)
            }
        } else {
            return WarmTheme.sketch.opacity(0.4)
        }
    }

    /// 选中/未选的字色:浅底配深字,提升可读对比度。
    private func foregroundLabel(isSelected: Bool, priority: Priority) -> Color {
        if appearance == .confirmation {
            guard isSelected else { return WarmTheme.textSecondary }
            switch priority {
            case .low: return ConfirmEditorTheme.lowSelectedText
            case .normal: return ConfirmEditorTheme.selectedText
            case .high: return .white
            }
        }
        if isSelected {
            switch priority {
            case .high:   return WarmTheme.urgentText
            case .normal: return WarmTheme.primaryText
            case .low:    return WarmTheme.textSecondary
            }
        } else {
            return WarmTheme.textMuted
        }
    }

    private func selectedFill(_ priority: Priority) -> Color {
        switch priority {
        case .low: return ConfirmEditorTheme.lowFill
        case .normal: return ConfirmEditorTheme.accentFill
        case .high: return WarmTheme.urgent
        }
    }
}

// MARK: - 时段 segmented control

/// 模糊时段 segmented control(等宽四段:随时 / 上午 / 下午 / 晚上)。
///
/// 替代原 chips 形态——区分控件语义:时段是互斥切换 → segmented;
/// 分类是标签选择 → chips(见 TodoCategoryGrid)。两组成色不同,避免误判同组。
///
/// 选中态刻意轻:浅橙底 + 橙字(用 primary.opacity(0.15),不实心),
/// 因为"选时段"不是最终提交动作,不应抢主操作视觉重量。
/// `.anytime` 选中时写回 nil(与原 timeBucketButton 语义一致)。
struct TodoTimeBucketSegmented: View {
    @Binding private var selection: TimeBucket?
    private let onEdit: () -> Void
    private let appearance: TodoFieldEditorAppearance

    init(
        selection: Binding<TimeBucket?>,
        appearance: TodoFieldEditorAppearance = .standard,
        onEdit: @escaping () -> Void
    ) {
        self._selection = selection
        self.appearance = appearance
        self.onEdit = onEdit
    }

    var body: some View {
        // spacing 用 xxs(4):段间留缝,让选中段的圆角(segmentedThumb=7)完整呈现,
        // 不被相邻未选段的 clear 背景切平成"压扁的圆角"。
        HStack(spacing: WarmSpacing.xxs) {
            ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                segment(bucket)
            }
        }
        // segmented 轨道:无填充 + 1pt sketch 描边 + 圆角 segmentedTrack(10)。
        // 历史:原 subtleControlBackground 灰底在白卡上"显浑"(用户反馈"脏")→ 改成
        // 透明底 + 描边,视觉密度立刻降一档。选中段在 segment 内自带浅橙底,边界仍清晰,
        // 轨道只需勾形状不必铺色。
        // padding 用 xs(8):外圆角 segmentedTrack(10) - 内圆角 segmentedThumb(7) = 3,
        // padding 必须 ≥ 差值才不切角,留 8 给 anti-aliasing 缓冲。
        // confirmation 模式轨道自带 raisedSurface 填充,内段间距收到 xxs(4)。
        .padding(appearance == .confirmation ? WarmSpacing.xxs : WarmSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.segmentedTrack)
                .fill(appearance == .confirmation ? ConfirmEditorTheme.raisedSurface : Color.clear)
        )
        .overlay {
            if appearance == .standard {
                RoundedRectangle(cornerRadius: WarmRadius.segmentedTrack)
                    .strokeBorder(WarmTheme.sketch.opacity(0.4), lineWidth: 1)
            }
        }
    }

    private func segment(_ bucket: TimeBucket) -> some View {
        let selectedBucket = selection ?? .anytime
        let isSelected = selectedBucket == bucket
        return Button {
            withAnimation(WarmAnimation.springFast) {
                selection = bucket == .anytime ? nil : bucket
                onEdit()
            }
        } label: {
            Text(bucket.localizedTitle)
                .font(.system(size: 14, weight: .medium))
                // standard 选中用 primaryText(深橙),confirmation 选中用 selectedText(白/深青)
                .foregroundColor(timeBucketForeground(isSelected: isSelected))
                .lineLimit(1)
                // 0.7 而非 0.8:en locale "Evening" 7 字符在 AX5 下 ×2~3 字号,
                // 等宽段内 0.8 缩放仍可能溢出,放宽到 MEMORY 规则下限 0.7。
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                .padding(.vertical, WarmSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.segmentedThumb)
                        .fill(timeBucketBackground(isSelected: isSelected))
                )
                .shadow(
                    color: appearance == .confirmation && isSelected
                        ? ConfirmEditorTheme.accentFill.opacity(0.18)
                        : .clear,
                    radius: 4,
                    y: 2
                )
        }
        .buttonStyle(.plain)
    }

    private func timeBucketForeground(isSelected: Bool) -> Color {
        guard appearance == .confirmation else {
            return isSelected ? WarmTheme.primaryText : WarmTheme.textSecondary
        }
        return isSelected ? ConfirmEditorTheme.selectedText : WarmTheme.textSecondary
    }

    private func timeBucketBackground(isSelected: Bool) -> Color {
        guard appearance == .confirmation else {
            return isSelected ? WarmTheme.primary.opacity(0.12) : .clear
        }
        return isSelected ? ConfirmEditorTheme.accentFill : .clear
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
    /// 外部覆盖的 a11y label(组件已 `.accessibilityElement(children: .ignore)` 合并成单 element,
    /// label 必须在内部设置才生效;外层再贴 `.accessibilityLabel` 会被 ignore 子树挡住不朗读)。
    /// nil 时默认"detail.time"(Time 卡片场景);detail EndDate 场景传"recurrence.end_date.label"。
    private let accessibilityLabelOverride: String?

    @State private var showDatePickerPopover = false
    @State private var popoverFallbackAnchor: Date?
    @State private var popoverDismissTask: Task<Void, Never>?
    @State private var selectionFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    init(date: Binding<Date?>, accessibilityLabel: String? = nil, onEdit: @escaping () -> Void) {
        self._date = date
        self.accessibilityLabelOverride = accessibilityLabel
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
                    .font(.system(size: 15, weight: .medium))
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
        .accessibilityLabel(accessibilityLabelOverride ?? String(localized: "detail.time"))
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

// MARK: - 钟点 popover 触发器

/// 钟点触发器(与 `TodoDatePopoverTrigger` 对称的 popover + .wheel 方案)。
///
/// 替代原 `TodoClockTimeRow.hasDueTime == true` 分支里内联的 `DatePicker.compact` ——
/// `.compact` 在 iPhone 上点击后内联展开成滚轮,SwiftUI 不给"折叠"钩子,只能靠点外面收
/// (用户报告的 bug:选好时间后没有"完成"按钮,也不自动关闭,行为跟日期 popover 不一致)。
/// 这里改成自控 popover:文本按钮显示当前钟点 + chevron.down,点击弹 `.wheel` 滚轮,
/// 滚轮最后一次变动后 ~0.8s 自动收起(留出连续滚动窗口,避免边滚边关),
/// 与日期 popover 的"选好即收"行为对齐。
///
/// 不变式:`hasDueTime == true ⇒ dueDate != nil`(`TodoClockTimeRow` 的"添加钟点"按钮保证),
/// 但 binding 仍以 `Date?` 入参,防御性处理 nil —— 显示用 anchor 兜底,写回时合并到 anchor 的日期部分。
///
/// **为什么需要 `popoverFallbackAnchor`**:与 `TodoDatePopoverTrigger` 同一原因 ——
/// SwiftUI 在 popover 打开期间可能反复重建 body,每次 `Date()` 都重新求值。
/// 时间场景下虽然只取 hour/minute,但 set 分支要拿"日期部分"做合并(nil 路径下),
/// 若不锚定,跨午夜停留 popover 时 anchor 会从打开那一天漂到次日,合并出错误的年月日。
struct TodoTimePopoverTrigger: View {
    @Binding private var date: Date?
    private let onEdit: () -> Void

    @State private var showTimePickerPopover = false
    /// 打开 popover 瞬间捕获的 nil 兜底锚点(只在 date == nil 时生效)。
    /// 一旦捕获不再更新,避免 body 重建时反复 `Date()` 求值导致跨午夜漂移。
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
            // 打开瞬间捕获回退锚点:之后 nil 路径下的兜底都用这一份稳定值,
            // 避免 SwiftUI body 重建时反复调 Date() 导致跨午夜漂移到次日。
            if popoverFallbackAnchor == nil {
                popoverFallbackAnchor = Date()
            }
            showTimePickerPopover = true
        } label: {
            HStack(spacing: WarmSpacing.xxs) {
                Text(todoFieldEditorTimeFormatter.string(from: anchorDate))
                    .font(.system(size: 15, weight: .medium))
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
        .accessibilityLabel(String(localized: "detail.clock_time"))
        .accessibilityValue(todoFieldEditorTimeFormatter.string(from: anchorDate))
        .accessibilityIdentifier("DetailTimePopoverTrigger")
        .popover(isPresented: $showTimePickerPopover) {
            VStack(spacing: WarmSpacing.sm) {
                DatePicker(
                    "",
                    selection: popoverBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
            }
            .padding(WarmSpacing.md)
            .frame(width: 280)
            .onAppear {
                // 预热 haptic engine —— 首次 impactOccurred() 才不会因 engine 冷启动延迟/丢失。
                selectionFeedbackGenerator.prepare()
            }
        }
        .onDisappear {
            // 钟点 popover 自动收起 task 一并 cancel —— 组件已退出,防止 task 在 dismiss 后
            // 仍触发 showTimePickerPopover 写入(虽无害,但状态干净更可预测)。
            // 与 TodoDatePopoverTrigger.onDisappear 行为对齐。
            popoverDismissTask?.cancel()
            popoverDismissTask = nil
        }
    }

    /// nil 兜底锚点:date 优先,fallback 到 popover 打开时捕获的 anchor,再兜到当下。
    /// 三段式与 `TodoDatePopoverTrigger.anchorDate` 同构(那边多包一层 `DayClock.startOfUserDay`,
    /// 这里不需要 —— 时间场景只关心 hour/minute,日起点偏移不影响显示)。
    private var anchorDate: Date {
        date ?? popoverFallbackAnchor ?? Date()
    }

    /// 钟点 popover 内 DatePicker 的双向绑定。setter 四件事:
    /// 1) 取 wheel 给的 newTime 的 hour/minute,合并到现有 date 的年月日(没有则用 anchor 的日期);
    /// 2) onEdit 上报;3) 触觉反馈;4) schedulePopoverDismiss。
    ///
    /// **为什么合并日期而不是直接写 newTime**:wheel 给的 newTime 是完整 Date(以"现在"为基准),
    /// 直接写回会让 dueDate 的年月日被今天的日期覆盖,跟用户原本选的"哪一天 什么时间"语义打架。
    private var popoverBinding: Binding<Date> {
        Binding(
            get: { anchorDate },
            set: { newTime in
                let calendar = Calendar.current
                var components = calendar.dateComponents([.year, .month, .day], from: anchorDate)
                components.hour = calendar.component(.hour, from: newTime)
                components.minute = calendar.component(.minute, from: newTime)
                date = calendar.date(from: components)
                onEdit()
                selectionFeedbackGenerator.impactOccurred()
                selectionFeedbackGenerator.prepare()
                schedulePopoverDismiss()
            }
        )
    }

    /// 滚轮最后一次变动后 ~0.8s 收起 popover。
    ///
    /// **为什么 800ms 而非日期的 180ms**:日期 `.graphical` 是离散点击,180ms 足够;
    /// 滚轮是连续滑动,用户可能边滚边停顿看,800ms 才能确认"真停下了",避免边滚边关。
    /// 用 Task 而非 DispatchQueue.main.asyncAfter —— 可取消:连续滚动时 cancel 上一次。
    private func schedulePopoverDismiss() {
        popoverDismissTask?.cancel()
        popoverDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showTimePickerPopover = false
            }
        }
    }
}

// MARK: - 钟点 + 时段行

/// 钟点 + 时段合并行。
///
/// 从 `TodoDetailView.timeSection` 抽出。两种状态由 `hasDueTime` 决定:
/// - hasDueTime=true:钟点 DatePicker + 派生 TimeBucket 只读 + 清除钟点按钮
/// - hasDueTime=false:「添加钟点」按钮(canAddClockTime 守门)+ 时段 segmented(复用 TodoTimeBucketSegmented)
///
/// 不变式:hasDueTime == true ⇒ dueDate != nil —— UI 侧维持。
/// a11y id `DetailAddTimeButton` 保留。
struct TodoClockTimeRow: View {
    @Binding private var dueDate: Date?
    @Binding private var hasDueTime: Bool
    @Binding private var timeBucket: TimeBucket?
    private let recurrenceFrequency: RecurrenceFrequency?
    private let onEdit: () -> Void
    private let appearance: TodoFieldEditorAppearance

    init(
        dueDate: Binding<Date?>,
        hasDueTime: Binding<Bool>,
        timeBucket: Binding<TimeBucket?>,
        recurrenceFrequency: RecurrenceFrequency?,
        appearance: TodoFieldEditorAppearance = .standard,
        onEdit: @escaping () -> Void
    ) {
        self._dueDate = dueDate
        self._hasDueTime = hasDueTime
        self._timeBucket = timeBucket
        self.recurrenceFrequency = recurrenceFrequency
        self.appearance = appearance
        self.onEdit = onEdit
    }

    var body: some View {
        if hasDueTime {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                HStack {
                    // 钟点编辑入口:popover + .wheel + 800ms 自动收起(替代原内联 .compact)。
                    // 原 .compact 在 iPhone 上点击后内联展开成滚轮,SwiftUI 不给"折叠"钩子,
                    // 用户必须点外面才能收 —— 跟日期 popover 的"选好即收"不一致。
                    TodoTimePopoverTrigger(date: $dueDate, onEdit: onEdit)

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
                    .font(.system(size: 12))
                    .foregroundColor(
                        appearance == .confirmation ? ConfirmEditorTheme.accent : WarmTheme.textMuted
                    )
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
                                // 14pt(比"添加日期"15pt 小一级):钟点是次要操作,
                                // 日期是主操作 —— 字号差承担主次表达。
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .layoutPriority(1)
                        }
                        // primaryText 深橙(浅底文字对比度优于直接 primary)
                        .foregroundColor(
                            appearance == .confirmation ? ConfirmEditorTheme.accent : WarmTheme.primaryText
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DetailAddTimeButton")
                }

                TodoTimeBucketSegmented(
                    selection: $timeBucket,
                    appearance: appearance,
                    onEdit: onEdit
                )
            }
        }
    }
}

// MARK: - 提醒提前量档位

/// 提前量档位共享表:详情页/确认页 `TodoReminderOffsetRow` 与设置页「默认提前提醒」
/// Picker 共用同一份档位与文案。数组顺序即菜单顺序;nil = 准时。
/// 自定义分钟数刻意不做(YAGNI)。
enum ReminderOffsetPresetOptions {
    /// 档位表:nil = 准时。
    static let presets: [Int?] = [nil, 5, 15, 30, 60, ReminderOffsetConfig.maxMinutes]

    /// 档位显示文本。60/1440 用整段文案(不是"提前 60 分钟"),跟 iOS 系统提醒事项口径一致。
    static func label(for preset: Int?) -> String {
        switch preset {
        case nil:
            return String(localized: "reminder.on_time")
        case 60:
            return String(localized: "reminder.hour_ahead")
        case ReminderOffsetConfig.maxMinutes:
            return String(localized: "reminder.day_ahead")
        case let minutes?:
            return String.localizedStringWithFormat(
                String(localized: "reminder.minutes_ahead"), minutes
            )
        }
    }

    // MARK: Int 存储互转(@AppStorage 存不了 nil):0 = 准时,其余 = 提前分钟数。

    static func rawValue(for preset: Int?) -> Int { preset ?? 0 }
}

/// 单条待办的提醒提前量选择行(Menu 档位制)。调用方只在待办**带钟点**时渲染。
///
/// 档位:准时(nil) / 提前 5、15、30、60 分钟 / 提前 1 天(1440),见 `ReminderOffsetPresetOptions`。
/// 绑定值语义与 `reminderOffsetMinutes` 字段一致(nil = 准时)。
/// 样式对齐 `TodoClockTimeRow` 的"添加钟点"行(13pt 图标 + 14pt 文本,字号差承担主次),
/// appearance 切换详情页 / 确认页配色。
struct TodoReminderOffsetRow: View {
    @Binding private var offsetMinutes: Int?
    private let appearance: TodoFieldEditorAppearance
    private let onEdit: () -> Void

    init(
        offsetMinutes: Binding<Int?>,
        appearance: TodoFieldEditorAppearance = .standard,
        onEdit: @escaping () -> Void
    ) {
        self._offsetMinutes = offsetMinutes
        self.appearance = appearance
        self.onEdit = onEdit
    }

    var body: some View {
        HStack(spacing: WarmSpacing.xxs) {
            Image(systemName: "bell")
                .font(.system(size: 13))

            Text(String(localized: "detail.reminder.label"))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Spacer(minLength: WarmSpacing.xs)

            Menu {
                ForEach(ReminderOffsetPresetOptions.presets, id: \.self) { preset in
                    Button {
                        offsetMinutes = preset
                        onEdit()
                    } label: {
                        if preset == offsetMinutes {
                            Label(ReminderOffsetPresetOptions.label(for: preset), systemImage: "checkmark")
                        } else {
                            Text(ReminderOffsetPresetOptions.label(for: preset))
                        }
                    }
                }
            } label: {
                Text(ReminderOffsetPresetOptions.label(for: offsetMinutes))
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityIdentifier("DetailReminderOffsetMenu")
        }
        .foregroundColor(
            appearance == .confirmation ? ConfirmEditorTheme.accent : WarmTheme.primaryText
        )
    }
}
