import SwiftUI
import UIKit
import WidgetKit

private func formattedHomeDate(_ date: Date) -> String {
    // 只给「月 日」（"7月17日" / "Jul 17"）：星期已由旁边的大标题（todayWeekdayTitle）承担，
    // 这里再带 weekday 会重复。
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
    /// 动态效果减弱开关。沿用 OnboardingView 的处理:动画用 motionAnim() 包一层,
    /// 开启时返回 nil 让 SwiftUI 直接跳终值,不播。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var selectedDate = DayClock.startOfUserDay(for: Date())
    @State private var visibleMonthAnchor = Calendar.current.startOfDay(for: Date())
    @State private var hasStartedEntranceAnimation = false
    /// 今日进度环入场进度:0→1 驱动底环 trim 与进度弧 trim(顺时针绘制)。
    /// 会话级状态——HomeView 在 App 级长期存活,切 tab 不重置。
    @State private var ringEntranceProgress: CGFloat = 0
    /// 会话内只播一次入场动画的标记。0/0 启动场景下保持 false,
    /// 直到用户新建第一个任务走 onChange 路径补播。
    @State private var hasPlayedRingEntrance: Bool = false
    /// 月历 occurrence 缓存：由后台 `queryActor` 异步加载，主线程不再做 SwiftData fetch/展开。
    /// `.task(id:)` 在 visibleMonthAnchor / store.todos / occurrenceRevision 变化时刷新。
    @State private var monthOccurrences: [String: [TodoOccurrenceData]] = [:]
    @State private var calendarLoadState: HomeCalendarLoadState = .loading
    /// 规律任务 occurrence 完成切换不会改 `store.todos`（完成记录在独立表），用此 revision 强制刷新。
    @State private var occurrenceRevision = 0
    @AppStorage(CalendarWriteMode.storageKey) private var calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
    /// 网格折叠进度(0=展开满屏 6 行, 1=折叠到选中日所在周 1 行 + 任务列表)。
    /// 生命周期:与 HomeView 的 View identity 绑定。HomeView 在 App 级别长期存活,
    /// 切 tab 不会销毁重建 HomeView,因此 collapseProgress 在 tab 切换间自然保留。
    /// 切月 / jumpToToday 不重置:折叠是"视图密度偏好",与"看哪天/哪月"正交。
    @State private var collapseProgress: CGFloat = 0
    /// 手势起始时的 collapseProgress,首次 onChanged 时捕获。
    @State private var gestureAnchorProgress: CGFloat = 0
    /// 是否正在跟手(首次 onChanged=true, onEnded/onCancelled=false)。
    @State private var isCollapseGesturing = false

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
    /// 入场动画偏移/透明度。只作用于 Today tab 的 List;Calendar tab 的网格/WeekStripCard
    /// 走 collapseProgress 驱动,不经过这两个 State。
    @State private var listOffset: CGFloat = 30
    @State private var listOpacity: Double = 0
    @State private var cardAppeared: Set<UUID> = []

    /// Calendar tab 下「未安排的」底部抽屉展开态。
    /// 默认折叠(unscheduled 多时视觉干净);Today tab 不用 drawer,此状态无意义。
    @State private var unscheduledDrawerExpanded: Bool = false

    /// 本周完成数(用于首页"本周小结"卡片)。
    private var weeklyCompletedCount: Int {
        let cal = Calendar.current
        let today = DayClock.startOfUserDay(for: Date(), calendar: cal)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        return store.todos.filter { $0.isCompleted }.filter { todo in
            guard let completed = todo.completedAt else { return false }
            let day = DayClock.startOfUserDay(for: completed, calendar: cal)
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
                    // 拖拽时整体淡出 + 高度收(回顾类信息,与当下排程动作无关——用户原话)。
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
                        .frame(height: HomeLayoutMetrics.weeklySummaryRowHeight, alignment: .top)
                        .clipped()
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
                // 输入面板展开 OR Calendar tab 的 unscheduled drawer 展开 → FAB 完全移除
                // (drawer 展开时需要释放底部空间——之前用 .opacity(0) 会让 safeAreaInset
                // 仍保留 FAB 的布局高度,变成「挡板」压缩 drawer 可用区域。
                // 条件渲染 + .transition(.opacity) 既释放空间又保留淡入淡出动画。)
                if !(showInputPanel || (selectedBottomTab == .calendar && unscheduledDrawerExpanded)) {
                    VoiceFAB(
                        isDisabled: isInputEntryDisabled,
                        onTap: { openVoiceInputPanel() }
                    )
                    .transition(.opacity)
                }
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
            .onChange(of: todayTotalCount) { oldTotal, newTotal in
                // 启动时是 0/0(环没入场)、之后用户新建第一个任务:补一次入场动画,
                // 等同于"首次有内容"。playRingEntranceIfNeeded 内部 gate 保证会话内只播一次。
                // 注意 trigger 必须用 todayTotalCount 而非 store.todos.count:
                // 场景"今日 0/0 但其他日子有任务"下,store.todos.count 永远 >0,
                // 用它做 trigger 永远不会进入此分支——补播会失效。
                if oldTotal == 0, newTotal > 0 {
                    playRingEntranceIfNeeded()
                }
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
        // 单次计算当日统计,避免 statsBadgeHiddenForToday / todayProgressCluster 各调一遍。
        let dayStats = selectedDayStats()
        let statsHidden = store.todos.isEmpty || dayStats.total == 0 || calendarLoadState == .error
        return VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            // 左右分布（对齐 HTML 设计稿）：左=标题组，右=进度环+设置齿轮。
            // 拖拽时整行向上滑出 + 淡出(导航类,与当下排程动作无关)。
            HStack(alignment: .center, spacing: WarmSpacing.md) {
                if selectedBottomTab == .today {
                    // 今日 tab：星期几（主，大字）+ 日期（副，小灰字），基线对齐。
                    // 问候语已按设计稿移除。
                    HStack(alignment: .firstTextBaseline, spacing: WarmSpacing.sm) {
                        Text(todayWeekdayTitle)
                            .font(WarmFont.serifDisplay(30))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)

                        Text(formattedHomeDate(Date()))
                            .font(WarmFont.caption(14))
                            .foregroundColor(WarmTheme.textSecondary)
                    }
                } else {
                    // 日历 tab：月份标题；浏览月/周 ≠ 当前时，标题后挂一个小回退箭头，
                    // 整个「标题 + 箭头」作为一个 Button 跳回今天。
                    //
                    // 设计取舍：原先用"回到今天"文字胶囊——英文"Back to today"较长，
                    // 叠上长月份名（"September"）+ Grid 按钮 + 齿轮，一整行会超宽，
                    // 月份名被挤到几乎 0 宽、向左滑月份时直接"消失"。改成 chevron 后
                    // 占用宽度从 ~100pt 压到 ~16pt，月份名恒定拿到所需空间。
                    //
                    // monthTitleText 是「当前月 Text」与「backToTodayTitleButton 内 Text」
                    // 的共享样式来源——避免两处字号/颜色/scaleFactor 分叉。
                    //
                    // layoutPriority(1) 保护月份标题优先于 Spacer/statsBadge/Grid 按钮拿到
                    // 所需宽度，避免再次触发月份名被挤到 0 宽（不论当前/非当前月分支均需要）。
                    if isViewingCurrentPeriod {
                        monthTitleText
                            .frame(minHeight: WarmSize.touch, alignment: .center)
                            .layoutPriority(1)
                    } else {
                        backToTodayTitleButton
                            .layoutPriority(1)
                    }
                }

                Spacer()

                if !statsHidden {
                    todayProgressCluster(total: dayStats.total, completed: dayStats.completed)
                        .transition(.opacity)
                }

                settingsButton
            }
            .animation(motionAnim(.easeOut(duration: 0.3)), value: statsHidden)

            viewSwitcher
                .frame(height: HomeLayoutMetrics.viewSwitcherRowHeight, alignment: .top)
                .clipped()
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
            withAnimation(WarmAnimation.springFast) {
                selectedBottomTab = tab
                // 切到 Today tab 时 drawer 状态无意义,reset 避免下次切回 Calendar 突然展开。
                if tab != .calendar {
                    unscheduledDrawerExpanded = false
                }
            }
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(WarmFont.headline(14))
                    .foregroundColor(isSelected ? WarmTheme.textPrimary : WarmTheme.textMuted)
                Capsule()
                    // tab 下划线用 textPrimary 而非 primary:视觉改版后 primary 收回
                    // 只用于"当前日期高亮圆 + 麦克风按钮",tab 导航属次要元素。
                    .fill(isSelected ? WarmTheme.textPrimary : Color.clear)
                    .frame(width: 20, height: 2)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(tab.accessibilityIdentifier)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Calendar tab 的大标题：当前可见月份（"9月" / "Sep"，对齐设计稿的紧凑数字月份）。
    /// 跨年浏览时带上年份（"2027年1月" / "Jan 2027"）——单独的年份小字行已按设计稿删除。
    private var calendarMonthTitle: String {
        if calendar.isDate(visibleMonthAnchor, equalTo: Date(), toGranularity: .year) {
            return visibleMonthAnchor.formatted(.dateTime.month())
        }
        return visibleMonthAnchor.formatted(.dateTime.year().month())
    }

    /// 当前浏览的月（周视图为周）是否就是今天所在的月/周。
    /// 设计稿规则：只按月/周判断，不看选中的具体某天——停在本月就不渲染「回到今天」胶囊。
    private var isViewingCurrentPeriod: Bool {
        calendar.isDate(
            visibleMonthAnchor,
            equalTo: Date(),
            toGranularity: .month
        )
    }

    /// 日历 tab 月份标题的共享样式（当前月 Text 与 `backToTodayTitleButton` 内的 Text 共用）。
    /// 提取为单一来源避免两处 font/color/scaleFactor 分叉。
    private var monthTitleText: some View {
        Text(calendarMonthTitle)
            .font(WarmFont.serifDisplay(30))
            .foregroundColor(WarmTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    /// 「回到今天」标题按钮：月份名 + 小回退箭头（chevron.left），整个区域可点。
    /// 仅当浏览月/周 ≠ 今天所在月/周时渲染；点击跳回今天并选中今天。
    ///
    /// 取代原"回到今天"文字胶囊——胶囊宽度（~100pt）在英文 locale + 长月份名下
    /// 会挤占月份标题，导致向左滑月份时月份名被压成 0 宽消失。chevron 仅占 ~16pt，
    /// 让月份名恒定拿到完整宽度。
    ///
    /// 设计约束：
    /// - `monthTitleText` 复用月份标题样式，保证与当前月分支视觉一致。
    /// - `frame(minHeight: WarmSize.touch)` 把整个 HStack 撑到 ≥ 44pt 以满足 HIG 点击目标，
    ///   与当前月分支 frame 对齐避免切月时标题位置跳动。
    private var backToTodayTitleButton: some View {
        Button(action: jumpToToday) {
            HStack(spacing: 4) {
                monthTitleText

                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WarmTheme.primary)
            }
            .frame(minHeight: WarmSize.touch, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TodayMonthButton")
        .accessibilityLabel(String(localized: "a11y.today_month"))
    }

    private var todayWeekdayTitle: String {
        Date().formatted(.dateTime.weekday(.wide))
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
        let day = DayClock.startOfUserDay(for: selectedDate, calendar: calendar)
        let onDay = store.todos.filter { todo in
            guard let due = todo.dueDate else { return false }
            return DayClock.isSameUserDay(due, day, calendar: calendar)
        }
        let completed = onDay.filter { $0.isCompleted }.count
        return (onDay.count, completed)
    }

    /// 今日总数,仅用于 playRingEntranceIfNeeded 的 gate 检查(不在 body 中调用,
    /// 避免 .onChange 热路径上重复跑 filter 遍历)。headerView 里的 dayStats 单算一次。
    private var todayTotalCount: Int {
        selectedDayStats().total
    }

    /// "今天 (0/3)" + 进度环 的合并外壳。
    /// 合并后才能让 transition(.opacity) 同步作用于标签和环(整体淡入淡出),
    /// 并让 accessibilityElement 合并成一个可访问性节点(沿用 HomeStatsBadge id)。
    /// total/completed 由 headerView 单次计算传入,避免重复调 selectedDayStats()。
    private func todayProgressCluster(total: Int, completed: Int) -> some View {
        let progress = total > 0 ? Double(completed) / Double(total) : 0
        return HStack(spacing: WarmSpacing.xs) {
            todayProgressLabel(completed: completed, total: total)
            progressRing(progress: progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "home.stats %lld %lld"), completed, total))
        .accessibilityIdentifier("HomeStatsBadge")
    }

    /// "今天 (0/3)" 标签。"今天"用主色,数字用次级灰。
    /// monospacedDigit 防数字字宽变化抖动(0/3 → 1/3 切换);fixedSize 防外层 frame 压榨宽度。
    private func todayProgressLabel(completed: Int, total: Int) -> some View {
        HStack(spacing: WarmSpacing.xxs) {
            Text(String(localized: "home.today"))
                .font(WarmFont.caption(13))
                .foregroundStyle(WarmTheme.textPrimary)
            Text("(\(completed)/\(total))")
                .font(WarmFont.caption(13))
                .monospacedDigit()
                .foregroundStyle(WarmTheme.textSecondary)
        }
        .fixedSize()
    }

    /// 44pt 纯环,无中心文字。底环 + 进度弧。
    /// trim 受 ringEntranceProgress 驱动:入场时底环 trim 0→1(从 12 点顺时针绘制),
    /// 进度弧 trim 同步增长到 progress。两段动画各自独立声明,入场 0.6s / 完成补动画 0.3s。
    private func progressRing(progress: Double) -> some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringEntranceProgress)
                .stroke(WarmTheme.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: progress * ringEntranceProgress)
                .stroke(WarmTheme.primary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 44, height: 44)
        .shadow(color: WarmTheme.primary.opacity(0.15), radius: 4)
        .animation(motionAnim(.easeOut(duration: 0.3)), value: progress)
        .animation(motionAnim(.easeOut(duration: 0.6)), value: ringEntranceProgress)
    }

    private var settingsButton: some View {
        // 去玻璃 + 缩小：原 .buttonStyle(.glass) + .glassEffect(.regular) 会让 44×44 的圆形
        // 玻璃背板在 header 里视觉过重。设置是低频次要入口，去掉背板改用 .plain。
        // 视觉占 36×36（WarmSize.secondaryHit），但外层 frame 撑到 WarmSize.touch(44)
        // 保证 HIG 最小 hit target——不靠 .plain 的默认行为，hit target 在此显式声明。
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WarmTheme.textSecondary)
                .frame(width: WarmSize.secondaryHit, height: WarmSize.secondaryHit)
                .frame(width: WarmSize.touch, height: WarmSize.touch)
                // Rectangle 对齐外层 44pt frame——整个 HIG 最小 hit target 都可点击，
                // 不能用 Circle()（会只让内层 36pt 圆区可点）。
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// 渲染日历内容视图(月历网格)。`rowHeightBasis` 是"用于算行高的基准高度",
    /// 通常是展开态满高度(fullHeight)——折叠过程不改行高,只靠外层 frame + offset 动作。
    /// 外层 `.frame(height: calendarHeight)` + `.clipped()` 封顶(见 monthHomeView)。
    @ViewBuilder
    private func calendarContentView(state: HomeCalendarState, rowHeightBasis: CGFloat) -> some View {
        HomeMonthHeaderView(
            state: state,
            onSelectDay: selectDay,
            onDropTodo: { todoId, date in assignTodoToDate(todoId, date: date) },
            onShiftPeriod: { shiftPeriod(by: $0) },
            availableHeight: rowHeightBasis
        )
    }

    private var monthHomeView: some View {
        let state = HomeCalendarState.make(
            store: store,
            selectedDate: selectedDate,
            visibleMonthAnchor: visibleMonthAnchor,
            occurrencesByDay: monthOccurrences,
            calendar: calendar
        )
        // 选中日在 42 格里的行索引(0-5),折叠时把选中周推到顶部。
        // 提到 GeometryReader 外:只依赖 visibleMonthAnchor / selectedDate,与 proxy.size 无关,
        // 避免 60fps 跟手时每帧重做 42 次 isDate(inSameDayAs:) 调用(NSCalendar 桥接,有开销)。
        // firstIndex 找不到时退回 0(选中日不在当月网格内,折叠 offset=0 等价于"不动")。
        // 此情况只在 visibleMonthAnchor 与 selectedDate 不同步时发生——
        // 正常路径(shiftPeriod / jumpToToday)会同时更新两者,保持同步。
        let selectedRowIndex = CGFloat(
            min((state.visibleDays.firstIndex { calendar.isDate($0, inSameDayAs: selectedDate) } ?? 0) / 7, 5)
        )

        return GeometryReader { proxy in
            let fullHeight = HomeLayoutMetrics.calendarExpandedHeight(
                availableHeight: proxy.size.height,
                selectedTab: selectedBottomTab
            )
            // 行高固定用展开态(fullHeight)算:折叠时只靠外层 frame+offset 动作,不改每行 intrinsic 高度。
            // 若用动态 calendarHeight 算,折叠过程每帧 relayout 42 格会掉帧。
            let actualRowHeight = HomeLayoutMetrics.dayRowHeight(availableHeight: fullHeight)
            // rowStride 必须与 HomeMonthHeaderView 内 VStack 的 spacing 一致(gridRowSpacing=2),
            // 否则折叠 offset 会偏移过多/过少,选中周被推出视口。
            let rowStride = actualRowHeight + HomeLayoutMetrics.gridRowSpacing
            // 折叠态高度 = 固定段 + 1 行实际行高。不能用 gridMonthMinRowHeight 兜底值——
            // 实际行高(随屏幕变大)会 > 80pt,折叠容器装不下整行就截断。
            let collapsedHeight = HomeLayoutMetrics.calendarFixedSectionHeight + actualRowHeight
            let calendarHeight = fullHeight + (collapsedHeight - fullHeight) * collapseProgress
            let gridOffset = selectedRowIndex * rowStride * collapseProgress

            VStack(spacing: 0) {
                if selectedBottomTab == .calendar {
                    ZStack(alignment: .top) {
                        // 展开态:完整月网格(淡出)
                        // allowsHitTesting 与 WeekStripCard 共用 0.5 阈值:progress > 0.5 时网格
                        // 已淡到 < 50%,关掉命中避免与 WeekStripCard 形成双层响应;progress <= 0.5 时
                        // WeekStripCard 关命中,网格独占。两层在任意 progress 下有且仅有一个可点击。
                        calendarContentView(state: state, rowHeightBasis: fullHeight)
                            .frame(height: calendarHeight, alignment: .top)
                            .offset(y: -gridOffset)
                            .clipped()
                            .opacity(1 - collapseProgress)
                            .allowsHitTesting(collapseProgress <= 0.5)

                        // 折叠态:周条卡片(淡入)
                        WeekStripCard(
                            state: state,
                            onSelectDay: selectDay,
                            onExpand: {
                                withAnimation(WarmAnimation.springStandard) {
                                    collapseProgress = 0
                                }
                            }
                        )
                        .padding(.horizontal, WarmSpacing.xl)
                        .padding(.top, WarmSpacing.xxs)
                        .opacity(collapseProgress)
                        .allowsHitTesting(collapseProgress > 0.5)
                    }
                    .frame(height: calendarHeight, alignment: .top)
                    .clipped()
                }

                switch calendarLoadState {
                case .loading:
                    HomeCalendarLoadingView()
                case .error:
                    HomeCalendarErrorView(onRetry: retryCalendarLoad)
                case .empty, .success:
                    // Today tab: 列表占整屏(月网格不渲染,calendarHeight=0 → listHeight=proxy.size.height);
                    // Calendar tab 展开态(collapseProgress=0):网格占满 95% 高度已显示事件概览,
                    // 下方仅 5% 余量不足以放列表 → 不渲染列表,用户下滑折叠后才出现列表。
                    // Calendar tab 折叠态(collapseProgress > collapseListVisibleThreshold=0.3):
                    // 网格收成 WeekStripCard,下方腾出空间渲染任务列表,随 progress 淡入并可点击。
                    let listHeight = max(0, proxy.size.height - calendarHeight)
                    let isCalendarList = selectedBottomTab == .calendar
                    // 列表渲染阈值 0.3:progress 超过此值才挂载列表,提前挂载让 opacity 有时间渐入。
                    // 命中阈值 0.5:对齐网格 allowsHitTesting(progress<=0.5) + WeekStripCard (>0.5),
                    // 任意 progress 下有且仅有一层可点击,避免双层响应。
                    // opacity 跟随 progress 渐变,0.3→0.5 之间列表淡入但不可点击(网格仍独占交互)。
                    let listInteractive = !isCalendarList || collapseProgress > HomeLayoutMetrics.collapseListVisibleThreshold
                    if listInteractive {
                        HomeSelectedDayListView(
                            state: state,
                            selectedBottomTab: selectedBottomTab,
                            cardAppeared: $cardAppeared,
                            onToggleTodo: { actions.toggleTodo($0) },
                            onToggleOccurrence: { actions.toggleOccurrence($0) },
                            onDeleteTodo: { actions.deleteTodo($0) },
                            onOpenTodo: { selectedTodo = $0 },
                            onMoveToBucket: { id, bucket in assignTodoToBucket(id, bucket: bucket) },
                            onMoveToTomorrow: { id in moveTodoToTomorrow(id) }
                        )
                        .frame(height: listHeight)
                        .opacity(isCalendarList ? collapseProgress : 1)
                        .allowsHitTesting(!isCalendarList || collapseProgress > 0.5)
                        .clipped()
                    }
                }
            }
            // 上下滑手势:驱动网格折叠/展开。连续跟手,松手 snap。
            // 左右滑翻月在 HomeMonthHeaderView 内部处理(方向判定互斥)。
            .gesture(
                SimultaneousDragGesture(
                    minimumDistance: HomeLayoutMetrics.collapseDragThreshold,
                    onChanged: { drag in
                        let vertical = abs(drag.translation.height)
                        let horizontal = abs(drag.translation.width)
                        guard vertical > horizontal else { return }
                        if !isCollapseGesturing {
                            isCollapseGesturing = true
                            gestureAnchorProgress = collapseProgress
                        }
                        // delta 计算扣掉 collapseDragThreshold:UIKit 派发首帧 onChanged 时
                        // translation.height 可能已 = ±40pt(minimumDistance 拦掉前 40pt),
                        // 不扣阈值会让 delta 瞬时跳 ±0.5,视觉上折叠动画"瞬移半屏"。
                        // 扣阈值后首帧 delta=0,后续位移按 (travelDistance - threshold) 满量算 progress。
                        let effective = abs(drag.translation.height) - HomeLayoutMetrics.collapseDragThreshold
                        let travel = HomeLayoutMetrics.collapseTravelDistance - HomeLayoutMetrics.collapseDragThreshold
                        // travel 必须为正:collapseTravelDistance 必须 > collapseDragThreshold(见 HomeLayoutMetrics 注释)。
                        // 若常量被误改导致 travel <= 0,除以零/负数会产生 NaN/infinity,破坏 collapseProgress。
                        // guard 兜底:travel 不合法时复位 isCollapseGesturing(否则 onEnded 读陈旧 anchor),
                        // 并 snap 到展开稳态 0,避免 NaN 污染 UI 状态。
                        guard travel > 0 else {
                            isCollapseGesturing = false
                            withAnimation(WarmAnimation.springStandard) {
                                collapseProgress = 0
                            }
                            return
                        }
                        let magnitude = max(0, effective) / travel
                        let delta = drag.translation.height < 0 ? magnitude : -magnitude
                        collapseProgress = max(0, min(1, gestureAnchorProgress + delta))
                    },
                    onEnded: { drag in
                        guard isCollapseGesturing else { return }
                        isCollapseGesturing = false
                        // 不再按 vertical > horizontal 门控:onChanged 已确认手势起始方向为垂直,
                        // 即使 onEnded 时累计位移因弧形滑动翻成水平主导,也必须 snap 到稳态,
                        // 否则 collapseProgress 卡在中间值(半折叠 + 列表半透明)无动画回收。
                        let target: CGFloat
                        if abs(drag.velocity.dy) > HomeLayoutMetrics.collapseFlickVelocity {
                            target = drag.velocity.dy < 0 ? 1 : 0
                        } else {
                            target = collapseProgress > 0.5 ? 1 : 0
                        }
                        withAnimation(WarmAnimation.springStandard) {
                            collapseProgress = target
                        }
                    },
                    onCancelled: {
                        // 手势被系统中断(.cancelled / .failed):不复位 isCollapseGesturing 会让
                        // 下次手势的 anchor 捕获落到 `if !isCollapseGesturing` 的 else 分支,
                        // 基于陈旧 gestureAnchorProgress 累加 delta,产生视觉跳跃。
                        // snap 到最近稳态(0 或 1):中断时 progress 停在中间态会让列表半透明
                        // 且 allowsHitTesting=true,与半折叠的网格形成未定义交互态。
                        guard isCollapseGesturing else { return }
                        isCollapseGesturing = false
                        let target: CGFloat = collapseProgress > 0.5 ? 1 : 0
                        withAnimation(WarmAnimation.springStandard) {
                            collapseProgress = target
                        }
                    }
                )
            )
            .accessibilityActions {
                if selectedBottomTab == .calendar {
                    Button(String(localized: "a11y.previous_month")) {
                        shiftPeriod(by: -1)
                    }
                    Button(String(localized: "a11y.next_month")) {
                        shiftPeriod(by: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .offset(y: listOffset)
        .opacity(listOpacity)
        .accessibilityIdentifier("MonthHomeView")
        .task(id: CalendarRefreshKey(anchor: visibleMonthAnchor, todos: store.todos, revision: occurrenceRevision)) {
            let startedAt = Date()
            if calendarLoadState == .error {
                calendarLoadState = .loading
            }
            let rangeDays = HomeCalendarState.monthDays(for: visibleMonthAnchor, calendar: calendar)
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
            // 切日时折叠 unscheduled drawer:新日期的 unscheduled 列表不同,
            // 保持展开会让用户先看到旧列表动画切换,视觉跳跃;统一回到折叠态。
            unscheduledDrawerExpanded = false
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
            let today = DayClock.startOfUserDay(for: Date(), calendar: calendar)
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

        playRingEntranceIfNeeded()
    }

    /// 动效减弱时返回 nil,关闭 SwiftUI 隐式动画。沿用 OnboardingView 同名 helper 风格。
    private func motionAnim(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// 今日进度环入场动画:底环从 12 点顺时针绘制,进度弧同步增长。
    /// 触发规则(会话内"只播一次"):
    ///   - Gate 1: total > 0(0/0 时环根本不显示,无需播)
    ///   - Gate 2: !hasPlayedRingEntrance(切走再切回、删光再重建都不重播)
    ///   - reduceMotion: 直接跳终值
    /// 另有 .onChange(of: todayTotalCount) 路径处理"启动时 0/0、之后新建任务"的补播场景。
    private func playRingEntranceIfNeeded() {
        guard !hasPlayedRingEntrance else { return }
        guard todayTotalCount > 0 else { return }
        hasPlayedRingEntrance = true

        if reduceMotion {
            ringEntranceProgress = 1
            return
        }
        // ringEntranceProgress 初始值为 0,gate 保证此函数会话内只执行一次,
        // 因此无需先显式归零——直接 withAnimation 从当前值(0)动画到 1。
        withAnimation(.easeOut(duration: 0.6)) {
            ringEntranceProgress = 1
        }
    }

    /// 翻月：按月向前/向后。
    private func shiftPeriod(by value: Int) {
        guard let newAnchor = calendar.date(byAdding: .month, value: value, to: visibleMonthAnchor) else {
            return
        }
        let normalizedAnchor = HomeCalendarState.startOfMonth(for: newAnchor, calendar: calendar)
        withAnimation(WarmAnimation.springStandard) {
            visibleMonthAnchor = normalizedAnchor
            selectedDate = normalizedAnchor
        }
    }

    private func jumpToToday() {
        let today = DayClock.startOfUserDay(for: Date(), calendar: calendar)
        withAnimation(WarmAnimation.springStandard) {
            selectedDate = today
            visibleMonthAnchor = today
            // 不设 selectedBottomTab——日历里"今天"按钮只让月历跳到今天位置，
            // 不切底部 tab。底部 tab 切"今日"时 onChange 会调此方法设 selectedDate。
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

    /// Bucket slot「+ 设钟点」入口:把传入的 hour/minute 合入选中日的 dueDate,
    /// 写 `hasDueTime=true + timeBucket=nil`(TimeBucketResolver 走钟点派生分支)。
    /// `hourMinute` 的日期部分被丢弃,只取 hour/minute;选 0:00 也能写入(夜班场景)。
    private func setTodoHour(_ todoId: UUID, hourMinute: Date) {
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            VoiceTodoLog.ui.warning("home.set_hour.todo_not_found id=\(todoId.uuidString, privacy: .public)")
            return
        }
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: hourMinute)
        var combined = dayComponents
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        guard let dueDate = calendar.date(from: combined) else {
            VoiceTodoLog.ui.error("home.set_hour.combined_date_invalid id=\(todoId.uuidString, privacy: .public)")
            return
        }
        do {
            try coordinator.updateTodoDetail(
                todoId,
                update: TodoDetailUpdate(
                    title: todo.title,
                    detail: todo.detail,
                    category: nil,
                    priority: nil,
                    dueDate: dueDate,
                    hasDueTime: true,
                    // 有钟点 → timeBucket 自动派生(传 nil 由 init 归零 + Resolver 走钟点分支)。
                    timeBucket: nil,
                    dueHint: "",
                    recurrenceRule: todo.recurrenceRule
                )
            )
            occurrenceRevision += 1
            coordinator.showToast(
                message: String(format: String(localized: "home.timeline.hour_assigned"),
                                todo.title, HomeViewHourFormatter.string(from: dueDate)),
                style: .success
            )
        } catch {
            VoiceTodoLog.store.error("home.set_hour.failed id=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }

    /// drawer → timeline bucket slot 拖拽落点:把 unscheduled 任务排到选中日的某 bucket。
    /// 写 `dueDate=选中日(00:00) + hasDueTime=false + timeBucket=bucket`,
    /// `TimeBucketResolver` 走 explicitBucket 分支派生(覆盖原 bucket)。
    /// 跟 `assignTodoToDate`(用原 timeBucket)语义不同,不能共用。
    private func assignTodoToBucket(_ todoId: UUID, bucket: TimeBucket) {
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            VoiceTodoLog.ui.warning("home.assign_bucket.todo_not_found id=\(todoId.uuidString, privacy: .public)")
            return
        }
        let day = calendar.startOfDay(for: selectedDate)
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
                    timeBucket: bucket,
                    dueHint: "",
                    recurrenceRule: todo.recurrenceRule
                )
            )
            occurrenceRevision += 1
            coordinator.showToast(
                message: String(format: String(localized: "home.assigned_to_bucket"),
                                todo.title, bucket.localizedTitle),
                style: .success
            )
        } catch {
            VoiceTodoLog.store.error("home.assign_bucket.failed id=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }

    /// Context menu「移到明天」:把任务 dueDate 推到明天(保留原 timeBucket/钟点)。
    /// 跟 `assignTodoToBucket` 不同 —— 那个改 bucket 重置钟点;这个只挪日期不改时段语义。
    /// 已完成的任务走这个路径也合理:用户可能在规划明天的安排时挪已完成的复盘项。
    ///
    /// **依赖契约**:`TodoDetailUpdate` 的 nil 字段(category / priority)语义是「不更新」,
    /// 非 nil 字段(title / detail / dueDate / hasDueTime / timeBucket / dueHint /
    /// recurrenceRule)显式重传 —— 为了只让 dueDate 变化,其他字段传回原值。
    /// 若 TodoDetailUpdate 的语义将来改成「nil = 清空」,这里需同步改用 nil 表示不更新。
    ///
    /// **DST 边界**:`bySettingHour` 在春令时跳变日凌晨 2:00→3:00 时若原钟点是 2:30
    /// 会返回 nil,fallback 到 `tomorrow`(00:00)。这是已知取舍(一年 1-2 次),
    /// 不静默吞错误,但用户预期「明天 2:30」会变成「明天 0:00」。
    private func moveTodoToTomorrow(_ todoId: UUID) {
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            VoiceTodoLog.ui.warning("home.move_to_tomorrow.todo_not_found id=\(todoId.uuidString, privacy: .public)")
            return
        }
        // 用 DayClock.startOfUserDay 算"明天"而非 calendar.date(byAdding:.day, value:1, to: Date()),
        // 保持与 app 其他地方"用户一天起点"的口径一致(自定义 dayStartHour 时不一致会差几小时)。
        let today = DayClock.startOfUserDay(for: Date(), calendar: calendar)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            VoiceTodoLog.ui.error("home.move_to_tomorrow.date_calc_failed id=\(todoId.uuidString, privacy: .public)")
            coordinator.showToast(message: ErrorMessages.dateCalcFailed, style: .warning)
            return
        }
        // 保留原 hasDueTime 和 dueDate 的钟点分量 —— 明天同时段。
        // 若原 hasDueTime=false,dueDate 直接换成明天的 00:00;若 true,需把钟点拼回明天日期上。
        let newDueDate: Date = todo.hasDueTime
            ? (todo.dueDate.map { originalDue in
                calendar.date(bySettingHour: calendar.component(.hour, from: originalDue),
                              minute: calendar.component(.minute, from: originalDue),
                              second: 0, of: tomorrow) ?? tomorrow
            } ?? tomorrow)
            : tomorrow
        do {
            try coordinator.updateTodoDetail(
                todoId,
                update: TodoDetailUpdate(
                    title: todo.title,
                    detail: todo.detail,
                    category: nil,
                    priority: nil,
                    dueDate: newDueDate,
                    hasDueTime: todo.hasDueTime,
                    timeBucket: todo.timeBucket,
                    dueHint: "",
                    recurrenceRule: todo.recurrenceRule
                )
            )
            occurrenceRevision += 1
            coordinator.showToast(
                message: String(format: String(localized: "home.moved_to_tomorrow"), todo.title),
                style: .success
            )
        } catch {
            VoiceTodoLog.store.error("home.move_to_tomorrow.failed id=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }

    /// timeline → drawer 反向拖拽落点:清 dueDate 让任务回 unscheduled。
    /// 保留原 `timeBucket`,下次拖回同 bucket 仍按用户原意图分组(避免被 reset 到 anytime)。
    private func unassignTodoFromDay(_ todoId: UUID) {
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            VoiceTodoLog.ui.warning("home.unassign.todo_not_found id=\(todoId.uuidString, privacy: .public)")
            return
        }
        do {
            try coordinator.updateTodoDetail(
                todoId,
                update: TodoDetailUpdate(
                    title: todo.title,
                    detail: todo.detail,
                    category: nil,
                    priority: nil,
                    dueDate: nil,
                    hasDueTime: false,
                    timeBucket: todo.timeBucket,
                    dueHint: "",
                    recurrenceRule: todo.recurrenceRule
                )
            )
            occurrenceRevision += 1
            coordinator.showToast(
                message: String(format: String(localized: "home.unassigned_from_day"), todo.title),
                style: .success
            )
        } catch {
            VoiceTodoLog.store.error("home.unassign.failed id=\(todoId.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
        }
    }
}

/// 钟点 toast 用的 formatter。HomeView 是 generic struct,不能持有 static stored property,
/// 所以 formatter 提到文件顶层作为独立常量。
private let HomeViewHourFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
}()

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


