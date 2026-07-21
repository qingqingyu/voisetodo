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
    var showsTimeBucketMetadata = true
    var dueStatusDisplayMode: DueStatusDisplayMode = .full

    private var categoryColor: Color {
        WarmTheme.color(for: todo.category)
    }

    /// 合并所有时间元数据成单行（用于第 2 行展示）。
    /// 拼装规则抽到了 `TodoTimeDisplayComposer`（与 ConfirmSheet 共用），
    /// 这里只负责"从 TodoItemData 模型字段取出结构化时间"——
    /// 注意 TodoItemData 没有 ExtractedTodo 的 dueTime 字符串字段，
    /// 钟点合在了 dueDate + hasDueTime，所以这里在 hasDueTime=true 时用
    /// DateFormatter 提取 "HH:mm"。
    private var composedTimeText: String? {
        guard !todo.isCompleted else { return nil }
        let timeText: String?
        if todo.hasDueTime, let dueDate = todo.dueDate {
            timeText = Self.timeFormatter.string(from: dueDate)
        } else {
            timeText = nil
        }
        return TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: timeText,
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
                            .frame(width: 28, height: 28)

                        Image(systemName: todo.category.sfSymbolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : categoryColor)
                    }

                    Text(todo.title)
                        .font(todo.priority == .high ? WarmFont.headline(16) : WarmFont.body(16))
                        .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : WarmTheme.textPrimary)
                        .strikethrough(todo.isCompleted, color: WarmTheme.textSecondary)
                        .lineLimit(2)
                }

                // 元数据合并行：clock + composedTimeText 一行展示。
                // P3 修复：原 recurrence 用 primaryDark 红色（与 urgent 警告冲突），
                // 改为 textSecondary 灰色（与 ConfirmSheet 时间行一致）；字号 12 → 11 进一步压低视觉权重。
                if let timeText = composedTimeText {
                    HStack(spacing: WarmSpacing.xxs) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(timeText)
                            .font(WarmFont.caption(11))
                    }
                    .foregroundColor(WarmTheme.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if let dueStatusText {
                Text(dueStatusText)
                    .font(WarmFont.caption(11))
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
        .padding(.vertical, WarmSpacing.xs)
        // 卡片底色：secondaryBackground 满不透明——0.5 透明度时卡片几乎融入背景，
        // 边界"似有似无"最尴尬。提到 1.0 让 #FFF5EE 与背景 #FFFBF7 有可辨识的对比。
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.chip)
                .fill(WarmTheme.secondaryBackground)
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
        .accessibilityIdentifier("TodoCell_\(index)")
        .accessibilityValue(todo.isCompleted ? String(localized: "a11y.completed") : String(localized: "a11y.not_completed"))
        .accessibilityHint(String(localized: "a11y.view_detail"))
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
