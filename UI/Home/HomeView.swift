import SwiftUI
import UIKit
import WidgetKit

private func formattedHomeDate(_ date: Date) -> String {
    date.formatted(.dateTime.month().day().weekday(.wide))
}

/// 读取当前 window 的底部 safe area inset（home indicator 高度，≈34pt on notched devices）。
/// 用于 `inputPanelOverlay` 在 `.ignoresSafeArea(edges: .bottom)`（等同 .all region）后、
/// 键盘未弹起时给 `BottomInputPanelView` 补一段 padding，避免面板内容侵入 home indicator 区域。
///
/// 实现选择：用 SwiftUI 原生 GeometryReader 而不是直接读 UIApplication.shared.connectedScenes。
/// 原因：GeometryReader 的 safeAreaInsets 是 SwiftUI 依赖图的一等公民，横竖屏切换 / 分屏
/// 改变 bottom safe area 时会自动 invalidate body；直接读 UIWindow.safeAreaInsets 绕过依赖图，
/// 可能停在旧值。GeometryReader 返回 Color.clear 不占布局空间，避免影响外层布局。
private struct BottomSafeAreaReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.safeAreaInsets.bottom) }
                .onChange(of: proxy.safeAreaInsets.bottom) { _, newValue in
                    onChange(newValue)
                }
        }
        .frame(width: 0, height: 0)
    }
}

// MARK: - HomeView

private struct HomeCalendarDayState {
    let date: Date
    let occurrences: [TodoOccurrenceData]
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let hasHighPriority: Bool
}

/// 首页日历视图模式：整月网格 / 单周一行。
enum CalendarViewMode: String {
    case month
    case week
}

private struct HomeCalendarState {
    let selectedDate: Date
    let visibleMonthAnchor: Date
    let viewMode: CalendarViewMode
    /// 当前模式下要渲染的日期：月视图为整月网格（42 天），周视图为所在周 7 天。
    let visibleDays: [Date]
    let weekHeaderDays: [Date]
    let occurrencesByDay: [String: [TodoOccurrenceData]]
    let unscheduledTodos: [TodoItemData]
    let selectedOccurrences: [TodoOccurrenceData]
    let uncompletedOccurrences: [TodoOccurrenceData]
    let completedOccurrences: [TodoOccurrenceData]
    let hasTodos: Bool

    private let calendar: Calendar

    var monthTitle: String {
        switch viewMode {
        case .month:
            return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
        case .week:
            guard let first = visibleDays.first, let last = visibleDays.last else {
                return visibleMonthAnchor.formatted(.dateTime.year().month(.wide))
            }
            // 去掉 zh/ja locale 下 `.dateTime.month().day()` 默认追加的"日"后缀，
            // 保留 locale-aware 的月份/日表达。en/等无此后缀的语言 hasSuffix 不命中即 no-op。
            // 注意：ko locale 的"일"后缀未在此处理——若后续要支持 ko，需扩展 stripDaySuffix
            // 并按字符（而非字节）dropLast；当前目标用户语言为 zh/en，ko 不在范围内。
            return "\(Self.stripDaySuffix(first.formatted(.dateTime.month().day()))) – \(Self.stripDaySuffix(last.formatted(.dateTime.month().day())))"
        }
    }

    /// 去掉 `.formatted(.dateTime.day())` 在 zh/ja locale 末尾产生的"日"后缀。
    /// 仅当以单字符"日"结尾时删除——避免误伤含"日"的星期或更复杂文案（此处 month().day() 不会出现）。
    /// ko locale 的"일"后缀不在处理范围（见 monthTitle 上方注释）。
    private static func stripDaySuffix(_ formatted: String) -> String {
        guard formatted.hasSuffix("日") else { return formatted }
        return String(formatted.dropLast())
    }

    var selectedDateTitle: String {
        if calendar.isDateInToday(selectedDate) {
            return String(localized: "home.week.today")
        }
        if calendar.isDateInTomorrow(selectedDate) {
            return String(localized: "home.week.tomorrow")
        }
        return selectedDate.formatted(.dateTime.month().day().weekday(.wide))
    }

    static func make<Store: HomeTodoStore>(
        store: Store,
        selectedDate: Date,
        visibleMonthAnchor: Date,
        viewMode: CalendarViewMode,
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar,
        now: Date = Date()
    ) -> HomeCalendarState {
        let normalizedSelectedDate = calendar.startOfDay(for: selectedDate)
        let normalizedAnchor = calendar.startOfDay(for: visibleMonthAnchor)
        let visibleDays = days(for: viewMode, anchor: normalizedAnchor, calendar: calendar)

        return HomeCalendarState(
            todos: store.todos,
            selectedDate: normalizedSelectedDate,
            visibleMonthAnchor: normalizedAnchor,
            viewMode: viewMode,
            visibleDays: visibleDays,
            weekHeaderDays: weekHeaderDays(referenceDate: now, calendar: calendar),
            occurrencesByDay: occurrencesByDay,
            calendar: calendar
        )
    }

    static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    func dayState(for day: Date) -> HomeCalendarDayState {
        let dayOccurrences = occurrences(on: day)
        return HomeCalendarDayState(
            date: day,
            occurrences: dayOccurrences,
            isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
            isToday: calendar.isDateInToday(day),
            // 周视图 7 天等权重，不按"当月"置灰；月视图保留跨月补齐日的弱化样式。
            isCurrentMonth: viewMode == .week
                ? true
                : calendar.isDate(day, equalTo: visibleMonthAnchor, toGranularity: .month),
            hasHighPriority: dayOccurrences.contains { $0.todo.priority == .high && !$0.isCompleted }
        )
    }

    func weekdayTitle(for date: Date) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    private init(
        todos: [TodoItemData],
        selectedDate: Date,
        visibleMonthAnchor: Date,
        viewMode: CalendarViewMode,
        visibleDays: [Date],
        weekHeaderDays: [Date],
        occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) {
        self.selectedDate = selectedDate
        self.visibleMonthAnchor = visibleMonthAnchor
        self.viewMode = viewMode
        self.visibleDays = visibleDays
        self.weekHeaderDays = weekHeaderDays
        self.occurrencesByDay = occurrencesByDay
        self.unscheduledTodos = todos.filter { $0.dueDate == nil && $0.recurrenceRule == nil }
        self.hasTodos = !todos.isEmpty
        self.calendar = calendar

        let selectedOccurrences = Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)
        self.selectedOccurrences = selectedOccurrences
        self.uncompletedOccurrences = selectedOccurrences.filter { !$0.isCompleted }
        self.completedOccurrences = selectedOccurrences.filter { $0.isCompleted }
    }

    private func occurrences(on day: Date) -> [TodoOccurrenceData] {
        Self.occurrences(on: day, in: occurrencesByDay, calendar: calendar)
    }

    private static func occurrences(
        on day: Date,
        in occurrencesByDay: [String: [TodoOccurrenceData]],
        calendar: Calendar
    ) -> [TodoOccurrenceData] {
        occurrencesByDay[TodoOccurrenceData.dayKey(for: day, calendar: calendar)] ?? []
    }

    /// 按模式返回要渲染/加载的日期集合。月视图 42 天网格；周视图所在周 7 天。
    static func days(for viewMode: CalendarViewMode, anchor: Date, calendar: Calendar) -> [Date] {
        switch viewMode {
        case .month:
            return monthDays(for: anchor, calendar: calendar)
        case .week:
            return weekDays(for: anchor, calendar: calendar)
        }
    }

    static func monthDays(for visibleMonthAnchor: Date, calendar: Calendar) -> [Date] {
        let monthStart = startOfMonth(for: visibleMonthAnchor, calendar: calendar)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// 锚点所在周的 7 天（与月视图同为周一起始，复用 startOfWeek）。
    static func weekDays(for anchor: Date, calendar: Calendar) -> [Date] {
        let start = startOfWeek(for: anchor, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func weekHeaderDays(referenceDate: Date, calendar: Calendar) -> [Date] {
        let monday = startOfWeek(for: referenceDate, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
    }
}

private enum HomeCalendarLoadState {
    case loading
    case empty
    case error
    case success
}

/// 键盘动画常量。放在文件作用域，避免在泛型 `HomeView<Store>` 内定义 static 属性
/// （Swift 不支持泛型类型的 static stored properties）。
private enum HomeKeyboardAnimation {
    /// 当通知 userInfo 缺失 duration 时的兜底值（iOS 默认键盘动画 0.25s）。
    static let fallbackDuration: TimeInterval = 0.25
    /// duration clamp 下限。硬件键盘场景可能给 0.0，SwiftUI 不接受 0 时长的 easeInOut。
    static let minDuration: TimeInterval = 0.05
}

@MainActor
/// 月历 occurrence 缓存的刷新键：当月锚点 / 当前 todos / occurrence 完成修订号任一变化即重算。
/// 用于 `.task(id:)` —— 规律任务 occurrence 完成切换不改 `store.todos`，必须靠 revision 触发刷新。
///
/// 性能取舍：用 `[TodoItemData]` 全数组做 Hashable，500 todos × ~20 字段 = μs 级比较，
/// 远小于 SwiftData fetch + 规则展开的耗时（后者才是 CLAUDE.md 性能表里的瓶颈）。
/// 派生 token（count + lastMutatedId）会漏掉对单条 todo 字段编辑的感知，不正确；
/// 用 `TodoStore.dataRevision` 全局自增能省掉这层比较，但需要 TodoStore 在所有写操作处 bump，
/// 工作量大且容易漏。当前方案是正确性优先。
private struct CalendarRefreshKey: Hashable {
    let anchor: Date
    let mode: CalendarViewMode
    let todos: [TodoItemData]
    let revision: Int
}

@MainActor
private struct HomeViewActions<Store: HomeTodoStore> {
    let store: Store
    let coordinator: AppCoordinator
    let setProcessing: (Bool) -> Void
    let selectTodo: (TodoItemData) -> Void
    /// 通知视图：规律任务 occurrence 完成状态已写入（store.todos 不会变化），需要刷新月历缓存。
    let markCalendarDataChanged: () -> Void

    func cancelExtraction() {
        coordinator.cancelExtraction()
        updateProcessing(false)
    }

    /// 启动 deeplink 重试任务并返回 Task 句柄。
    /// 与 submitManualInput 同样需要调用方持有，视图销毁时 cancel。
    @discardableResult
    func navigateToDeepLinkedTodo(id: UUID) -> Task<Void, Never> {
        if let todo = store.todos.first(where: { $0.id == id }) {
            selectTodo(todo)
            coordinator.deepLinkTodoId = nil
            return Task { } // 同步命中，返回已完成 Task 保持签名一致
        }

        return Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, coordinator.deepLinkTodoId == id else { return }
            if let todo = store.todos.first(where: { $0.id == id }) {
                selectTodo(todo)
            }
            coordinator.deepLinkTodoId = nil
        }
    }

    /// 启动「延时盖 overlay → 处理 → 关 overlay」任务并返回 Task 句柄，
    /// 由调用方持有以便在视图销毁时 cancel（防止访问已销毁的 @State）。
    @discardableResult
    func submitManualInput(_ text: String) -> Task<Void, Never> {
        return Task { @MainActor in
            print("🔍 [DIAG] home.manual_input.task_start text='\(text)'")
            // 等输入面板滑出动画结束（springSmooth ≈ 350ms）再盖 processing overlay，
            // 否则两层 overlay 同时淡入会撕裂。给 400ms 留余量。
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else {
                print("🔍 [DIAG] home.manual_input.task_cancelled reason=cancelled_during_sleep")
                return
            }
            print("🔍 [DIAG] home.manual_input.task_post_sleep calling_processManualInput")
            updateProcessing(true)
            await coordinator.processManualInput(text)
            // 处理期间用户可能退出 HomeView，再次校验避免访问已销毁状态。
            guard !Task.isCancelled else {
                print("🔍 [DIAG] home.manual_input.task_cancelled reason=cancelled_during_process")
                return
            }
            updateProcessing(false)
            print("🔍 [DIAG] home.manual_input.task_done")
        }
    }

    func toggleTodo(_ id: UUID) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try store.toggleComplete(id)
                WidgetCenter.shared.reloadAllTimelines()
                VoiceTodoLog.store.info("ui.home.toggle.success id=\(id.uuidString, privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.toggle.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    func toggleOccurrence(_ occurrence: TodoOccurrenceData) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try store.toggleOccurrenceComplete(occurrence.todo.id, on: occurrence.occurrenceDate)
                WidgetCenter.shared.reloadAllTimelines()
                markCalendarDataChanged()
                VoiceTodoLog.store.info("ui.home.toggle_occurrence.success id=\(occurrence.todo.id.uuidString, privacy: .public) date=\(occurrence.occurrenceDate.ISO8601Format(), privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.toggle_occurrence.failed id=\(occurrence.todo.id.uuidString, privacy: .public) date=\(occurrence.occurrenceDate.ISO8601Format(), privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    func deleteTodo(_ id: UUID) {
        withAnimation(WarmAnimation.springSmooth) {
            do {
                try coordinator.deleteTodo(id)
                VoiceTodoLog.store.info("ui.home.delete.success id=\(id.uuidString, privacy: .public)")
            } catch {
                VoiceTodoLog.store.error("ui.home.delete.failed id=\(id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                coordinator.showToast(
                    message: ErrorMessages.storageError,
                    style: .warning
                )
            }
        }
    }

    private func updateProcessing(_ isProcessing: Bool) {
        withAnimation(.easeInOut(duration: 0.3)) {
            setProcessing(isProcessing)
        }
    }
}

private struct HomeMonthHeaderView: View {
    let state: HomeCalendarState
    let onShift: (Int) -> Void
    let onJumpToToday: () -> Void
    let onSelectDay: (Date) -> Void
    let onSetViewMode: (CalendarViewMode) -> Void
    /// 可用高度（来自 GeometryReader）。0 = 不约束，用默认行高。
    var availableHeight: CGFloat = 0

    private var viewModeBinding: Binding<CalendarViewMode> {
        Binding(get: { state.viewMode }, set: { onSetViewMode($0) })
    }

    /// 根据可用高度计算日期格行高。
    /// 固定段（Picker + 导航行 + 星期表头 + spacing + padding）≈ 130pt（见 calendarFixedSectionHeight）；
    /// 剩余空间平分给网格行（月视图 6 行 / 周视图 1 行）。
    /// availableHeight = 0 时回退到默认 WarmSpacing.xxxl（48pt）。
    private var dayRowHeight: CGFloat {
        HomeLayoutMetrics.dayRowHeight(availableHeight: availableHeight, viewMode: state.viewMode)
    }

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            // iOS 26：.segmented picker 自带 Liquid Glass 渲染。
            // 保留 maxWidth 220——VStack 无其他宽度约束时 segmented 会撑满父容器，
            // 视觉上不协调；220pt 让 picker 紧凑居中。
            Picker("", selection: viewModeBinding) {
                Text(String(localized: "calendar.mode.month")).tag(CalendarViewMode.month)
                Text(String(localized: "calendar.mode.week")).tag(CalendarViewMode.week)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("CalendarViewModePicker")
            .accessibilityLabel(String(localized: "a11y.calendar_mode"))

            HStack {
                Button(action: { onShift(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PreviousMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.previous_week" : "a11y.previous_month"))

                Text(state.monthTitle)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button(action: { onShift(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NextMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.next_week" : "a11y.next_month"))

                Button(action: onJumpToToday) {
                    Text(String(localized: "home.week.today_button"))
                        .font(WarmFont.caption(13))
                        .foregroundStyle(WarmTheme.primaryDark)
                        .padding(.horizontal, WarmSpacing.sm)
                        .frame(height: 32)
                }
                .buttonStyle(.glass)
                // 淡橙 tint 呼应 FAB 的橙色调，但更弱（"今天"是次要操作）。
                .glassEffect(.regular.tint(WarmTheme.primary.opacity(0.3)))
                .accessibilityIdentifier("TodayMonthButton")
                .accessibilityLabel(String(localized: "a11y.today_month"))
            }

            HStack(spacing: WarmSpacing.xs) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: WarmSpacing.xs), count: 7), spacing: WarmSpacing.xs) {
                ForEach(state.visibleDays, id: \.self) { day in
                    HomeMonthDayButton(dayState: state.dayState(for: day), onSelect: onSelectDay, rowHeight: dayRowHeight)
                }
            }
        }
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.top, WarmSpacing.xxs)
        .padding(.bottom, WarmSpacing.sm)
        .background(WarmTheme.background.opacity(0.94))
    }
}

// MARK: - Home layout constants

private enum HomeLayoutMetrics {
    /// 月历区域目标上限比例（对齐 HTML 参考的 max-height:38vh）。
    static let calendarTargetHeightRatio: CGFloat = 0.38
    /// 月历表头固定段高度（Picker + 导航行 + 星期表头 + VStack spacing + padding）。
    /// 拆解：Picker segmented(~32) + navRow(32) + weekday(16) + VStack spacing(WarmSpacing.xs×5≈20)
    ///       + top/bottom padding(xxs+sm≈16) + 动态字体浮动余量(~14) ≈ 130pt 保守上限。
    /// 低估会导致 calendarHeight 算出比实际小，底部日期行被 `.clipped()` 裁切（Bug 1 根因）。
    static let calendarFixedSectionHeight: CGFloat = 130
    /// 单行日期格最小高度：优先保证 14pt 日期数字可读。
    static let dayRowMinHeight: CGFloat = 14
    /// 列表底部留白（Color.clear 占位 Section 的高度），与 BottomTabBar 实占高度解耦。
    /// 几何推导：safeAreaInset 实占 = BottomTabBar 自身高度 + .padding(.bottom, WarmSpacing.md)
    ///   = max(WarmSize.fab, WarmSize.tabPillSize) + WarmSpacing.md
    ///   = WarmSize.fab + WarmSpacing.md（因 fab > tabPillSize 不变量）
    ///   = 60 + 16 = 76pt。
    /// listBottomInset = 76pt + 余量 64pt(滚动停位呼吸 + 渐隐遮罩视觉缓冲) = 140pt。
    /// `.background` 内的渐隐遮罩 20pt 只覆盖在 Tab 簇背后、不进入布局流，不占用 safeAreaInset 高度。
    /// 调参规则：
    /// - 改 BottomTabBar.tabBarFadeHeight 时不应联动改本值——它不是 safeAreaInset 的高度。
    /// - 改 BottomTabBar 布局（HStack 高度、padding、Tab 簇尺寸）时必须重新测量 safeAreaInset 实占高度。
    static let listBottomInset: CGFloat = 140

    /// 圆点直径跟 rowHeight 自适应（改动 A）：
    /// 之前用固定 dayRowDotSize=4 + dayRowDotsVisibleThreshold=24，
    /// 但月视图实际 dayRowHeight ≈ 18pt < 24，圆点永不显示。
    /// 现在按行高动态返回圆点尺寸，月视图也能看到"有事/没事"标记。
    /// - rowHeight < 16：返回 nil（极矮屏，连日期数字都紧，不渲染圆点）
    /// - 16-20：返回 3（月视图典型）
    /// - 21-28：返回 3.5
    /// - ≥29：返回 4（周视图典型）
    static func dotSize(for rowHeight: CGFloat) -> CGFloat? {
        switch rowHeight {
        case ..<16: return nil
        case 16...20: return 3
        case 21...28: return 3.5
        default: return 4
        }
    }
    /// 周视图单行期望高度（舒适触摸目标 + 视觉留白）。
    /// 周视图只有 1 行，若套用 38% cap 会把单行撑到 128pt 过高；
    /// 这里用固定 48pt 让周视图紧凑，腾出更多空间给列表。
    static let weekDesiredRowHeight: CGFloat = 48

    /// 月历区域高度（容器封顶值，不直接决定行高）。
    /// 设计意图（对齐 HTML 参考 `max-height:38vh; overflow:hidden`）：
    ///   - **月视图**：6 行内容通常接近 38% cap，直接用 cap 让 dayRowHeight 自适应撑满。
    ///   - **周视图**：1 行内容远低于 38%，若套用 cap 会把单行撑到 128pt 过高；
    ///     改用 content-driven（header + 1 行 48pt = 178pt），列表获得更多空间。
    /// 与 `dayRowHeight` 的契约：本函数返回容器高度，`dayRowHeight` 在容器内独立计算行高
    /// （`max(dayRowMinHeight, (container - fixedSection - spacing) / rows)`）。
    /// 极矮屏（maxCap < 178）下周视图 dayRowHeight 会 < 48，容器底部可能被 `.clipped()` 裁切，
    /// 这是已知取舍（与月视图一致）：列表区至少 62% 不可妥协。
    static func calendarHeight(availableHeight: CGFloat, selectedTab: BottomTab, viewMode: CalendarViewMode) -> CGFloat {
        guard selectedTab == .calendar, availableHeight > 0 else { return 0 }
        let maxCap = availableHeight * calendarTargetHeightRatio
        switch viewMode {
        case .month:
            return maxCap
        case .week:
            let contentHeight = calendarFixedSectionHeight + weekDesiredRowHeight
            return min(maxCap, contentHeight)
        }
    }

    static func dayRowHeight(availableHeight: CGFloat, viewMode: CalendarViewMode) -> CGFloat {
        guard availableHeight > 0 else { return WarmSpacing.xxxl }
        let rows = rowCount(for: viewMode)
        let usable = max(0, availableHeight - calendarFixedSectionHeight - gridSpacing(forRows: rows))
        return max(dayRowMinHeight, usable / rows)
    }

    private static func rowCount(for viewMode: CalendarViewMode) -> CGFloat {
        switch viewMode {
        case .month:
            return 6
        case .week:
            return 1
        }
    }

    private static func gridSpacing(forRows rows: CGFloat) -> CGFloat {
        WarmSpacing.xs * max(0, rows - 1)
    }
}

private struct HomeMonthDayButton: View {
    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void
    var rowHeight: CGFloat = WarmSpacing.xxxl

    /// 圆点尺寸跟 rowHeight 自适应（改动 A）：
    /// 月视图 18pt 行高下返回 3pt，周视图 48pt 行高下返回 4pt。
    /// 极矮屏（< 16pt）返回 nil，不渲染圆点。
    private var dotSize: CGFloat? {
        HomeLayoutMetrics.dotSize(for: rowHeight)
    }

    var body: some View {
        Button {
            onSelect(dayState.date)
        } label: {
            VStack(spacing: WarmSpacing.xxs) {
                // 纯数字（5/29 等），不用 .formatted(.dateTime.day(.twoDigits))
                // 后者在 zh locale 下产生"29日"，与日期格上下文冲突显冗余。
                // VoiceOver 文案仍走 VoiceOverLabel.monthDayText（带"6月29日"完整表达），
                // 视觉显示与无障碍朗读职责分离。
                Text("\(Calendar.current.component(.day, from: dayState.date))")
                    .font(WarmFont.headline(14))
                    .foregroundColor(dayState.isSelected ? .white : (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))

                if let dotSize {
                    HStack(spacing: 2) {
                        ForEach(0..<min(dayState.occurrences.count, 3), id: \.self) { index in
                            Circle()
                                .fill(dayState.hasHighPriority && index == 0 ? WarmTheme.urgent : (dayState.isSelected ? Color.white : WarmTheme.primary))
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                    .frame(height: dotSize)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            // 选中态放大：弱动画提示用户"我点对了"，但不夸张到挤压相邻格
            // （月历 7 列宽，放大太多会重叠）。Reduce Motion 时 animation 会被系统忽略。
            .scaleEffect(dayState.isSelected ? WarmAnimation.monthDaySelectedScale : WarmAnimation.monthDayDefaultScale)
            .animation(WarmAnimation.springSmooth, value: dayState.isSelected)
            // 改动 B：背景简化——
            // - 选中：实心 primary 背景 + 白字（白字在 fill 上面，靠 foregroundColor 控制）
            // - 今天未选中：primary 0.18 浅填充（视觉锚点，替代原来的 stroke 边框）
            // - 其他：裸背景（无填充、无边框、无阴影），让圆点成为主视觉标记
            // 删除的内容：Color.white.opacity(0.9/0.45) 白底、stroke 边框、shadow 阴影
            .background {
                if dayState.isSelected {
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(WarmTheme.primary)
                } else if dayState.isToday {
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(WarmTheme.primary.opacity(0.18))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceOverLabel.build(for: dayState))
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthDay_\(dayState.date.formatted(.dateTime.year().month().day()))")
    }
}

/// VoiceOver 文案构造：把日历单元格的状态翻译成完整一句话。
/// 月视图单元格视觉信息（数字、点、底色）对低视力/盲人用户没用，必须用文字补全。
/// 顺序遵循可达性惯例：身份（日期）在前，状态（非当月/今天/待办数）在后。
/// 使用 app 当前本地化语言 + gregorian 日历格式化日期，避免系统区域语言与 app 文案混读。
private enum VoiceOverLabel {
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
        let count = dayState.occurrences.count
        if count > 0 {
            parts.append(String(format: String(localized: "a11y.day.todo_count"), count))
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

private struct HomeSelectedDayListView: View {
    let state: HomeCalendarState
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onDeleteTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    let onMoveUnscheduled: (IndexSet, Int) -> Void

    var body: some View {
        List {
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if state.selectedOccurrences.isEmpty {
                    emptySelectedDayRow
                } else {
                    ForEach(Array(zip(state.uncompletedOccurrences.indices, state.uncompletedOccurrences)), id: \.1.id) { index, occurrence in
                        occurrenceRow(occurrence, index: index)
                    }
                }
            } header: {
                daySectionHeader(title: state.selectedDateTitle, count: state.uncompletedOccurrences.count)
            }

            if !state.completedOccurrences.isEmpty {
                Section {
                    ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(occurrence, index: state.uncompletedOccurrences.count + idx)
                    }
                } header: {
                    daySectionHeader(title: String(localized: "home.completed_section_title"), count: state.completedOccurrences.count)
                }
            }

            if !state.unscheduledTodos.isEmpty {
                Section {
                    ForEach(Array(state.unscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        todoRow(todo, index: state.selectedOccurrences.count + idx)
                    }
                    .onMove(perform: onMoveUnscheduled)
                } header: {
                    daySectionHeader(title: String(localized: "home.week.unscheduled"), count: state.unscheduledTodos.count)
                }
            }

            // 防底部玻璃簇遮挡的尾部留白 Section。
            // List .frame(height: listHeight) 钉死后 safeAreaInset(.bottom) 不被 List 感知，
            // 最后一项会滚到底部悬浮玻璃簇后面。Color.clear 占位让出空间。
            // listBottomInset 见 HomeLayoutMetrics 顶部注释拆解（Tab 簇 safeAreaInset 实占 76pt + 余量 64pt）。
            Section {
                Color.clear
                    .frame(height: HomeLayoutMetrics.listBottomInset)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("TodoList")
    }

    private var homeGlobalEmptyRow: some View {
        // 空状态只做文案引导，主要输入入口由底部 FAB + 输入面板承载。
        ProductEmptyStateView(
            icon: "sparkles",
            title: String(localized: "empty.home.title"),
            message: String(localized: "empty.home.message")
        )
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.sm, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    private var emptySelectedDayRow: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "empty.day.title"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(Color.white.opacity(0.86))
                .shadow(color: WarmTheme.shadowLight, radius: 5, x: 0, y: 2)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("EmptyState")
    }

    private func daySectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(title)
                .font(WarmFont.headline(15))
            Text("\(count)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.primaryDark)
                .padding(.horizontal, WarmSpacing.xs)
                .padding(.vertical, WarmSpacing.xxs)
                .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: WarmSpacing.md, leading: WarmSpacing.xl, bottom: WarmSpacing.xxs, trailing: WarmSpacing.lg))
    }

    private func todoRow(_ todo: TodoItemData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    private func occurrenceRow(_ occurrence: TodoOccurrenceData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: occurrence.todo,
            onToggle: { onToggleOccurrence(occurrence) },
            onTap: { onOpenTodo(occurrence.todo) }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xs, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(occurrence.todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(occurrence.todo.id) ? 1 : 0)
        .offset(y: cardAppeared.contains(occurrence.todo.id) ? 0 : 20)
        .onAppear {
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(occurrence.todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }
}

private struct HomeCalendarLoadingView: View {
    var body: some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                .scaleEffect(1.2)

            Text(String(localized: "home.calendar.loading"))
                .font(WarmFont.body(15))
                .foregroundColor(WarmTheme.textSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("HomeCalendarLoadingState")
    }
}

private struct HomeCalendarErrorView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: WarmSpacing.md) {
                ProductEmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "home.calendar.error.title"),
                    message: String(localized: "home.calendar.error.message")
                )

                Button(action: onRetry) {
                    Label(String(localized: "common.retry"), systemImage: "arrow.clockwise")
                        .font(WarmFont.headline(15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: WarmSize.touch)
                        .background(
                            Capsule()
                                .fill(WarmTheme.primary)
                                .shadow(color: WarmTheme.shadowMedium, radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HomeCalendarRetryButton")
            }
            .padding(.horizontal, WarmSpacing.xl)
            .accessibilityIdentifier("HomeCalendarErrorState")

            Spacer()
        }
    }
}

/// 主页视图 - 温暖手账风格
/// 纸张纹理背景 + 手写展示字体 + 分类色带卡片
struct HomeView<Store: HomeTodoStore>: View {
    @ObservedObject var store: Store
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var permissionManager: PermissionManager
    @State private var isProcessing = false
    @State private var showSettingsSheet = false
    // 底部 Tab + FAB + 输入面板状态
    @State private var selectedBottomTab: BottomTab = .today
    @State private var showInputPanel = false
    @State private var isKeyboardMode = false
    /// 键盘模式是否由录音失败 fallback 触发（区别于未来可能的手动切换入口）。
    /// true 时 BottomInputPanelView 显示警告 banner + 「重新尝试语音」按钮。
    @State private var isFallbackMode = false
    @State private var panelInputText = ""
    /// 键盘当前高度（监听 UIResponder.keyboardWillShow/Hide 通知）。
    /// 用于把 BottomInputPanelView 整体上推到键盘之上——否则 .overlay(alignment: .bottom)
    /// 的内容会被键盘挡住（提交按钮看不到）。
    ///
    /// 残留兜底：`.onReceive` 订阅挂在 `inputPanelOverlay` 的 ZStack 上，当
    /// `showInputPanel=false` 时整个 overlay 会被移除，可能错过 `keyboardWillHide` 通知
    /// 导致 `keyboardHeight` 残留非零。body 末尾的 `onChange(of: showInputPanel)` 在面板
    /// 关闭时显式归零兜底，避免新增 close 路径漏改。
    @State private var keyboardHeight: CGFloat = 0
    /// 底部 safe area inset（home indicator 高度），由 `BottomSafeAreaReader` 同步过来。
    /// 用于 `inputPanelOverlay` 在键盘未弹起时给面板补 padding 避开 home indicator。
    /// 用 @State 让 SwiftUI 把 inset 作为视图依赖：横竖屏切换 / 分屏改变时自动 invalidate body。
    @State private var bottomSafeAreaInset: CGFloat = 0
    /// 两阶段关闭的过渡标志：键盘模式下第一次点遮罩只收键盘后置 true，
    /// 让第二次点无脑走 closeInputPanel 而不再依赖 keyboardHeight 是否归零。
    /// 解决两个竞态：
    ///   (1) dismissKeyboard 是 no-op（first responder 不是 FocusableUITextView）→
    ///       keyboardWillHide 不触发 → keyboardHeight 卡在 >0 → 用户永远进不了第二阶段
    ///   (2) 用户快速连点：keyboardWillHide 异步派发尚未把 keyboardHeight 改 0 时，
    ///       第二次点又被判定为「键盘弹起」再次 dismissKeyboard
    /// 重置时机：closeInputPanel 后 scheduleDeferredPanelStateReset 一并清，与
    /// panelInputText 同生命周期；openVoiceInputPanel / switchInputPanelMode 也复位。
    @State private var keyboardDismissStageTriggered: Bool = false
    /// dismissKeyboard 后的兜底 timer：若 N 毫秒后 keyboardHeight 仍 > 0，
    /// 说明 resignFirstResponder 没有真正触发 keyboardWillHide（no-op 场景），
    /// 此时把 keyboardDismissStageTriggered 强制设 true，让下一次 tap 直接 closeInputPanel。
    @State private var keyboardDismissFallbackTask: Task<Void, Never>?
    /// 输入面板会话 epoch：每次 openVoiceInputPanel 自增。所有键盘异步比对路径
    /// （scheduleKeyboardDismissFallback）快照时记录 epoch，比对时校验 epoch 未变，
    /// 彻底消除"会话切换恰好 keyboardHeight 相同"的 TOCTOU 假阳性。
    @State private var panelSessionEpoch: Int = 0
    @State private var inputPanelPermissionTask: Task<Void, Never>?
    @State private var inputPanelResetTask: Task<Void, Never>?
    /// 「录音模式发送」触发的 stop-and-process 任务。视图销毁时一并 cancel。
    @State private var stopAndProcessTask: Task<Void, Never>?
    /// 「键盘模式发送」触发的延时处理任务。与 stopAndProcessTask 同样需要在
    /// 视图销毁时 cancel，否则会在 await 后访问已销毁的 @State/coordinator。
    @State private var manualInputTask: Task<Void, Never>?
    /// Deeplink 重试任务（todos 尚未加载时延后重试）。同样需要 onDisappear cancel。
    @State private var deepLinkTask: Task<Void, Never>?
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var visibleMonthAnchor = Calendar.current.startOfDay(for: Date())
    @State private var hasStartedEntranceAnimation = false
    /// 月历 occurrence 缓存：由后台 `queryActor` 异步加载，主线程不再做 SwiftData fetch/展开。
    /// `.task(id:)` 在 visibleMonthAnchor / store.todos / occurrenceRevision 变化时刷新。
    @State private var monthOccurrences: [String: [TodoOccurrenceData]] = [:]
    @State private var calendarLoadState: HomeCalendarLoadState = .loading
    /// 规律任务 occurrence 完成切换不会改 `store.todos`（完成记录在独立表），用此 revision 强制刷新。
    @State private var occurrenceRevision = 0
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
    /// 日历视图模式（月/周），跨启动记住上次选择。
    @AppStorage("calendarViewMode") private var calendarViewModeRaw = CalendarViewMode.month.rawValue
    private var calendarViewMode: CalendarViewMode {
        CalendarViewMode(rawValue: calendarViewModeRaw) ?? .month
    }

    private let waveformHeights: [CGFloat] = [12, 24, 20, 32, 16]
    private let calendar = Calendar.current
    private var isInputEntryBlockedByProcessing: Bool {
        coordinator.isExtracting || isProcessing || coordinator.showConfirmSheet
    }

    private var isInputEntryDisabled: Bool {
        coordinator.isRecording || isInputEntryBlockedByProcessing
    }

    // MARK: - Initialization

    init(store: Store) {
        self.store = store
    }

    @State private var selectedTodo: TodoItemData?

    /// 列表可见性：录音 / 处理 / 抽取中时隐藏列表与底部渐隐遮罩。
    /// 集中此条件避免 Group 与遮罩两处重复判断漂移。
    private var isListVisible: Bool {
        !coordinator.isRecording && !isProcessing && !coordinator.isExtracting
    }

    // 动画状态
    @State private var headerOffset: CGFloat = -50
    @State private var headerOpacity: Double = 0
    @State private var listOffset: CGFloat = 30
    @State private var listOpacity: Double = 0
    @State private var cardAppeared: Set<UUID> = []

    private var actions: HomeViewActions<Store> {
        HomeViewActions(
            store: store,
            coordinator: coordinator,
            setProcessing: { isProcessing = $0 },
            selectTodo: { selectedTodo = $0 },
            markCalendarDataChanged: { occurrenceRevision += 1 }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(spacing: 0) {
                    headerView

                    if coordinator.isRecording || isProcessing || coordinator.isExtracting {
                        recordingOverlay
                    }

                    Group {
                        if isListVisible {
                            monthHomeView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 底部渐隐遮罩：让列表内容淡出到 Tab 簇下方，而不是被硬切。
                // 只在列表可见时显示（录音态有全屏 overlay 不需要）。
                // allowsHitTesting(false) 确保不拦截列表滚动 / 点击。
                if isListVisible {
                    LinearGradient(
                        colors: [.clear, WarmTheme.background.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .frame(height: 40)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                startEntranceAnimation()
            }
            .overlay {
                if coordinator.isRecording {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("RecordingIndicator")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomTabBar(
                    selectedTab: $selectedBottomTab,
                    isFABDisabled: isInputEntryDisabled,
                    onFABTap: { openVoiceInputPanel() }
                )
            }
            // 底部输入面板（从底部滑出 + 遮罩）
            .overlay(alignment: .bottom) {
                if showInputPanel {
                    inputPanelOverlay
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                HomeSettingsSheet(
                    calendarWriteModeRaw: $calendarWriteModeRaw,
                    onUpgradePro: { coordinator.showPaywall = true }
                )
            }
            .navigationDestination(item: $selectedTodo) { todo in
                TodoDetailView(store: store, todo: todo)
                    .environmentObject(coordinator)
            }
            .onChange(of: coordinator.deepLinkTodoId) { _, todoId in
                guard let todoId else { return }
                deepLinkTask?.cancel()
                deepLinkTask = actions.navigateToDeepLinkedTodo(id: todoId)
            }
            .onChange(of: store.todos.count) { _, _ in
                let currentIds: Set<UUID> = Set(store.todos.map(\.id))
                cardAppeared = cardAppeared.intersection(currentIds)
            }
            .onChange(of: selectedBottomTab) { _, tab in
                if tab == .today {
                    jumpToToday()
                }
            }
            // 面板关闭时显式归零 keyboardHeight 作为兜底——onReceive 订阅挂在 inputPanelOverlay
            // 的 ZStack 上，showInputPanel=false 后整个 overlay 会被移除，可能错过
            // keyboardWillHide 通知导致 keyboardHeight 残留非零。集中在此处理比每个 close/send
            // 路径内联归零更可靠（不会因新增路径漏改）。
            .onChange(of: showInputPanel) { _, isVisible in
                if !isVisible {
                    // 面板关闭：归零 keyboardHeight 兜底（避免非正常退出残留）
                    if keyboardHeight != 0 {
                        keyboardHeight = 0
                    }
                    // 取消两阶段 fallback timer：closeInputPanel 通常已 cancel，
                    // 但 onChange 路径兜底外部将 showInputPanel 置 false 的场景（生命周期/路由切换）。
                    keyboardDismissFallbackTask?.cancel()
                }
            }
            .onChange(of: coordinator.voiceInputFallbackToKeyboard) { oldValue, shouldFallback in
                // 识别器初始化失败（模拟器缺 Siri asset / 真机罕见故障）时，
                // coordinator 信号 → 自动切键盘模式，避免用户被困在录音模式看 toast。
                // 仅在面板打开、且未已处于键盘模式时响应；面板没开就没必要切。
                // 用 rising edge (oldValue=false, newValue=true) 过滤掉复位产生的额外触发，
                // 也避免 handleError 被并发调用多次时键盘模式闪两次。
                // 并发安全：handleError 同步连续调用多次时，SwiftUI 会合并变更通知，
                // 最终值仍为 true，observer 至少触发一次，isFallbackMode 会被正确置 true。
                guard !oldValue, shouldFallback, showInputPanel, !isKeyboardMode else { return }
                coordinator.voiceInputFallbackToKeyboard = false
                print("🔍 [DIAG] home.fallback_to_keyboard reason=recognizer_unavailable")
                isFallbackMode = true
                switchInputPanelMode(toKeyboard: true)
            }
            .onDisappear {
                // 视图销毁时主动收尾异步 Task，避免它们继续访问已销毁的 @State。
                // cancel 后统一 nil 清空，让 ARC 尽早回收（与已 nil 的 task 一致）。
                inputPanelPermissionTask?.cancel()
                inputPanelPermissionTask = nil
                inputPanelResetTask?.cancel()
                inputPanelResetTask = nil
                keyboardDismissFallbackTask?.cancel()
                keyboardDismissFallbackTask = nil
                stopAndProcessTask?.cancel()
                stopAndProcessTask = nil
                manualInputTask?.cancel()
                manualInputTask = nil
                deepLinkTask?.cancel()
                deepLinkTask = nil
                // 复位两阶段标志 + fallback 标志：scheduleDeferredPanelStateReset 只在 closeInputPanel
                // 后 400ms 触发，若 view 在此之前销毁（tab 切换 / sheet dismiss），复位就漏了。
                // 与 openVoiceInputPanel 已做的复位动作对齐，保证"销毁→重建"与"open→close"状态等价。
                keyboardDismissStageTriggered = false
                isFallbackMode = false
            }
        }
        .accessibilityIdentifier("HomeView")
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(formattedHomeDate(Date()))
                    .font(WarmFont.caption(14))
                    .foregroundColor(WarmTheme.textSecondary)

                // tab 感知：today 显示问候语；calendar 显示"日历"标题（改动 C）。
                // 复用现有 tab.calendar key（"日历" / "Calendar"），不新增 localization。
                // 字体/颜色两 tab 一致，切换无位移。
                Text(selectedBottomTab == .today ? greetingText : String(localized: "tab.calendar"))
                    .font(WarmFont.display(30))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Spacer()

            // statsBadge 显隐：
            // - store.todos 为空：彻底不渲染（无内容可统计）
            // - calendarLoadState == .error：隐藏——缓存不可信且 fallback 每帧 O(n) 遍历 store.todos
            //   会持续触发性能开销（用户越滑越卡）。错误态让用户先看到 retry 按钮，统计徽章次要。
            // - 其他（loading/success/empty）：正常显示，缓存命中优先，未命中走 fallback 同步兜底。
            if !store.todos.isEmpty && calendarLoadState != .error {
                statsBadge
            }

            settingsButton
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.top, WarmSpacing.md)
        .padding(.bottom, WarmSpacing.sm)
        .background(
            WarmTheme.background.opacity(0.9)
                .shadow(color: WarmTheme.shadowLight, radius: 1, y: 1)
        )
        .offset(y: headerOffset)
        .opacity(headerOpacity)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return String(localized: "home.greeting.morning")
        case 12..<14:
            return String(localized: "home.greeting.noon")
        case 14..<18:
            return String(localized: "home.greeting.afternoon")
        case 18..<22:
            return String(localized: "home.greeting.evening")
        default:
            return String(localized: "home.greeting.night")
        }
    }

    /// 计算 selectedDate 当天的完成度统计。
    /// 优先用 `monthOccurrences` 缓存（已通过 .task(id:) 异步算好）；
    /// 缓存未就绪（冷启动/跨月切换）时同步从 `store.todos` 过滤兜底，
    /// 避免 statsBadge 闪现 "0/0"。
    ///
    /// 已知瞬态：跨月切换瞬间缓存清空，fallback 只覆盖原始 dueDate 命中（保守，
    /// 不计 recurrenceRule 重复展开），数字会从"含重复任务的真实计数"暂时回落到
    /// "仅原始 dueDate 计数"，几十 ms 后缓存加载完成即恢复。这是可接受的瞬态——
    /// 比闪 "0/0" 更友好（用户至少能看到当天有任务）。
    private func selectedDayStats() -> (total: Int, completed: Int) {
        let dayKey = TodoOccurrenceData.dayKey(for: selectedDate, calendar: calendar)
        if let cached = monthOccurrences[dayKey] {
            let completed = cached.filter { $0.isCompleted }.count
            return (cached.count, completed)
        }
        // 兜底：直接遍历 store.todos，覆盖 dueDate 命中 selectedDate 的非重复任务。
        // 重复任务在 monthOccurrences 加载前先不计入（保守，避免重复渲染高估）。
        let day = calendar.startOfDay(for: selectedDate)
        let onDay = store.todos.filter { todo in
            guard let due = todo.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
        let completed = onDay.filter { $0.isCompleted }.count
        return (onDay.count, completed)
    }

    private var statsBadge: some View {
        // 统计口径：selectedDate 当天（与列表 section header 一致，避免数字打架）。
        // today tab 下 selectedDate 恒为今天（无 UI 改定），实际就是"今天的完成度"；
        // calendar tab 下跟用户点的日期走。
        // iOS 26：.glassEffect 默认按 content shape 渲染（HStack 是圆角矩形），
        // 用 .clipShape(Capsule()) 强制成胶囊形，与原 Capsule().fill 观感对齐。
        let (total, completed) = selectedDayStats()
        return HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(WarmTheme.primary)

            Text(String(localized: "home.stats \(completed) \(total)"))
                .font(WarmFont.caption(14))
                .foregroundStyle(WarmTheme.textSecondary)
        }
        .padding(.horizontal, WarmSpacing.sm)
        .padding(.vertical, WarmSpacing.xs)
        .glassEffect(.regular)
        .clipShape(Capsule())
    }

    private var settingsButton: some View {
        // iOS 26：圆形按钮用 .buttonStyle(.glass) + .glassEffect(.regular)，
        // 替代原来的 Circle().fill(secondaryBackground)。设置图标在玻璃上保持 secondary 色。
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(WarmTheme.textSecondary)
                .frame(width: WarmSize.touch, height: WarmSize.touch)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .glassEffect(.regular)
        .accessibilityIdentifier("HomeSettingsButton")
        .accessibilityLabel(String(localized: "settings.title"))
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        ZStack {
            WarmTheme.background.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: WarmSpacing.xl) {
                Spacer()

                if isProcessing || coordinator.isExtracting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                        .scaleEffect(1.5)

                    Text(String(localized: "home.processing"))
                        .font(WarmFont.displayLight(20))
                        .foregroundColor(WarmTheme.textSecondary)

                    if coordinator.isExtracting {
                        Button(action: {
                            actions.cancelExtraction()
                        }) {
                            Text(String(localized: "home.cancel_extraction"))
                                .font(WarmFont.body(15))
                                .foregroundColor(WarmTheme.textSecondary)
                                .padding(.horizontal, WarmSpacing.lg)
                                .padding(.vertical, WarmSpacing.xs)
                                .background(
                                    Capsule()
                                        .stroke(WarmTheme.textMuted, lineWidth: 1)
                                )
                        }
                        .accessibilityIdentifier("CancelExtractionButton")
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(WarmTheme.primary.opacity(0.08))
                            .frame(width: WarmSize.mega, height: WarmSize.mega)

                        Circle()
                            .fill(WarmTheme.primary.opacity(0.15))
                            .frame(width: WarmSize.hero, height: WarmSize.hero)

                        HStack(spacing: WarmSpacing.xxs) {
                            ForEach(Array(waveformHeights.enumerated()), id: \.offset) { i, h in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(WarmTheme.primary)
                                    .frame(width: 4, height: h)
                                    .animation(
                                        .easeInOut(duration: 0.5)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.12),
                                        value: coordinator.isRecording
                                    )
                            }
                        }
                    }

                    Text(String(localized: "home.listening"))
                        .font(WarmFont.display(22))
                        .foregroundColor(WarmTheme.textPrimary)
                }

                if !coordinator.transcript.isEmpty {
                    Text(coordinator.transcript)
                        .font(WarmFont.body(15))
                        .foregroundColor(WarmTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, WarmSpacing.xxl)
                        .padding(.vertical, WarmSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.section)
                                .fill(Color.white.opacity(0.8))
                                .shadow(color: WarmTheme.shadowLight, radius: 4, y: 2)
                        )
                        .padding(.horizontal, WarmSpacing.xl)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .animation(.easeOut(duration: 0.2), value: coordinator.transcript)
                }

                Spacer()
            }
        }
        .transition(.opacity)
    }

    // MARK: - Month Home View

    private var monthHomeView: some View {
        let state = HomeCalendarState.make(
            store: store,
            selectedDate: selectedDate,
            visibleMonthAnchor: visibleMonthAnchor,
            viewMode: calendarViewMode,
            occurrencesByDay: monthOccurrences,
            calendar: calendar
        )

        return GeometryReader { proxy in
            // 月历封顶 38% 高度（硬约束，对齐 solution-b-capped-calendar.html 的 max-height:38vh）。
            // 极矮屏日期行可能被裁切，与 HTML overflow:hidden 一致；列表区始终 ≥ 62% 可滚动。
            // 「今日」tab 隐藏月历，列表占满 100%。
            let calendarHeight = HomeLayoutMetrics.calendarHeight(
                availableHeight: proxy.size.height,
                selectedTab: selectedBottomTab,
                viewMode: calendarViewMode
            )

            VStack(spacing: 0) {
                if selectedBottomTab == .calendar {
                    HomeMonthHeaderView(
                        state: state,
                        onShift: shiftPeriod,
                        onJumpToToday: jumpToToday,
                        onSelectDay: selectDay,
                        onSetViewMode: setViewMode,
                        availableHeight: calendarHeight
                    )
                    // 封顶 + 裁切：对齐 HTML 参考的 max-height:38vh + overflow:hidden。
                    // 防止月历内容（网格行高过小时）向上溢出盖住"下午好"标题、
                    // 或向下溢出侵入列表滚动区。
                    // alignment: .top —— 内容贴顶；周→月切换动画期间 frame 从 178pt 涨到 258pt，
                    // 但内容立即变 6 行（~244pt），中途 frame ~200pt 装不下时，.top 让溢出只往下走，
                    // 上方 Picker/月份标题不被切（默认 .center 会上下都切，"上面文字被切掉"的 bug）。
                    .frame(height: calendarHeight, alignment: .top)
                    .clipped()
                }

                switch calendarLoadState {
                case .loading:
                    HomeCalendarLoadingView()
                case .error:
                    HomeCalendarErrorView(onRetry: retryCalendarLoad)
                case .empty, .success:
                    // 列表高度必须 concrete（不能用 .frame(maxHeight: .infinity)）：
                    // SwiftUI 在 GeometryReader + VStack 嵌套里对 List 提议"无限"高度时，
                    // List 会渲染所有内容而不滚动（已知行为）。
                    // 这里用 proxy.size.height - calendarHeight 算出实际可用高度，
                    // List 在此 concrete 高度内会正确启用滚动。
                    let listHeight = max(0, proxy.size.height - calendarHeight)
                    HomeSelectedDayListView(
                        state: state,
                        cardAppeared: $cardAppeared,
                        onToggleTodo: { actions.toggleTodo($0) },
                        onToggleOccurrence: { actions.toggleOccurrence($0) },
                        onDeleteTodo: { actions.deleteTodo($0) },
                        onOpenTodo: { selectedTodo = $0 },
                        onMoveUnscheduled: { source, destination in
                            moveUnscheduled(from: source, to: destination)
                        }
                    )
                    .frame(height: listHeight)
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("MonthHomeView")
        .task(id: CalendarRefreshKey(anchor: visibleMonthAnchor, mode: calendarViewMode, todos: store.todos, revision: occurrenceRevision)) {
            let startedAt = Date()
            // 注意：这里**不**主动设 .loading（避免切月份时清掉旧数据导致闪烁）。
            // 唯一例外：如果当前是 .error 态（上一次加载失败），重置为 .loading ——
            // 因为错误态本来就没有可保留的旧数据，重置闪烁可接受，反而避免新月份加载期间错误视图盖屏。
            if calendarLoadState == .error {
                calendarLoadState = .loading
            }
            // .success / .empty / 初始 .loading 都不主动设，保留旧值。
            let rangeDays = HomeCalendarState.days(for: calendarViewMode, anchor: visibleMonthAnchor, calendar: calendar)
            guard let firstDay = rangeDays.first, let lastDay = rangeDays.last else {
                monthOccurrences = [:]
                calendarLoadState = store.todos.isEmpty ? .empty : .success
                VoiceTodoLog.store.warning("home.month_occurrences.load_skipped reason=no_month_days anchor=\(visibleMonthAnchor.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                return
            }
            do {
                let groupedOccurrences = try await store.groupedCalendarOccurrences(
                    from: firstDay,
                    to: lastDay,
                    calendar: calendar
                )
                guard !Task.isCancelled else {
                    VoiceTodoLog.store.debug("home.month_occurrences.load_cancelled start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                    return
                }
                monthOccurrences = groupedOccurrences
                calendarLoadState = store.todos.isEmpty ? .empty : .success
                VoiceTodoLog.store.debug("home.month_occurrences.load_success start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) dayBuckets=\(monthOccurrences.count) todoCount=\(store.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            } catch is CancellationError {
                VoiceTodoLog.store.debug("home.month_occurrences.load_cancelled start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            } catch {
                calendarLoadState = .error
                VoiceTodoLog.store.error("home.month_occurrences.load_failed start=\(firstDay.ISO8601Format(), privacy: .public) end=\(lastDay.ISO8601Format(), privacy: .public) todoCount=\(store.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            }
        }
    }

    private func retryCalendarLoad() {
        occurrenceRevision += 1
    }

    private func selectDay(_ day: Date) {
        let normalizedDay = calendar.startOfDay(for: day)
        withAnimation(WarmAnimation.springStandard) {
            selectedDate = normalizedDay
            visibleMonthAnchor = normalizedDay
        }
    }

    // MARK: - Input Panel

    /// 面板底部 padding 的单一来源：键盘弹起时推到键盘顶（keyboardHeight），
    /// 键盘未弹起时补一段 safe area inset 避开 home indicator。
    /// 合并成单一计算属性避免两个连续 .padding(.bottom, ...) 隐式互斥的阅读负担。
    private var panelBottomPadding: CGFloat {
        keyboardHeight + (keyboardHeight == 0 ? bottomSafeAreaInset : 0)
    }

    private var inputPanelOverlay: some View {
        ZStack(alignment: .bottom) {
            // 遮罩
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    // 两阶段关闭（键盘模式下）：
                    //   - 键盘弹起时第一次点：只收键盘，面板变矮但仍可见，输入内容保留
                    //   - 键盘已收起时再点：关面板
                    // 这样兼顾两种意图：
                    //   (1) 用户瞄准 send 按钮 tap 偏到遮罩——只丢键盘不丢内容，能继续找 send
                    //   (2) 用户明确放弃输入——连点两次外面就全收起来
                    // 录音模式没有键盘可收，直接关面板。
                    if isKeyboardMode {
                        if keyboardDismissStageTriggered {
                            // 已经触发过第一阶段（或兜底 timer 强制置位）→ 第二次点直接关面板
                            print("🔍 [DIAG] home.panel.mask_tapped action=close_panel (键盘模式：第二阶段关面板)")
                            closeInputPanel()
                        } else if keyboardHeight > 0 {
                            // 第一阶段：收键盘，置标志位防止后续 tap 再次走 dismissKeyboard 路径
                            print("🔍 [DIAG] home.panel.mask_tapped action=dismiss_keyboard (键盘弹起：第一阶段收键盘)")
                            keyboardDismissStageTriggered = true
                            dismissKeyboard()
                            scheduleKeyboardDismissFallback()
                        } else {
                            // 键盘本来就没弹（hardware keyboard / Stage Manager 等），直接关
                            print("🔍 [DIAG] home.panel.mask_tapped action=close_panel (键盘未弹起：直接关面板)")
                            closeInputPanel()
                        }
                    } else {
                        print("🔍 [DIAG] home.panel.mask_tapped action=close_panel (录音模式：关面板)")
                        closeInputPanel()
                    }
                }
                .transition(.opacity)

            // 面板：用 .padding(.bottom, keyboardHeight) 让其整体跟随键盘推上，
            // 否则 .overlay(alignment: .bottom) 的内容会被键盘挡住（提交按钮看不到）。
            BottomInputPanelView(
                isKeyboardMode: $isKeyboardMode,
                inputText: $panelInputText,
                isRecording: coordinator.isRecording,
                isFallbackMode: isFallbackMode,
                onClose: { closeInputPanel() },
                onModeChange: { switchInputPanelMode(toKeyboard: $0) },
                onSendText: { text in handlePanelSend(text: text) },
                onStopRecordingForProcessing: { handlePanelSend(text: "") }
            )
            // 强制按内容大小（垂直方向），不被 ZStack 里的 Color.black.ignoresSafeArea
            // 反向撑大。没有这行，BottomInputPanelView 会跟 ZStack 同高（=屏幕全屏），
            // 加上 padding 后超出屏幕飞到顶部。
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, panelBottomPadding)
            // 诊断：用 iOS 17+ onGeometryChange（不通过 GeometryReader，不影响 layout）
            // 跟踪面板 frame，定位"超出屏幕"问题。
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                #if DEBUG
                print("🔍 [DIAG] panel.frame_global minY=\(newFrame.minY) height=\(newFrame.height) maxY=\(newFrame.maxY) keyboardHeight=\(keyboardHeight) panelBottomPadding=\(panelBottomPadding)")
                #endif
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // 必须忽略所有 safe area region（包括 .keyboard），让 ZStack 在键盘弹起时也不缩小：
        //   - 若只忽略 .container（home indicator）不忽略 .keyboard：键盘弹起时 ZStack 底部
        //     被推到键盘顶（如 539），同时 .padding(.bottom, keyboardHeight=335) 又把 view
        //     再推 335pt，view 顶部跑到屏幕外（minY=-147），面板和键盘之间出现 335pt 空白间隙。
        //   - 忽略 .all（含 .keyboard）：ZStack 底部始终对齐屏幕底（874），padding 推 view
        //     上去 keyboardHeight 让 BottomInputPanelView 底部贴键盘顶，无间隙也不飞屏。
        // .ignoresSafeArea(edges: .bottom) 等同于 .ignoresSafeArea(.all, edges: .bottom)。
        //
        // 副作用补偿：键盘未弹（keyboardHeight=0）时 ZStack 贴屏幕底，BottomInputPanelView
        // 内部的 panelInternalBottomPadding（22pt）不足以避开 home indicator（≈34pt），面板内容会侵入。
        // 此时通过 panelBottomPadding（见上）额外补一段 safe area 高度的 padding；
        // 键盘弹起后由 keyboardHeight 推上去，无需补偿。
        //
        // 顺序契约：`.background` modifier 应用在 `.ignoresSafeArea` 之前，
        // 意味着 background 内的 GeometryReader 读到的是 ignore 之前的 safeAreaInsets（含 home indicator）。
        // SwiftUI modifier 是链式后置包装，`.background` 的内容位于链中「未 ignore」的视图上下文中。
        // 这是一个隐式契约——若未来 iOS 版本改变 modifier 应用语义，需重新验证。
        // iPad 等无 home indicator 设备天然返回 0，SwiftUI 对 @State 相等赋值不会触发额外渲染。
        .background(
            BottomSafeAreaReader { inset in
                bottomSafeAreaInset = inset
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .zIndex(100)
        // 监听键盘事件：弹起时记录高度推面板上移；收回时清零。
        // 用 willShow/willHide（不是 did）让动画与系统键盘同步，避免滞后感。
        // 动画 duration/curve 优先读取通知 userInfo 中的系统值，缺省时退回默认（键盘动画兜底）。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                VoiceTodoLog.ui.warning("home.keyboard.will_show missing frame userInfo")
                return
            }
            // 诊断：iOS 26 模拟器疑似返回异常 frame（如整屏高度），让 panelBottomPadding 过大
            // 把面板推到屏幕顶端。打印 frame 实际值 + 屏幕高度对比，定位是 keyboard通知 bug
            // 还是 padding 计算 bug。
            // 注意： UIScreen.main 在 iOS 16+ 已弃用，用 connectedScenes 取 window scene 的屏高。
            // 多 window 场景（iPad / Stage Manager）下取所有 foregroundActive scene 的最大屏高
            // 作为 clamp 上限基准——clamp 只用作异常 frame 兜底，取最大值保证不会把正常键盘误 clamp 矮。
            // 真实单 window 设备（iPhone）只有一个 foregroundActive scene，等价原行为。
            let activeScenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            let screenHeight = activeScenes.map { $0.screen.bounds.height }.max() ?? frame.height
            #if DEBUG
            print("🔍 [DIAG] home.keyboard.will_show frame=\(frame) screenHeight=\(screenHeight) frame.height=\(frame.height) origin.y=\(frame.origin.y)")
            #endif
            // 保底 clamp：键盘高度不可能超过屏幕高度的 70%。超过说明是异常值
            // （iOS 26 模拟器某些版本返回整个 UIWindow 的 frame）。用 origin.y 反推真实高度：
            // 键盘顶部 = 屏幕底 - 键盘高度 = origin.y（在屏幕坐标系下）。
            let resolvedHeight = (frame.origin.y > 0 && frame.origin.y < screenHeight)
                ? (screenHeight - frame.origin.y)
                : min(frame.height, screenHeight * 0.7)
            withAnimation(keyboardAnimation(from: note)) {
                keyboardHeight = resolvedHeight
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            // 收到 keyboardWillHide → dismissKeyboard 已成功生效，作废兜底 timer 避免竞态窗口误触发
            keyboardDismissFallbackTask?.cancel()
            withAnimation(keyboardAnimation(from: note)) {
                keyboardHeight = 0
            }
        }
    }

    private func openVoiceInputPanel() {
        guard !isInputEntryDisabled else { return }
        inputPanelResetTask?.cancel()
        keyboardDismissFallbackTask?.cancel()
        // 自增 epoch：让上一会话残留的异步比对 task（fallback timer）即使 cancel 信号未及时送达，
        // 比对时也能识别"已进入新会话"而短路退出。
        // 用 += 而非 &+=：Int 在 app 生命周期内不可能溢出（每次 open +1，需 9×10^18 次才溢出），
        // 万一溢出应 trap 而非静默回绕（项目原则：错误显式传播）。
        panelSessionEpoch += 1
        panelInputText = ""
        // 复位两阶段标志 + fallback 信号：上次会话残留的 true 会让本次首点直接关面板
        keyboardDismissStageTriggered = false
        // 复位 keyboardHeight：上次会话非正常退出（后台挂起后回来 / overlay 销毁错过
        // keyboardWillHide）可能残留 >0，让本次首点误走「键盘弹起」分支浪费一次 tap。
        // onChange(of: showInputPanel) 只在关闭时归零，打开时这里显式重置。
        keyboardHeight = 0
        // 复位 fallback 标志：本次是主动打开录音，不是 fallback 触发的键盘模式。
        isFallbackMode = false
        // 复位录音失败 fallback 信号（注意与 keyboardDismissStageTriggered 不同对象）：
        // 上次 Action Button / 面板外识别失败可能留下陈旧的 true，若不复位，
        // onChange 不会再次触发（值未变化），本次录音失败时无法自动切键盘。
        coordinator.voiceInputFallbackToKeyboard = false
        withAnimation(WarmAnimation.springSmooth) {
            showInputPanel = true
            isKeyboardMode = false
        }
        startRecordingForInputPanel()
    }

    private func startRecordingForInputPanel() {
        inputPanelPermissionTask?.cancel()
        inputPanelPermissionTask = Task { @MainActor in
            let readiness = await permissionManager.ensureVoicePermissionsBeforeRecording()
            guard !Task.isCancelled, showInputPanel, !isKeyboardMode else { return }

            if readiness == .granted {
                guard !isInputEntryDisabled else {
                    withAnimation(WarmAnimation.springSmooth) {
                        showInputPanel = false
                    }
                    scheduleDeferredPanelStateReset()
                    return
                }
                // 用返回值判断录音是否真正起来——不要读 coordinator.isRecording，
                // 那是 Combine 绑定 (.receive(on: .main))，await 后还在 pending，
                // 会把已起来的录音误判成 no_op 并切键盘（日志里的 fallback=keyboard）。
                let didStart = await coordinator.startRecording()
                guard !Task.isCancelled, showInputPanel else { return }
                guard didStart else {
                    // startRecording 没抛但录音未真正起来（音频会话/识别器边界场景，
                    // 例如模拟器缺 Siri asset）。回退到键盘模式让用户继续输入。
                    VoiceTodoLog.ui.warning("home.input_panel.start_recording_no_op fallback=keyboard")
                    // no_op 路径属于 fallback 触发：置位 isFallbackMode 显示 banner + retry 按钮。
                    // 否则 isFallbackMode 残留上一轮值（手动切键盘后被关掉仍是 false / 旧 fallback 残留 true），
                    // 误导用户「麦克风坏了」或反之不显示 retry。
                    isFallbackMode = true
                    withAnimation(WarmAnimation.springSmooth) {
                        isKeyboardMode = true
                    }
                    return
                }
                guard !Task.isCancelled, showInputPanel, !isKeyboardMode, !isInputEntryBlockedByProcessing else {
                    // didStart=true 表示录音已起来过。这里无条件 cancelRecording，
                    // coordinator.cancelRecording 内部 guard 读同步 voiceInput.isRecording
                    // （非 Combine 绑定的 coordinator.isRecording），不会误 cancel 已停止的录音。
                    coordinator.cancelRecording()
                    return
                }
            } else {
                // 权限未授予也属于 fallback 触发：置位 isFallbackMode 与 no_op 路径保持一致，
                // 让 banner 解释麦克风不可用并提供 retry。
                isFallbackMode = true
                isKeyboardMode = true
                coordinator.showVoicePermissionRequiredToast()
            }
        }
    }

    private func switchInputPanelMode(toKeyboard keyboardMode: Bool) {
        inputPanelResetTask?.cancel()
        keyboardDismissFallbackTask?.cancel()
        keyboardDismissStageTriggered = false
        if keyboardMode {
            inputPanelPermissionTask?.cancel()
            // 外层 if 不是冗余：cancelRecording 内部 guard 会生成 flowID/打日志，
            // 键盘模式正常情况下录音未启动，避免每次切换都触发无意义调用。
            if coordinator.isRecording {
                coordinator.cancelRecording()
            }
            withAnimation(WarmAnimation.springSmooth) {
                isKeyboardMode = true
            }
        } else {
            panelInputText = ""
            // 切回录音模式 = 用户主动放弃键盘输入，复位 fallback 标志。
            // 若本次录音再次失败，coordinator 会重新触发 fallback 并置 true。
            isFallbackMode = false
            // 切回录音模式时主动收键盘（同 closeInputPanel 的根因）。
            dismissKeyboard()
            withAnimation(WarmAnimation.springSmooth) {
                isKeyboardMode = false
            }
            startRecordingForInputPanel()
        }
    }

    private func closeInputPanel() {
        inputPanelPermissionTask?.cancel()
        inputPanelPermissionTask = nil
        keyboardDismissFallbackTask?.cancel()
        // 外层 if 不是冗余：cancelRecording 内部 guard 会生成 flowID/打日志，
        // 关闭时若录音未启动（权限被拒等），避免触发无意义调用。
        if coordinator.isRecording {
            coordinator.cancelRecording()
        }
        // 主动收键盘：UIKit UITextView 的 firstResponder 不响应 SwiftUI @State 变化，
        // 必须显式 endEditing，否则键盘会停留在已关闭的面板上。
        dismissKeyboard()
        // keyboardHeight 与 showInputPanel 在同一 withAnimation 内一起动画，
        // 避免 padding 瞬变 + 面板缓动造成的「跳一下」错位。
        // onChange(of: showInputPanel) 兜底归零，此处不必显式置零。
        withAnimation(WarmAnimation.springSmooth) {
            showInputPanel = false
        }
        scheduleDeferredPanelStateReset()
    }

    private func handlePanelSend(text: String) {
        // 诊断日志（print 保证 Xcode console 100% 看到，OSLog info 默认会被过滤）：
        // 用户反馈"输入后提交信息消失"，需确认 text/isKeyboardMode 是否真的进入此函数。
        print("🔍 [DIAG] home.panel.send_received text='\(text)' isKeyboardMode=\(isKeyboardMode) isRecording=\(coordinator.isRecording)")
        inputPanelPermissionTask?.cancel()
        inputPanelPermissionTask = nil
        keyboardDismissFallbackTask?.cancel()
        if isKeyboardMode {
            // 键盘模式正常情况下录音未启动（switchInputPanelMode 已处理取消），
            // 这里只兜底竞态——保留 if 防止每次发送都触发 cancelRecording 的内部日志噪音。
            if coordinator.isRecording {
                coordinator.cancelRecording()
            }
            manualInputTask?.cancel()
            manualInputTask = actions.submitManualInput(text)
        } else if coordinator.isRecording {
            stopAndProcessTask?.cancel()
            stopAndProcessTask = Task { @MainActor in
                withAnimation(WarmAnimation.springSmooth) {
                    isProcessing = true
                }
                await coordinator.stopRecordingAndProcess()
                // 注：注释曾描述"用户可能在 await 期间重开面板启动新录音"竞态，但实际已被
                // startRecordingForInputPanel 的 `!isInputEntryBlockedByProcessing` guard
                // （含 isProcessing）拦截——处理期间无法启动新录音。
                // 原 `!showInputPanel` guard 冗余且有害（面板关闭时会让 isProcessing 卡住），
                // 故删除。此处只需检查任务是否被取消。
                guard !Task.isCancelled else { return }
                withAnimation(WarmAnimation.springSmooth) {
                    isProcessing = false
                }
            }
        } else {
            // 录音模式但录音未启动（权限/竞态/系统中断）—— 不静默吞掉，记日志并提示用户。
            VoiceTodoLog.ui.warning("home.input_panel.send_skipped reason=not_recording isKeyboardMode=\(self.isKeyboardMode)")
            coordinator.showToast(message: ErrorMessages.recordingNotActive, style: .warning)
        }
        // 与 closeInputPanel 同根因：overlay 即将移除，UIKit firstResponder 不主动释放就会
        // 错过 keyboardWillHide。dismissKeyboard + onChange(of: showInputPanel) 兜底归零。
        dismissKeyboard()
        withAnimation(WarmAnimation.springSmooth) {
            showInputPanel = false
        }
        scheduleDeferredPanelStateReset()
    }

    /// 400ms 后如果面板没被重开，重置 panelInputText / isKeyboardMode / 两阶段标志。
    /// 用 delay 是为了让用户在快速关闭→重开时不会看到内容闪一下被清空。
    private func scheduleDeferredPanelStateReset() {
        inputPanelResetTask?.cancel()
        inputPanelResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, !showInputPanel else { return }
            panelInputText = ""
            isKeyboardMode = false
            keyboardDismissStageTriggered = false
            isFallbackMode = false
        }
    }

    /// dismissKeyboard 后的兜底：若 `dismissFallbackDeadline` 后 keyboardHeight 仍 > 0，
    /// 说明 resignFirstResponder 没有触发 keyboardWillHide（no-op 场景：
    /// first responder 不是 FocusableUITextView / 被系统 Alert 抢焦点等），
    /// 此时强制 keyboardDismissStageTriggered=true，让下一次 tap 直接走 closeInputPanel，
    /// 避免用户被困在「点遮罩只调 dismissKeyboard no-op，永远进不了第二阶段」的死锁。
    private func scheduleKeyboardDismissFallback() {
        // 350ms 取值依据：
        //   - 下界：iOS keyboardWillHide 通知在 resignFirstResponder 后约 1 个 runloop（~16ms）发出，
        //     350ms 留 ~20 倍余量吸收主线程卡顿 / SwiftUI 渲染排队。
        //   - 上界：人类感知「双击」的最小间隔约 300-500ms（Apple DoubleTap 间隔 250-300ms），
        //     350ms 在多数用户的「第一次 tap 收键盘 → 第二次 tap 关面板」节奏内，
        //     即使用户略快也会被 stageTriggered 直接 close，不会卡在死循环。
        // 没有更短的「正确」值——iOS 没有提供「first responder 是否成功 resign」的同步 API。
        let dismissFallbackDeadline: UInt64 = 350_000_000
        keyboardDismissFallbackTask?.cancel()
        let snapshot = keyboardHeight
        let snapshotEpoch = panelSessionEpoch
        keyboardDismissFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: dismissFallbackDeadline)
            // 面板已关闭（closeInputPanel / handlePanelSend / onChange(of: showInputPanel) 都会取消本 task；
            // 但为防 cancel 信号未送达 / Task 正好在 sleep 退出时被替换的极小竞态，再读一次 showInputPanel）。
            // epoch 校验：若期间 openVoiceInputPanel 已自增（用户重开面板），即便 keyboardHeight
            // 恰好相同也短路退出，彻底消除跨会话 TOCTOU。
            guard !Task.isCancelled, showInputPanel, panelSessionEpoch == snapshotEpoch else { return }
            // 键盘仍未收起 → 视为 dismissKeyboard no-op，强制推进到第二阶段
            if keyboardHeight == snapshot, snapshot > 0 {
                keyboardDismissStageTriggered = true
            }
        }
    }

    /// 主动释放 firstResponder 收键盘。封装成方法以消除三处 close/switch/send 路径的重复调用。
    /// UIKit 的 UITextView 不响应 SwiftUI @State 变化，必须显式 endEditing。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    /// 从键盘通知 userInfo 读取系统动画 duration/curve，缺省时退回 KeyboardAnimation 兜底。
    /// 不直接硬编码 0.25 easeOut——iOS 26 系统键盘动画常为 spring 且时长可变，
    /// 与系统值对齐才能避免「面板跑得快、键盘跑得慢」的错位。
    private func keyboardAnimation(from note: Notification) -> Animation {
        let userInfo = note.userInfo ?? [:]
        let rawDuration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double)
            ?? HomeKeyboardAnimation.fallbackDuration
        // 防 0/负值：硬件键盘断开或 stage manager 场景下 userInfo 可能给 0.0，
        // SwiftUI .easeInOut(duration: 0) 行为未定义，clamp 到最小 0.05s 保证可观测动画。
        let duration = max(rawDuration, HomeKeyboardAnimation.minDuration)
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut
        // UIView.AnimationCurve 与 SwiftUI.Animation 没有直接桥接，这里用与系统键盘近似的
        // timingCurve + duration 还原：easeInOut → SwiftUI 默认 easeInOut；其它曲线退回同曲线近似。
        // 未知曲线值（@unknown default）一律退回 easeInOut，避免假还原。
        switch curve {
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        @unknown default:
            return .easeInOut(duration: duration)
        }
    }

    // MARK: - Actions

    private func startEntranceAnimation() {
        if !hasStartedEntranceAnimation {
            let today = calendar.startOfDay(for: Date())
            selectedDate = today
            visibleMonthAnchor = today
            hasStartedEntranceAnimation = true
        }

        withAnimation(WarmAnimation.springEntrance.delay(0.1)) {
            headerOffset = 0
            headerOpacity = 1
        }

        withAnimation(WarmAnimation.springEntrance.delay(0.25)) {
            listOffset = 0
            listOpacity = 1
        }
    }

    /// 模式感知的翻页：月视图按月翻，周视图按周翻。
    private func shiftPeriod(by value: Int) {
        let component: Calendar.Component = calendarViewMode == .week ? .weekOfYear : .month
        guard let newAnchor = calendar.date(byAdding: component, value: value, to: visibleMonthAnchor) else {
            return
        }
        let normalizedAnchor: Date = calendarViewMode == .week
            ? calendar.startOfDay(for: newAnchor)
            : HomeCalendarState.startOfMonth(for: newAnchor, calendar: calendar)
        withAnimation(WarmAnimation.springStandard) {
            visibleMonthAnchor = normalizedAnchor
            selectedDate = normalizedAnchor
        }
    }

    private func setViewMode(_ mode: CalendarViewMode) {
        guard calendarViewMode != mode else { return }
        withAnimation(WarmAnimation.springStandard) {
            calendarViewModeRaw = mode.rawValue
            // 把可视锚点对齐到当前选中日：切周→显示选中日所在周，切月→显示选中日所在月，
            // 避免切换后选中高亮/下方任务列表落在看不见的区间外。
            visibleMonthAnchor = mode == .week
                ? calendar.startOfDay(for: selectedDate)
                : HomeCalendarState.startOfMonth(for: selectedDate, calendar: calendar)
        }
    }

    private func jumpToToday() {
        let today = calendar.startOfDay(for: Date())
        withAnimation(WarmAnimation.springStandard) {
            selectedDate = today
            visibleMonthAnchor = today
            // 不设 selectedBottomTab——日历里"今天"按钮只让月历跳到今天位置，
            // 不切底部 tab。底部 tab 切"今日"时 onChange 会调此方法设 selectedDate。
        }
    }

    /// 拖动重排「无日期」段：只在无日期任务之间互换全局位置，已排期/已完成任务槽位不动，
    /// 避免打乱 Widget 依赖的全局 sortOrder。
    private func moveUnscheduled(from source: IndexSet, to destination: Int) {
        // 与 HomeCalendarState.unscheduledTodos 同源同序（store.todos 已按 sortOrder 升序）。
        var displayed = store.todos.filter(TodoReorderPlanner.isUnscheduled)
        displayed.move(fromOffsets: source, toOffset: destination)
        let newUnscheduledOrder = displayed.filter { !$0.isCompleted }.map(\.id)
        let uncompleted = store.todos.filter { !$0.isCompleted }
        let fullIds = TodoReorderPlanner.reorderedUncompletedIDs(
            uncompleted: uncompleted,
            newUnscheduledOrder: newUnscheduledOrder
        )
        do {
            try store.reorder(ids: fullIds)
        } catch {
            VoiceTodoLog.store.error("home.reorder_unscheduled.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            store.refreshTodos()
        }
    }
}

// MARK: - Warm Todo Card

struct WarmTodoCard: View {
    let index: Int
    let todo: TodoItemData
    let onToggle: () -> Void
    var onTap: (() -> Void)? = nil

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
            timeText: timeText,
            dueHint: todo.dueHint
        )
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
                    // 分类图标：统一 SF Symbol 体系（替代 emoji），按 categoryColor 着色。
                    // 已完成时图标跟着文字一起降为 textSecondary，视觉上"整行变灰"。
                    // opacity 0.85（而非 0.7）：12pt 小图标下 7 种分类色（尤其黄/橙）
                    // 需要更高饱和度才可辨识；0.7 适合大色块，小图标会糊在一起。
                    Image(systemName: todo.category.sfSymbolName)
                        .font(.system(size: 12))
                        .foregroundColor(todo.isCompleted ? WarmTheme.textSecondary : categoryColor.opacity(0.85))

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

            if todo.priority == .high && !todo.isCompleted {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(WarmTheme.urgent)
                    )
                    .accessibilityIdentifier("PriorityLabel")
                    .accessibilityLabel(String(localized: "a11y.high_priority"))
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        // P4 修复：卡片感减重——
        // - 移除白底 + shadow（孤岛感来源）
        // - 改用极浅 secondaryBackground 让卡片与背景融合
        // - 圆角 section(16) → chip(8)（与待办列表"轻分隔"语义匹配）
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.chip)
                .fill(WarmTheme.secondaryBackground.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
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
private struct WarmCheckmarkShape: Shape {
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
