import SwiftUI

enum VoiceOverLabel {
    private static let gregorian = Calendar(identifier: .gregorian)

    static func build(for dayState: HomeCalendarDayState) -> String {
        var parts = [
            monthDayText(for: dayState.date),
            weekdayText(for: dayState.date)
        ]

        // 状态在后
        if !dayState.isCurrentMonth {
            parts.append(String(localized: "a11y.day.out_of_month"))
        }
        if dayState.isToday {
            parts.append(String(localized: "a11y.day.today"))
        }
        // 单次 reduce 同时累计总数和规律数,避免对 occurrences 数组做两次扫描。
        // 日级数据通常很小(≤10),这是预防性的——避免将来单日批量导入时退化。
        // 具名元组标签让闭包内访问可读 acc.count / acc.recurring 而非 acc.0 / acc.1。
        let (count, recurringCount) = dayState.occurrences.reduce(into: (count: 0, recurring: 0)) { acc, occ in
            acc.count += 1
            if occ.isRecurring { acc.recurring += 1 }
        }
        if count > 0 {
            parts.append(String(format: String(localized: "a11y.day.todo_count"), count))
            // 视觉上空心环已区分规律任务,VoiceOver 用文字补全——低视力用户看不到形态差异。
            // 给出规律任务的具体数量,避免混合日(部分规律 + 部分单次)语义丢失:
            // "5 项待办,其中 2 项规律"比"5 项待办,含规律任务"更精准。
            if recurringCount > 0 {
                parts.append(String(format: String(localized: "a11y.day.has_recurring_count"), recurringCount))
            }
        } else {
            parts.append(String(localized: "a11y.day.no_todo"))
        }
        return parts.joined(separator: String(localized: "a11y.day.separator"))
    }

    private static func monthDayText(for date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day()
        style.calendar = gregorian
        style.locale = appLocale
        return date.formatted(style)
    }

    private static func weekdayText(for date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.calendar = gregorian
        style.locale = appLocale
        return date.formatted(style)
    }

    private static var appLocale: Locale {
        guard let identifier = Bundle.main.preferredLocalizations.first(where: { $0 != "Base" }) else {
            return .current
        }
        return Locale(identifier: identifier)
    }
}


/// 截止状态尾标的展示策略。
enum DueStatusDisplayMode {
    /// 显示全部状态（overdue / today / tomorrow / 具体日期）。
    case full
    /// 只显示 `.overdue`，其余返回 nil。用于按天分组的列表——日期已由分区头给出，
    /// 挂 "Today" 是冗余，只有"过期"才补充信息。
    case overdueOnly
}

struct WarmTodoCard: View {
    let index: Int
    let todo: TodoItemData
    let onToggle: () -> Void
    /// 长按 context menu:移到指定 bucket。nil 时不挂 contextMenu(向后兼容)。
    var onMoveToBucket: ((TimeBucket) -> Void)? = nil
    /// 长按 context menu:移到明天。nil 时不显示「移到明天」项。
    var onMoveToTomorrow: (() -> Void)? = nil
    /// 时间 chip 点击入口 + popover 提交处理。nil 时 chip 不可点(纯展示,无 dot)。
    /// 接入方:HomeSelectedDayListView 注入 `onChangeTime`,chip 变成可点 button,
    /// 弹出 `TimeEditPopover`,提交时把新钟点回传调用方写库
    /// (popover 只改钟点 → 恒为 hasDueTime=true / timeBucket=nil,所以签名收敛为 `(Date) -> Void`)。
    var onChangeTime: ((Date) -> Void)? = nil
    var showsTimeBucketMetadata = true
    var dueStatusDisplayMode: DueStatusDisplayMode = .full
    /// 标题行是否内联钟点前缀（"09:00 吃药"）。默认 false——
    /// 只有明确把外层时间标签删掉的调用方（HomeSelectedDayListView）才打开，
    /// 避免 UnscheduledDrawer 等其它调用方被动改变外观。
    var showsInlineTimePrefix = false
    /// 是否自带白色圆角卡片底。默认 true（`UnscheduledDrawer` 里每条仍是独立卡片）。
    /// Today 列表传 false —— 那里整个分区合成一张卡，底色与圆角由
    /// `groupedCardRow` 在 List 的 `listRowBackground` 上统一画，
    /// 每行再自带一个白底会在行接缝处叠出边框。
    var showsCardBackground = true

    /// 改时间 popover 状态。chip 点击触发,popover 内部提交时通过 `onChangeTime` 回调。
    /// 编辑中的 date 由 chip 点击时的 `todo.dueDate ?? Date()` 初始化。
    @State private var showTimeEditor = false
    @State private var editingDate: Date = Date()

    private var categoryColor: Color {
        WarmTheme.color(for: todo.category)
    }

    /// 标题行内联钟点串：showsInlineTimePrefix=true 且 hasDueTime=true 时返回 "HH:mm"。
    /// 不看 isCompleted——已完成的卡片也保留时间前缀（与旧外置时间标签行为一致）。
    /// 钟点串不进 composedTimeText（避免与标题行重复），第二行只负责 recurrence / bucket / hint。
    private var inlineTimeText: String? {
        guard showsInlineTimePrefix, todo.hasDueTime, let dueDate = todo.dueDate else { return nil }
        return Self.timeFormatter.string(from: dueDate)
    }

    /// 合并剩余时间元数据成单行（用于第 2 行展示）。
    /// 拼装规则抽到了 `TodoTimeDisplayComposer`（与 ConfirmSheet 共用），
    /// 这里只负责"从 TodoItemData 模型字段取出结构化时间"——
    /// 注意钟点已由 inlineTimeText 在标题行展示，这里传 nil 避免重复。
    /// completed 状态下：默认调用方（UnscheduledDrawer 等）保持旧行为不显示第二行；
    /// 只有 showsInlineTimePrefix=true 的调用方（HomeSelectedDayListView）才保留
    /// recurrence / bucket —— 因为这些卡片不再有外层时间标签，需要补全规律语义。
    private var composedTimeText: String? {
        Self.composedTimeText(
            todo: todo,
            showsTimeBucketMetadata: showsTimeBucketMetadata,
            showsInlineTimePrefix: showsInlineTimePrefix
        )
    }

    /// `composedTimeText` 的 static 版本。抽出来是给分组卡片的调用方用的:
    /// Today 列表要在**构造卡片之前**知道这张卡会不会有第二行,好决定行高档位
    /// （56 单行 / 76 带副行，见 `WarmSize.rowCompact` / `rowTall`）。
    /// 与实例属性同源，避免"要不要给 76pt"和"实际渲不渲染第二行"两处判断分叉。
    static func composedTimeText(
        todo: TodoItemData,
        showsTimeBucketMetadata: Bool,
        showsInlineTimePrefix: Bool
    ) -> String? {
        if todo.isCompleted, !showsInlineTimePrefix { return nil }
        return TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: nil,
            dueHint: todo.dueDate == nil ? todo.dueHint : nil,
            timeBucketText: timeBucketText(todo: todo, showsTimeBucketMetadata: showsTimeBucketMetadata)
        )
    }

    /// 这张卡会不会渲染第二行元数据 —— 分组卡片据此在 56 / 76 两档行高之间选一档。
    static func hasMetadataLine(
        todo: TodoItemData,
        showsTimeBucketMetadata: Bool,
        showsInlineTimePrefix: Bool
    ) -> Bool {
        composedTimeText(
            todo: todo,
            showsTimeBucketMetadata: showsTimeBucketMetadata,
            showsInlineTimePrefix: showsInlineTimePrefix
        ) != nil
    }

    private var timeBucketText: String? {
        Self.timeBucketText(todo: todo, showsTimeBucketMetadata: showsTimeBucketMetadata)
    }

    private static func timeBucketText(todo: TodoItemData, showsTimeBucketMetadata: Bool) -> String? {
        guard showsTimeBucketMetadata, !todo.hasDueTime else {
            return nil
        }
        let bucket = TimeBucketResolver.effective(
            explicitBucket: todo.timeBucket,
            dueDate: todo.dueDate,
            hasDueTime: todo.hasDueTime
        )
        return bucket == .anytime ? nil : bucket.localizedTitle
    }

    private var dueStatus: TodoDueStatus? {
        let status = RelativeDueLabel.status(
            dueDate: todo.dueDate,
            isCompleted: todo.isCompleted,
            recurrenceRule: todo.recurrenceRule,
            hasDueTime: todo.hasDueTime
        )
        // overdueOnly：按天分组的列表里只保留"过期"，其余日期状态由分区头承担。
        if dueStatusDisplayMode == .overdueOnly {
            if case .overdue = status { return status }
            return nil
        }
        return status
    }

    private var dueStatusText: String? {
        switch dueStatus {
        case .overdue:
            return String(localized: "due.overdue")
        case .today:
            return String(localized: "due.today")
        case .tomorrow:
            return String(localized: "due.tomorrow")
        case .future(let date):
            return date.formatted(.dateTime.month().day())
        case nil:
            return nil
        }
    }

    private var dueStatusColor: Color {
        switch dueStatus {
        case .overdue:
            return WarmTheme.urgent
        case .today:
            return WarmTheme.warningText
        case .tomorrow, .future, nil:
            return WarmTheme.textSecondary
        }
    }

    private var isOverdue: Bool {
        if case .overdue = dueStatus {
            return true
        }
        return false
    }

    /// "HH:mm"（24 小时制）格式化器——与 ExtractedTodo.dueTime 原始格式一致，
    /// 这样 HomeView 与 ConfirmSheet 显示的钟点串能保持一致。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        // alignment: .center:checkbox 垂直居中对齐整个 VStack(标题行+元数据行),
        // 用户 2026-07-25 真机反馈:checkbox 跟第一行字顶对齐时,卡片有元数据第二行
        // 会拉高 VStack,checkbox 视觉上贴在卡片偏上 1/3 处显得「没对齐」。
        // 改成 .center 让 checkbox 始终坐卡片纵向中点,与「视觉居中」预期一致。
        HStack(alignment: .center, spacing: WarmSpacing.sm) {
            // 砍掉左侧色条——P2 修复：原色条 + 圆圈 checkbox 双重标记冗余。
            // 现在只用圆圈 checkbox 按 category 上色，更接近 Things 3 的极简做法。
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(
                            todo.isCompleted ? WarmTheme.success : WarmTheme.sketch,
                            lineWidth: 2
                        )
                        .frame(width: WarmSize.icon - 4, height: WarmSize.icon - 4)

                    Circle()
                        .fill(WarmTheme.success)
                        .frame(width: WarmSize.icon - 4, height: WarmSize.icon - 4)
                        .opacity(todo.isCompleted ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: todo.isCompleted)

                    WarmCheckmarkShape()
                        .trim(from: 0, to: todo.isCompleted ? 1 : 0)
                        .stroke(
                            .white,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: WarmSize.icon - 10, height: WarmSize.icon - 10)
                        .animation(.easeInOut(duration: 0.3), value: todo.isCompleted)
                }
                // alignment: .center 让 24pt 圆环居 44pt frame 中央,配合外层 HStack(.center)
                // 实现勾选框在卡片垂直居中。44pt frame 仍保留以撑大 hit target 到 HIG 标准,
                // 避免 checkbox 视觉圆环 24pt 命中区过小。
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TodoCheckbox_\(index)")
            .accessibilityLabel(todo.isCompleted ? String(localized: "a11y.completed") : String(localized: "a11y.not_completed"))
            .accessibilityHint({
                let action = todo.isCompleted
                    ? String(localized: "a11y.mark_incomplete")
                    : String(localized: "a11y.mark_complete")
                return String(localized: "a11y.toggle_complete \(action)")
            }())

            // 内容区：2 行布局（标题 + 元数据合并行）。
            // P1 修复：原来 3 行（title / dueHint / recurrence）挤压左侧 40%，
            // 现在元数据合并成一行，卡片高度降三分之一。
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                HStack(spacing: WarmSpacing.xxs) {
                    CategoryIconView(category: todo.category, isCompleted: todo.isCompleted)

                    // 标题行内联钟点:hasDueTime 时在 title 前挂 chip(HTML 设计稿 .chip 样式)。
                    // solid 样式 = 精确时刻(彩色底 + 分类色),最强视觉权重;
                    // 调用方注入 `onEditTime` 时 chip 变成可点 button(末尾 5pt dot 暗示),
                    // 弹改时间 popover;nil 时纯展示不可点。
                    // 已完成时降级到 textSecondary(灰)。
                    if let inlineTime = inlineTimeText {
                        ChipView(
                            text: inlineTime,
                            style: .solid,
                            accent: todo.isCompleted ? WarmTheme.textSecondary : categoryColor,
                            onTap: onChangeTime != nil ? { startEditingTime() } : nil,
                            accessibilityHintText: String(localized: "a11y.chip.time_edit_hint")
                        )
                    }

                    Text(todo.title)
                        .font(todo.priority == .high ? WarmFont.headline(15) : WarmFont.body(15))
                        .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : WarmTheme.textPrimary)
                        .strikethrough(todo.isCompleted, color: WarmTheme.textSecondary)
                        // 主内容不允许截断:长标题(尤其英文)靠自然换行 + 卡片高度自适应承接,
                        // 卡片在 List 中可滚动。详见 feedback memory「文本截断/换行零容忍」
                        // 用户内容分场景策略。
                }
                .accessibilityElement(children: .combine)

                // 元数据合并行：clock + composedTimeText 一行展示。
                // P3 修复：原 recurrence 用 primaryDark 红色（与 urgent 警告冲突），
                // 改为 textSecondary 灰色（与 ConfirmSheet 时间行一致）；字号继续下压到 10pt 进一步压低视觉权重。
                // composedTimeText 可能很长(TodoTimeDisplayComposer 会拼出"每天 · 至8月5日 · 15:00"),
                // 用 MarqueeText 替代 Text 避免长串换行撑高卡片、抵消 line 253-255 那次"高度降三分之一"优化。
                if let timeText = composedTimeText {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        MarqueeText(text: timeText, font: WarmFont.caption(10))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if let dueStatusText {
                Text(dueStatusText)
                    .font(WarmFont.caption(10))
                    .foregroundColor(dueStatusColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("TodoDueStatus_\(index)")
            }

            if todo.priority == .high && !todo.isCompleted {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isOverdue ? WarmTheme.textSecondary : WarmTheme.urgent)
                    )
                    .accessibilityIdentifier("PriorityLabel")
                    .accessibilityLabel(String(localized: "a11y.high_priority"))
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.xxs)
        // 卡片底色:纯白 cardBackground + 阴影分层。
        // 背景冷化后 cardBackground 与 background 都偏中性,
        // 改靠阴影 + 圆角建立层次,不再依赖色相对比。
        // showsCardBackground=false(Today 分组卡片)时整段跳过——底色与圆角由
        // 外层 `groupedCardRow` 统一画。
        .background {
            if showsCardBackground {
                RoundedRectangle(cornerRadius: WarmRadius.chip)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 4, x: 0, y: 2)
            }
        }
        // 去掉自带底色后整行是透明的,空白处(标题右边、第二行下方)不再参与 hit test,
        // 外层包裹的「点开详情」Button 会漏点。补一个 contentShape 把整行框回命中区。
        .contentShape(Rectangle())
        // 长按 context menu 的预览平台单独收圆角:分组模式下行本身没有背景,
        // 不给形状的话系统会按整个矩形行抠图,预览是个直角块,和圆角卡片语言不搭。
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: WarmRadius.chip))
        // iOS 26 FB18199844: 顶层 .onTapGesture 会吞掉 List swipeActions delete 按钮 tap。
        // 之前的 workaround 是把 onTapGesture 挂到 .background(Color.clear) 层,但背景层在
        // z 序是下层,iOS 26 List 中前景 Text/HStack/padding 拦截 hit testing,背景层
        // onTapGesture 收不到 tap —— 用户感知「整张卡片点不动」。改由调用方用
        // `Button { onOpenTodo(...) } label: { WarmTodoCard(...) }.buttonStyle(.plain)` 包装:
        // Button 是显式控件,跟 swipeActions 容器级手势天然共存(Apple Reminders 标准模式),
        // 内嵌 checkbox Button 也由 SwiftUI 分派给最内层,不会误触发外层 row tap。
        // 长按 context menu:兜底路径,不走拖拽也能改时段/移到明天。
        // 只在调用方注入 callback 时才挂 —— preview / mock 场景两个 callback 都 nil,
        // 此时 contextMenu 的 ViewBuilder 返回 EmptyView → SwiftUI 不挂 long-press 手势,
        // 与「裸 view」行为等价,但保持 View tree 类型稳定(condition 切换不引起重建)。
        // 卡片内部只剩 contextMenu(long-press)。tap 由调用方 Button 接管(见各调用点),
        // .draggable(如调用方挂)与 contextMenu 共存:long-press = 按住不动达阈值,
        // drag = 位移达阈值;iOS 自动仲裁。
        .contextMenu {
            if let onMoveToBucket {
                Section(String(localized: "card.menu.move_to_bucket")) {
                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                        Button {
                            HapticFeedback.light()
                            onMoveToBucket(bucket)
                        } label: {
                            Label(bucket.localizedTitle, systemImage: Self.bucketIcon(bucket))
                        }
                    }
                }
            }
            if let onMoveToTomorrow {
                Button {
                    HapticFeedback.light()
                    onMoveToTomorrow()
                } label: {
                    Label(String(localized: "card.menu.move_to_tomorrow"), systemImage: "calendar.badge.plus")
                }
            }
        }
        .accessibilityIdentifier("TodoCell_\(index)")
        .accessibilityValue(todo.isCompleted ? String(localized: "a11y.completed") : String(localized: "a11y.not_completed"))
        .accessibilityHint(String(localized: "a11y.view_detail"))
        .popover(isPresented: $showTimeEditor) {
            TimeEditPopover(
                date: $editingDate
            ) { date in
                commitTimeEdit(date: date)
            }
        }
    }

    /// 把 chip 点击事件转成 popover 弹出。popover 只编辑钟点,初始 date 取规则:
    /// - 有 dueDate → 用它(wheel 显示原钟点)
    /// - 无 dueDate → 用「今天 00:00 + 9h」= 今天 09:00。锚定 startOfDay 避免
    ///   `Date()` 取「当前瞬间」导致跨日漂移(用户 23:58 打开 popover、00:01 按
    ///   完成时,wheel 显示 23:58 但 editingDate 的日期分量已变成第二天 → 落库
    ///   到第二天 23:58)。默认钟点 09:00 是常见上班/晨间任务的合理起点。
    private func startEditingTime() {
        if let dueDate = todo.dueDate {
            editingDate = dueDate
        } else {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            editingDate = calendar.date(byAdding: .hour, value: 9, to: startOfToday) ?? startOfToday
        }
        showTimeEditor = true
    }

    /// popover 提交时:把新钟点回传 `onChangeTime`。popover 提交层不处理错误,
    /// 失败由调用方(HomeView.changeTodoTime)负责 toast。
    /// 时段/整天的切换由 contextMenu 的 `onMoveToBucket` 承接,不进 popover。
    private func commitTimeEdit(date: Date) {
        onChangeTime?(date)
        showTimeEditor = false
    }

    /// Context menu 里每个 bucket 的 SF Symbol。
    /// 与 TodoItemRow.swift 用的 `sun.max` 不同 —— 那里是 picker 的统一图标,
    /// 这里是 menu 内的视觉扫描辅助,每个 bucket 各自的时段意象更直观。
    static func bucketIcon(_ bucket: TimeBucket) -> String {
        switch bucket {
        case .anytime: return "circle.dotted"
        case .morning: return "sun.haze"
        case .afternoon: return "sun.max"
        case .evening: return "moon.stars"
        }
    }
}

// MARK: - Checkmark Shape

/// 勾号路径 — 借鉴 M13Checkbox 的 `M13CheckboxCheckPathGenerator`：
/// 用三点折线（短臂起点 → 中点 → 长臂顶点），配合 `.trim(from:to:)` 做"沿路径一笔绘制"的 stroke 动画。
/// 不直接用 SF Symbols 的 `checkmark`，是因为后者无法控制 stroke 的渐变绘制时机，
/// 而 `trim` 让"短臂→中点→长臂"按顺序出现，视觉上就是"被一笔勾出"。
struct WarmCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p1 = CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.55)
        let p2 = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.75)
        let p3 = CGPoint(x: rect.minX + rect.width * 0.85, y: rect.minY + rect.height * 0.25)
        path.move(to: p1)
        path.addLine(to: p2)
        path.addLine(to: p3)
        return path
    }
}

// MARK: - Preview

#Preview {
    HomeView(store: MockStore.preview)
        .environmentObject(AppCoordinator.preview)
}
