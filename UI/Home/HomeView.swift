import SwiftUI
import UIKit
import WidgetKit

private func formattedHomeDate(_ date: Date) -> String {
    // 只给「月 日」（"Jul 16"）：星期已由下方大标题（todayWeekdayTitle）承担，
    // 这里再带 weekday 会重复，还会把顶部一行挤到折行 + greeting 截断。
    date.formatted(.dateTime.month().day())
}

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

    /// 本周完成数(用于首页"本周小结"卡片)。
    private var weeklyCompletedCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        return store.todos.filter { $0.isCompleted }.filter { todo in
            guard let completed = todo.completedAt else { return false }
            let day = cal.startOfDay(for: completed)
            return day >= weekStart && day <= today
        }.count
    }

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

                    // 本周小结卡片(快速入口到回顾页)
                    if weeklyCompletedCount > 0 {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            HStack(spacing: WarmSpacing.sm) {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(WarmTheme.primary)
                                    .font(.system(size: 14))
                                Text(String(localized: "home.weekly_summary \(weeklyCompletedCount)"))
                                    .font(WarmFont.caption(13))
                                    .foregroundColor(WarmTheme.textSecondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                                    .foregroundColor(WarmTheme.textMuted)
                            }
                            .padding(.horizontal, WarmSpacing.lg)
                            .padding(.vertical, WarmSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }

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
                    .frame(height: HomeLayoutMetrics.bottomListFadeHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
            // A2 自动学习建议 banner
            .overlay(alignment: .top) {
                if let suggestion = coordinator.glossarySuggestion {
                    GlossarySuggestionBanner(
                        suggestion: suggestion,
                        onAccept: {
                            PersonalGlossaryStore.shared.add(PersonalGlossaryEntry(
                                type: .alias,
                                phrase: suggestion.correction.originalTitle,
                                expansion: suggestion.correction.confirmedTitle,
                                localeIdentifier: suggestion.correction.localeIdentifier
                            ))
                            CorrectionTracker.shared.remove(id: suggestion.correction.id)
                            withAnimation { coordinator.glossarySuggestion = nil }
                        },
                        onDismiss: {
                            CorrectionTracker.shared.remove(id: suggestion.correction.id)
                            withAnimation { coordinator.glossarySuggestion = nil }
                        }
                    )
                    .padding(.horizontal, WarmSpacing.lg)
                    .padding(.top, WarmSpacing.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VoiceFAB(
                    isDisabled: isInputEntryDisabled,
                    onTap: { openVoiceInputPanel() }
                )
                .opacity(showInputPanel ? 0 : 1)
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
            // B3 通知深链:回顾通知点击后弹出 ReviewView
            .sheet(isPresented: Binding(
                get: { coordinator.showReviewFromNotification },
                set: { coordinator.showReviewFromNotification = $0 }
            )) {
                NavigationStack { ReviewView() }
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
            .onChange(of: coordinator.didAutoFinishDueToSilence) { oldValue, didAutoFinish in
                // 静音自动提交：用户说完话 1.5s 后自动触发 Send 流程，
                // 等效于用户手动点"Done"按钮——复用 handlePanelSend 走同一条处理路径。
                // 若 isRecording 已为 false（看门狗超时已收敛），静音信号到达太晚——
                // 此时调 handlePanelSend 会走 else 分支弹"录音未活跃"误导 toast，静默丢弃。
                guard !oldValue, didAutoFinish, showInputPanel, !isKeyboardMode, coordinator.isRecording else { return }
                coordinator.didAutoFinishDueToSilence = false
                handlePanelSend(text: "")
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
        VStack(spacing: WarmSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    // 小字行：今日 tab 显示完整日期（+问候语）；
                    // 日历 tab 显示年份（月模式）/ 周范围（周模式）——月份名已在大标题，
                    // 避免与大标题、网格重复出现月份信息（页头合并改版）。
                    HStack(spacing: WarmSpacing.xs) {
                        Text(selectedBottomTab == .today
                             ? formattedHomeDate(Date())
                             : HomeCalendarState.periodCaption(anchor: visibleMonthAnchor, viewMode: calendarViewMode, calendar: calendar))
                            .font(WarmFont.caption(14))
                            .foregroundColor(WarmTheme.textSecondary)

                        if selectedBottomTab == .today {
                            Text(greetingText)
                                .font(WarmFont.displayLight(18))
                                .foregroundColor(WarmTheme.primaryDark.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    // 大标题行：日历 tab 下翻月/回今天按钮跟在月份名右侧
                    // （原来在日历卡片内部的导航行，合并到页头后卡片内导航行已删除）。
                    HStack(spacing: WarmSpacing.sm) {
                        Text(selectedBottomTab == .today ? todayWeekdayTitle : calendarMonthTitle)
                            .font(WarmFont.serifDisplay(30))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)

                        if selectedBottomTab == .calendar {
                            calendarNavButtons
                        }
                    }
                }

                Spacer()

                if !store.todos.isEmpty && selectedDayStats().total > 0 && calendarLoadState != .error {
                    statsBadge
                }

                settingsButton
            }

            // 导航切换器：Today / Calendar 下划线样式。
            // 方案一核心——导航退到头部（轻量），底部只留动作（FAB）。
            viewSwitcher
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

    // MARK: - View Switcher

    private var viewSwitcher: some View {
        HStack(spacing: WarmSpacing.lg) {
            switcherTab(label: String(localized: "tab.today"), tab: .today)
            switcherTab(label: String(localized: "tab.calendar"), tab: .calendar)
            Spacer()
        }
    }

    private func switcherTab(label: String, tab: BottomTab) -> some View {
        let isSelected = selectedBottomTab == tab
        return Button {
            withAnimation(WarmAnimation.springFast) { selectedBottomTab = tab }
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(WarmFont.headline(14))
                    .foregroundColor(isSelected ? WarmTheme.textPrimary : WarmTheme.textMuted)
                Capsule()
                    .fill(isSelected ? WarmTheme.primary : Color.clear)
                    .frame(width: 20, height: 2)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(tab.accessibilityIdentifier)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Calendar tab 的大标题：当前可见月份名（"July" / "七月"），替代冗余的 "Calendar" 字面量。
    private var calendarMonthTitle: String {
        visibleMonthAnchor.formatted(.dateTime.month(.wide))
    }

    /// 当前是否停在今天（选中今天 + 可见月为本月）——true 时隐藏"回今天"按钮。
    /// 与旧版日历卡片内导航行的 isOnToday 判断一致。
    private var isCalendarOnToday: Bool {
        calendar.isDateInToday(selectedDate) && calendar.isDate(visibleMonthAnchor, equalTo: Date(), toGranularity: .month)
    }

    /// 页头大标题右侧的日历导航按钮簇：回今天（非今天时）+ 上/下翻月（周视图为翻周）。
    /// 保留原日历卡片导航行的 accessibility id 与 label，UITest 与 VoiceOver 行为不变。
    private var calendarNavButtons: some View {
        HStack(spacing: WarmSpacing.xs) {
            if !isCalendarOnToday {
                Button(action: jumpToToday) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WarmTheme.primaryDark)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TodayMonthButton")
                .accessibilityLabel(String(localized: calendarViewMode == .week ? "a11y.today_week" : "a11y.today_month"))
            }

            Button(action: { shiftPeriod(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(WarmTheme.secondaryBackground))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("PreviousMonthButton")
            .accessibilityLabel(String(localized: calendarViewMode == .week ? "a11y.previous_week" : "a11y.previous_month"))

            Button(action: { shiftPeriod(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(WarmTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(WarmTheme.secondaryBackground))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NextMonthButton")
            .accessibilityLabel(String(localized: calendarViewMode == .week ? "a11y.next_week" : "a11y.next_month"))
        }
    }

    private var todayWeekdayTitle: String {
        Date().formatted(.dateTime.weekday(.wide))
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
        let (total, completed) = selectedDayStats()
        let isAllCompleted = total > 0 && completed == total
        let text = isAllCompleted
            ? String(localized: "home.stats.all_complete")
            : String(format: String(localized: "home.stats %lld %lld"), completed, total)
        return HStack(spacing: WarmSpacing.xs) {
            if isAllCompleted {
                Text("🎉")
                    .font(.system(size: 14))
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(WarmTheme.primary)
            }

            Text(text)
                .font(WarmFont.caption(14))
                .foregroundStyle(isAllCompleted ? WarmTheme.primaryDark : WarmTheme.textSecondary)
        }
        .padding(.horizontal, WarmSpacing.xs)
        .padding(.vertical, WarmSpacing.xxs)
        .background(Capsule().fill((isAllCompleted ? WarmTheme.primary.opacity(0.16) : WarmTheme.secondaryBackground.opacity(0.5))))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("HomeStatsBadge")
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
            // 月历封顶 44% 高度（硬约束，见 HomeLayoutMetrics.calendarTargetHeightRatio）。
            // 极矮屏日期行可能被裁切（overflow:hidden 语义）；列表区始终 ≥ 56% 可滚动。
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
                        onSelectDay: selectDay,
                        onDropTodo: { todoId, date in assignTodoToDate(todoId, date: date) },
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
                        selectedBottomTab: selectedBottomTab,
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
            // 全屏手势:整个屏幕(日历 + 列表)上下滑切换月/周。
            // 上滑→周(放大细节),下滑→月(缩小概览)。
            // 用 SimultaneousDragGesture(UIKit UIGestureRecognizer 包装)让列表滚动和拖拽共存——
            // iOS 26 起 SwiftUI .simultaneousGesture 在容器内失效(FB18199844),改走 UIKit 路径。
            .gesture(
                SimultaneousDragGesture(minimumDistance: HomeLayoutMetrics.viewModeDragThreshold) { drag in
                    let vertical = abs(drag.translation.height)
                    let horizontal = abs(drag.translation.width)
                    guard vertical > horizontal else { return }
                    if drag.translation.height < -HomeLayoutMetrics.viewModeSwitchThreshold,
                       calendarViewMode != .week {
                        setViewMode(.week)
                    } else if drag.translation.height > HomeLayoutMetrics.viewModeSwitchThreshold,
                              calendarViewMode != .month {
                        setViewMode(.month)
                    }
                }
            )
            .accessibilityAction(named: Text(calendarViewMode == .month
                                             ? String(localized: "a11y.switch_to_week")
                                             : String(localized: "a11y.switch_to_month"))) {
                setViewMode(calendarViewMode == .month ? .week : .month)
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
                transcript: coordinator.transcript,
                audioLevel: coordinator.audioLevel,
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

    /// 拖拽赋日期：从 Unscheduled 拖任务到日历格 → 设置 dueDate
    private func assignTodoToDate(_ todoId: UUID, date: Date) {
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            VoiceTodoLog.ui.warning("home.drag_assign.todo_not_found id=\(todoId.uuidString, privacy: .public)")
            return
        }
        let day = calendar.startOfDay(for: date)
        do {
            try coordinator.updateTodoDetail(
                todoId,
                update: TodoDetailUpdate(
                    title: todo.title,
                    detail: todo.detail,
                    category: nil,
                    priority: nil,
                    dueDate: day,
                    hasDueTime: false,
                    timeBucket: todo.timeBucket,
                    // 空字符串会被规范化为 nil，确保旧 hint（如"明天"）不与新 dueDate 矛盾。
                    dueHint: "",
                    // 保留原重复规则：TodoDetailUpdate 是完整替换语义，传 nil 会清除规则。
                    recurrenceRule: todo.recurrenceRule
                )
            )
            occurrenceRevision += 1
            coordinator.showToast(
                message: String(format: String(localized: "home.assigned_to_date"),
                                todo.title, TodoRelativeDateFormatter.format(day)),
                style: .success
            )
        } catch {
            VoiceTodoLog.store.error("home.drag_assign.failed id=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }
}

// MARK: - A2 自动学习建议 Banner

private struct GlossarySuggestionBanner: View {
    let suggestion: GlossarySuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: WarmSpacing.sm) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "suggestion.banner_prefix") + "「\(suggestion.correction.originalTitle)」")
                    .font(WarmFont.body(13))
                    .foregroundColor(WarmTheme.textPrimary)
                + Text(String(localized: "suggestion.banner_changed_to") + "「\(suggestion.correction.confirmedTitle)」")
                    .font(WarmFont.body(13))
                    .foregroundColor(WarmTheme.primary)
                Text(String(localized: "suggestion.banner_question"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
            }

            Spacer()

            VStack(spacing: 6) {
                Button(action: onAccept) {
                    Text(String(localized: "suggestion.remember"))
                        .font(WarmFont.headline(13))
                        .foregroundColor(.white)
                        .padding(.horizontal, WarmSpacing.md)
                        .padding(.vertical, WarmSpacing.xxs)
                        .background(Capsule().fill(WarmTheme.primary))
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text(String(localized: "suggestion.dismiss"))
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(WarmSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(WarmTheme.background)
                .shadow(color: WarmTheme.shadowLight, radius: 8, y: 2)
        )
    }
}


