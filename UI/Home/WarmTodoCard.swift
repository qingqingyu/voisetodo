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
    var onTap: (() -> Void)? = nil
    /// 长按 context menu:移到指定 bucket。nil 时不挂 contextMenu(向后兼容)。
    var onMoveToBucket: ((TimeBucket) -> Void)? = nil
    /// 长按 context menu:移到明天。nil 时不显示「移到明天」项。
    var onMoveToTomorrow: (() -> Void)? = nil
    var showsTimeBucketMetadata = true
    var dueStatusDisplayMode: DueStatusDisplayMode = .full
    /// 标题行是否内联钟点前缀（"09:00 吃药"）。默认 false——
    /// 只有明确把外层时间标签删掉的调用方（HomeSelectedDayListView）才打开，
    /// 避免 UnscheduledDrawer 等其它调用方被动改变外观。
    var showsInlineTimePrefix = false

    /// 分类图标圆背景尺寸。用 @ScaledMetric 跟随 Dynamic Type 缩放,基准 28pt。
    /// relativeTo: .body 跟卡片标题字号(WarmFont.body(16) → .body textStyle)同步缩放,
    /// 避免 AX5 下字变大而图标不变导致比例失衡。
    /// 用户原话:「任务卡片的分类图标用 @ScaledMetric 定尺寸」。
    @ScaledMetric(relativeTo: .body) private var categoryIconCircleSize: CGFloat = 28
    /// 分类图标 SF Symbol 字号。基准 12pt,同步跟随 .body 缩放。
    @ScaledMetric(relativeTo: .body) private var categoryIconFontSize: CGFloat = 12

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
        if todo.isCompleted, !showsInlineTimePrefix { return nil }
        return TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: nil,
            dueHint: todo.dueDate == nil ? todo.dueHint : nil,
            timeBucketText: timeBucketText
        )
    }

    private var timeBucketText: String? {
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
        HStack(spacing: WarmSpacing.sm) {
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
                .frame(width: 44, height: 44)
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
                    ZStack {
                        Circle()
                            .fill(todo.isCompleted ? WarmTheme.textMuted.opacity(0.16) : categoryColor.opacity(0.16))
                            .frame(width: categoryIconCircleSize, height: categoryIconCircleSize)

                        Image(systemName: todo.category.sfSymbolName)
                            .font(.system(size: categoryIconFontSize, weight: .semibold))
                            .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : categoryColor)
                    }

                    // 标题行内联钟点:hasDueTime 时在 title 前挂 "HH:mm"。
                    // 10pt mono + 分类色,已完成降级到 textSecondary。
                    // fixedSize:WarmFont.mono 是固定字号,AX 档位下 HStack + List frame 会触发 .tail truncation。
                    if let inlineTime = inlineTimeText {
                        Text(inlineTime)
                            .font(WarmFont.mono(10))
                            .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : categoryColor)
                            .fixedSize()
                    }

                    Text(todo.title)
                        .font(todo.priority == .high ? WarmFont.headline(15) : WarmFont.body(15))
                        .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : WarmTheme.textPrimary)
                        .strikethrough(todo.isCompleted, color: WarmTheme.textSecondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)

                // 元数据合并行：clock + composedTimeText 一行展示。
                // P3 修复：原 recurrence 用 primaryDark 红色（与 urgent 警告冲突），
                // 改为 textSecondary 灰色（与 ConfirmSheet 时间行一致）；字号继续下压到 10pt 进一步压低视觉权重。
                if let timeText = composedTimeText {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(timeText)
                            .font(WarmFont.caption(10))
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
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.chip)
                .fill(WarmTheme.cardBackground)
                .shadow(color: WarmTheme.shadowLight, radius: 4, x: 0, y: 2)
        )
        // iOS 26 回归：把 .onTapGesture 挂到外层 HStack 会吞掉 List swipeActions
        // 滑出按钮的 tap。改挂到 .background(Color.clear) 层——swipeActions 由 List
        // 容器层管理（滑出覆盖层），不在此背景层的命中范围内；HStack 内非按钮区域
        // （padding/Spacer/Text）的 tap 仍会透传到这层背景，与原行为等价。
        // FB18199844（open as of iOS 26.0）。
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
        )
        // 长按 context menu:兜底路径,不走拖拽也能改时段/移到明天。
        // 只在调用方注入 callback 时才挂 —— preview / mock 场景两个 callback 都 nil,
        // 此时 contextMenu 的 ViewBuilder 返回 EmptyView → SwiftUI 不挂 long-press 手势,
        // 与「裸 view」行为等价,但保持 View tree 类型稳定(condition 切换不引起重建)。
        // .draggable / .onTapGesture 与 contextMenu 三手势共存:
        // tap = 立即抬起,drag = 位移达阈值,long-press = 按住不动达阈值;iOS 自动仲裁。
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
