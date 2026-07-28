import SwiftUI
import WidgetKit

private func formattedDetailDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}

/// 「重复卡底部摘要」用的 "HH:mm" 24 小时制 formatter,跟 WarmTodoCard.timeFormatter 同款。
/// en_US_POSIX locale 锁死格式,避免随系统语言漂移导致详情页跟首页/ConfirmSheet 不一致。
/// file-private 顶层 —— TodoDetailView<Store> 是泛型,Swift 不允许泛型类型内有 static stored properties。
private let detailRecurrenceSummaryTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "HH:mm"
    return formatter
}()

/// 待办详情页 - 温暖主题风格
/// 支持编辑标题、备注、分类、优先级、日期（DatePicker）、重复，以及标记完成/删除
struct TodoDetailView<Store: TodoListReadable>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var store: Store
    /// 编辑基准。@State 持有:每次 debounce 自动保存成功后同步此值,
    /// 避免「保存后继续编辑」时 checkForChanges 用旧基准误判(用户改回原值会被认为没改)。
    /// 历史问题:原为 `let todo`,onDisappear 一次性保存;改为实时保存后必须可写。
    ///
    /// **@State 语义注意**:SwiftUI @State 在 `init` 设置初始值后,父视图刷新传新值时
    /// **不会重新初始化**此 @State。这意味着:如果父视图(HomeView)中该 todo 被其他流程
    /// (Siri Intent / Widget toggle)更新,Detail 页看到的仍是旧值。
    /// 当前业务下详情页是 modal push,生命周期短,接受此权衡。如果未来出现"详情页常驻 +
    /// 外部数据源可变"场景,需要改用 ObservableObject ViewModel 包装。
    @State private var todo: TodoItemData

    @State private var editedTitle: String
    @State private var editedDetail: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueDate: Date?
    @State private var editedHasDueTime: Bool
    @State private var editedTimeBucket: TimeBucket?
    @State private var editedRecurrenceFrequency: RecurrenceFrequency?
    @State private var editedWeekdays: Set<Int>
    /// weekly 重复的 interval:1=每周、2=双周、3=三周、≥4=fallback。
    /// 跟 frequency/weekdays 同级独立 @State:详情页 chip 暴露"双周/三周"两个独立选项,
    /// 选中时同时设 frequency=.weekly + interval=N。原来没有这个字段,
    /// 导致 AI 返回的 interval=2/3 待办进详情页再保存时被静默重置为 1。
    @State private var editedInterval: Int
    @State private var editedDayOfMonth: Int
    @State private var hasChanges = false
    @State private var showDeleteConfirmation = false
    /// 防抖保存 task。用户每次改字段都会 cancel + 重启;800ms 内无新改动才真正写库。
    /// onDisappear 时 cancel 并立即静默保存,保证用户离开时一定落盘。
    @State private var saveTask: Task<Void, Never>?

    /// 检测 Dynamic Type 档位。AX1+ 切到 weekday 4+3 两行布局,
    /// 单格宽度从 ~44pt 涨到 ~89pt,容下 AX5 下撑大的 "Wed" / "周三"。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(store: Store, todo: TodoItemData) {
        self.store = store
        _todo = State(initialValue: todo)
        _editedTitle = State(initialValue: todo.title)
        _editedDetail = State(initialValue: todo.detail ?? "")
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueDate = State(initialValue: todo.dueDate)
        _editedHasDueTime = State(initialValue: todo.hasDueTime)
        _editedTimeBucket = State(initialValue: todo.timeBucket)
        _editedRecurrenceFrequency = State(initialValue: todo.recurrenceRule?.frequency)
        _editedWeekdays = State(initialValue: Set(todo.recurrenceRule?.weekdays ?? []))
        _editedInterval = State(initialValue: todo.recurrenceRule?.interval ?? 1)
        // 默认值用当前日:与 recurrenceModeButton 切到 .monthly 时的 fallback 一致。
        // 模型 dayOfMonth 1...31, Picker 也限制 1...31, 永远合法 —— 不再需要 validation。
        _editedDayOfMonth = State(initialValue: todo.recurrenceRule?.dayOfMonth ?? Calendar.current.component(.day, from: Date()))
    }

    private var categoryColor: Color { WarmTheme.color(for: editedCategory) }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                VStack(spacing: WarmSpacing.lg) {
                    // 标题
                    VStack(alignment: .leading) {
                        HStack(spacing: WarmSpacing.xs) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(categoryColor)
                                .frame(width: 4, height: WarmSpacing.xl)
                            Text(String(localized: "detail.section.title"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                        }
                        TextField(String(localized: "detail.title_placeholder"), text: $editedTitle, axis: .vertical)
                            // 20pt：比 Notes(14pt) 拉开明显级差，确立标题是页面视觉重心
                            // （原先 18pt vs Notes 16pt 太接近，两者读起来重量差不多）。
                            .font(WarmFont.headline(20))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1...2)
                            .onChange(of: editedTitle) { _, _ in checkForChanges() }
                    }
                    .padding(WarmSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.sheet)
                            .fill(Color.white)
                            .shadow(color: WarmTheme.shadowMedium, radius: 10, x: 0, y: 5)
                    )

                    // 备注（issue 3：新增 Notes 字段）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.notes"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            // 14pt：比 Title(20pt) 明显降一级，正文不再跟标题抢视觉重量；
                            // 字号收小后满宽文本块的视觉密度也随之减轻（原 16pt 显得笨重）。
                            TextField(String(localized: "detail.notes_placeholder"), text: $editedDetail, axis: .vertical)
                                .font(WarmFont.body(14))
                                .foregroundColor(WarmTheme.textPrimary)
                                .lineLimit(1...3)
                                .onChange(of: editedDetail) { _, _ in checkForChanges() }
                        }
                    }

                    // 分类（自适应网格：7 个分类按屏宽换行，避免横向滚动藏起「其他」）
                    // minimum 64pt：去掉 emoji 后每列只需容纳文字本身宽度，
                    // 64pt 足够放下 13pt 字体的 "Finance"/"Social"，
                    // 配合 chip 内 lineLimit(1) + minimumScaleFactor 兜底 Dynamic Type 最大档。
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.category"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 64), spacing: WarmSpacing.xs)],
                                spacing: WarmSpacing.xs
                            ) {
                                ForEach(TodoCategory.allCases, id: \.self) { cat in
                                    categoryChip(cat)
                                }
                            }
                        }
                    }

                    // 优先级（issue 7：绿色改橙色系；issue 8：统一实心填充）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.priority"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            HStack(spacing: WarmSpacing.sm) {
                                priorityButton(.low, label: String(localized: "detail.priority.low"), icon: "arrow.down")
                                priorityButton(.normal, label: String(localized: "detail.priority.normal"), icon: "minus")
                                priorityButton(.high, label: String(localized: "detail.priority.high"), icon: "exclamationmark")
                            }
                        }
                    }

                    // 时间(日期 + 时段合并):一个整体卡,日期区在上、Divider、时段区在下。
                    // 之前是两个独立 detailCard,违背语音场景「下午提醒我」的语义完整性——
                    // 用户要分两步理解「哪天 + 什么时段」,合并后一眼看到完整时间。
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.time"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            // 日期区形态由重复档位派生(RecurrenceAnchorPolicy.dateRowMode):
                            // - .dueDate(无重复):「日期」DatePicker + ✕ / 「添加日期」按钮 —— 原行为不变
                            // - .startAnchor(双周/三周):「起始日期」DatePicker,无 ✕ —— 锚点决定 occurs() 的
                            //   weekDiff % interval,清掉会退回 createdAt 让用户看不见也控制不了「从哪一周开始」
                            // - .hidden(daily/weekly(interval==1)/monthly):整行不渲染 —— 锚点只是下界或
                            //   靠 dayOfMonth 自锚,暴露出来只会跟重复卡语义打架
                            let dateRowMode = RecurrenceAnchorPolicy.dateRowMode(
                                frequency: editedRecurrenceFrequency,
                                interval: editedInterval
                            )
                            if dateRowMode == .dueDate {
                                if editedDueDate != nil {
                                    HStack {
                                        DatePicker(
                                            "",
                                            selection: Binding(
                                                get: { editedDueDate ?? Date() },
                                                set: { editedDueDate = $0; checkForChanges() }
                                            ),
                                            displayedComponents: .date
                                        )
                                        .datePickerStyle(.compact)
                                        .labelsHidden()
                                        Spacer()
                                        Button {
                                            editedDueDate = nil
                                            editedHasDueTime = false
                                            checkForChanges()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(WarmTheme.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else {
                                    Button {
                                        self.editedDueDate = DayClock.startOfUserDay(for: Date())
                                        checkForChanges()
                                    } label: {
                                        HStack(spacing: WarmSpacing.xs) {
                                            Image(systemName: "calendar")
                                                .font(.system(size: 15))
                                            Text(String(localized: "detail.add_date"))
                                                .font(WarmFont.body(16))
                                        }
                                        .foregroundColor(WarmTheme.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else if dateRowMode == .startAnchor {
                                // 双周/三周锚点不可清空 —— 进这个 mode 时 recurrenceModeButton
                                // action 已在 interval>1 && editedDueDate==nil 时补今天。
                                // DatePicker 用户的任何 set 都会把 nil → 具体日期,所以 selection
                                // 的 get 用 ?? Date() 仅作显示兜底;真正的不变式由 set 路径保证。
                                HStack(spacing: WarmSpacing.xs) {
                                    Text(String(localized: "detail.start_date"))
                                        .font(WarmFont.caption(12))
                                        .foregroundColor(WarmTheme.textSecondary)
                                    DatePicker(
                                        "",
                                        selection: Binding(
                                            get: { editedDueDate ?? Date() },
                                            set: { editedDueDate = $0; checkForChanges() }
                                        ),
                                        displayedComponents: .date
                                    )
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    Spacer()
                                }
                                .accessibilityIdentifier("DetailStartDatePicker")
                            }
                            // .hidden:整行不渲染(EmptyView 在 ViewBuilder 中被忽略)

                            // 语音原文备注(保留但不编辑)
                            if let hint = todo.dueHint, !hint.isEmpty {
                                Text(String(format: String(localized: "detail.voice_hint_format"), hint))
                                    .font(WarmFont.caption(12))
                                    .foregroundColor(WarmTheme.textMuted)
                            }

                            // 时段区:任何重复档位下都可用。原 if editedDueDate != nil 分支
                            // 会把「钟点 / 时段」跟 dueDate 绑死,但引擎层(TodoQueryActor)
                            // 在 recurrenceRule != nil 时用 dueDate ?? createdAt 作锚点,
                            // 锚点为 nil 时仍能调度,所以 UI 也应该解耦。
                            //
                            // - hasDueTime=true:钟点 picker + 派生 TimeBucket 只读 + 清除钟点按钮
                            // - hasDueTime=false:「添加钟点」按钮(canAddClockTime 守门)+ TimeBucket 胶囊恒显示
                            Divider()
                            timeSection
                        }
                    }

                    recurrenceEditorCard

                    // 删除:文字链接样式(无背景填充)。
                    // 保留二次确认 alert —— 危险操作必须有,但视觉上弱化避免误点。
                    // 热区:.contentShape(Rectangle()) + .frame(maxWidth: .infinity, minHeight: 44)
                    //   把"透明背景"也纳入点击区,保证 iOS HIG 44pt 触摸目标。
                    //   文字本身只有 ~17pt 高、~50pt 宽,不撑满会变成难点的居中小按钮。
                    //   撑满后视觉上仍是"居中文字链接"(背景透明),但整行可点。
                    Button(action: { showDeleteConfirmation = true }) {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "trash")
                            Text(String(localized: "detail.delete_button"))
                        }
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.urgent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, WarmSpacing.xxl) // 跟上方 recurrence 卡片拉开留白,危险操作单独成段

                    // 元信息（issue 9：降为底部小字，不做卡片）
                    VStack(spacing: WarmSpacing.xxs) {
                        if todo.needsAIProcessing {
                            HStack(spacing: WarmSpacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(WarmTheme.warning)
                                Text(String(localized: "detail.needs_ai"))
                                    .font(WarmFont.body(13))
                                    .foregroundColor(WarmTheme.warning)
                            }
                        }
                        Text("\(String(localized: "detail.created_at")) \(formattedDetailDate(todo.createdAt))")
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, WarmSpacing.sm)
                }
                .padding(.horizontal, WarmSpacing.xl)
                .padding(.top, WarmSpacing.xl) // issue 6：加大 top padding 防 Title 被导航栏截断
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(String(localized: "detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // HomeView 移除 NavigationStack 后,详情页靠 fullScreenCover 内嵌的 NavigationStack 呈现。
            // 内嵌 NavigationStack 无 push 历史 → 无自动 back,补关闭按钮。
            // 图标用 chevron.down(iOS 17+ 标准 modal dismiss 语义,跟系统提醒事项详情页一致):
            //   - 旧版 xmark 在 autosave 机制下有歧义 —— 用户会误以为"放弃改动退出"
            //   - checkmark 会跟卡片左侧 todo 完成勾选框视觉重复,误以为"标记 todo 完成"
            //   - chevron.down 是纯导航语义,不暗示保存/取消,匹配 autosave 行为
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel(String(localized: "panel.close"))
                .accessibilityIdentifier("TodoDetailCloseButton")
            }
        }
        // 自动保存:用户每次改字段会 schedule debounce,onDisappear 时 cancel 并立即静默保存兜底。
        // 这样用户改完停 0.8s 看到顶部「已保存 ✓」反馈,或在用户离开页面时静默落盘。
        // 不再用旧版「返回时一次性保存」(saveIfChanged) ——反馈缺失,用户不知道改的存了没。
        //
        // cancel + 置 nil 是协作式取消的最佳实践:Task.sleep 会 throw CancellationError(被 try? 吞掉),
        // guard !Task.isCancelled 让 Task 尽早退出而不是空等 800ms。
        //
        // 关于并发安全:即使 Task 已越过 sleep 进入 persistChanges 同步段(onDisappear 的 cancel
        // 无法中断正在执行的同步代码),两次 persistChanges 也是严格串行的 ——
        // Task 内执行完毕置 hasChanges = false,紧接的 onDisappear persistChanges 会命中
        // `guard hasChanges else { return }` 提前退出。没有真正的并发写。
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            if hasChanges {
                persistChanges(feedback: .none)
            }
        }
        .alert(String(localized: "detail.confirm_delete"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "detail.cancel"), role: .cancel) {}
            Button(String(localized: "detail.delete"), role: .destructive) { deleteTodo() }
        } message: {
            Text(String(localized: "detail.delete_warning"))
        }
        // 详情页靠 fullScreenCover 呈现 —— 它是独立窗口层级,VoiceTodoApp.mainView 上的
        // .toast overlay 被整页盖住,详情页里调 coordinator.showToast 时反馈不可见。
        // 这里在详情页内再挂一份,复用同一组 coordinator 状态,反馈就能在详情页顶部出现。
        // dismiss 后若 toast 未消失,主 overlay 接管显示,不会丢反馈。
        .toast(
            message: coordinator.toastMessage,
            style: coordinator.toastStyle,
            isPresented: $coordinator.showToast,
            actionTitle: coordinator.toastActionTitle,
            action: coordinator.toastAction
        )
    }

    // MARK: - Card Wrapper

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(WarmSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowLight, radius: 4, x: 0, y: 2)
            )
    }

    // MARK: - Chips（自适应网格 + 统一实心填充选中样式）

    private func categoryChip(_ category: TodoCategory) -> some View {
        let isSelected = editedCategory == category
        return Button {
            withAnimation(WarmAnimation.springStandard) { editedCategory = category; checkForChanges() }
        } label: {
            Text(category.displayName)
                .font(WarmFont.caption(13))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// 颜色语义跟优先级强度对应(三档都是实心填充,深浅表达强度,不再用描边):
    /// - High 选中   → 实心 urgent(红) + 白字(强调态,危险/紧急)
    /// - Normal 选中 → 实心 primary(中珊瑚橙) + 白字(标准强调)
    /// - Low 选中    → 实心 primaryLight(浅珊瑚) + textPrimary(弱强调,浅底配深字保证可读)
    /// - 未选中      → 浅灰底 + textSecondary
    /// 之前 Normal 选中是细描边,跟未选中的浅灰底几乎分不清——统一改实心后
    /// 三档的"选中/未选中"对比都很强,颜色深浅本身就是强度提示,一眼能看出选的是哪档。
    private func priorityButton(_ priority: Priority, label: String, icon: String) -> some View {
        let isSelected = editedPriority == priority
        return Button {
            withAnimation(WarmAnimation.springStandard) { editedPriority = priority; checkForChanges() }
        } label: {
            HStack(spacing: WarmSpacing.xs) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                // 字号统一到 caption(13):跟 categoryChip 同尺寸,chip 类组件视觉一致。
                Text(label).font(WarmFont.caption(13))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WarmSpacing.sm)
            .background(priorityButtonBackground(isSelected: isSelected, priority: priority))
            .foregroundColor(
                isSelected
                    ? (priority == .low ? WarmTheme.textPrimary : .white)
                    : WarmTheme.textSecondary
            )
        }
        .buttonStyle(.plain)
    }

    /// priorityButton 的背景 View。抽出为独立 helper 是为了规避 SwiftUI `.background { if/else }`
    /// ViewBuilder 闭包写法在 type-check 耗时和可读性上的问题,跟同文件其他 chip 的
    /// `.background(RoundedRectangle(...).fill/stroke(...))` 直链形式保持一致。
    @ViewBuilder
    private func priorityButtonBackground(isSelected: Bool, priority: Priority) -> some View {
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

    /// 时段区:任何重复档位下都可用。两种状态由 editedHasDueTime 决定。
    /// - hasDueTime=true: 钟点 DatePicker + 派生 TimeBucket 只读 + 清除钟点按钮
    /// - hasDueTime=false: 「添加钟点」按钮(可见性由 canAddClockTime 守门)+ TimeBucket 胶囊恒显示。
    ///
    /// **不变式**:editedHasDueTime == true ⇒ editedDueDate != nil —— UI 侧维持,
    /// TodoDetailUpdate.init 再兜一层归一化(hasDueTime = dueDate != nil && hasDueTime)。
    @ViewBuilder
    private var timeSection: some View {
        if editedHasDueTime {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                HStack {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { editedDueDate ?? Date() },
                            set: { newTime in
                                // DatePicker(.hourAndMinute) 的 set 给的是完整 Date,
                                // 但只有钟点部分有意义——把它合并到 editedDueDate 的日期部分,
                                // 避免替换掉用户刚选的日期。
                                let calendar = Calendar.current
                                var components = calendar.dateComponents([.year, .month, .day], from: editedDueDate ?? Date())
                                components.hour = calendar.component(.hour, from: newTime)
                                components.minute = calendar.component(.minute, from: newTime)
                                editedDueDate = calendar.date(from: components)
                                checkForChanges()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()

                    Spacer()

                    // 清除钟点:保留 editedDueDate(日期部分) 和 editedTimeBucket(手动选择),
                    // 只切 hasDueTime=false。下次再点"添加钟点"会从当前时刻开始。
                    Button {
                        editedHasDueTime = false
                        checkForChanges()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                // 派生 TimeBucket 只读显示:不写回 editedTimeBucket,清钟点后会自然回到手动模式。
                let derived = TimeBucketResolver.effective(
                    explicitBucket: editedTimeBucket,
                    dueDate: editedDueDate,
                    hasDueTime: editedHasDueTime
                )
                Text(derived.localizedTitle)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
            }
        } else {
            VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                // 「添加钟点」可见性:有 dueDate 或有重复规则即可。
                // 原条件 `editedDueDate != nil` 会让「双周/三周但 editedDueDate 还没补」
                // (理论上不会发生,recurrenceModeButton action 已兜底)以及「无 dueDate 但有 rule」
                // (引擎层 dueDate ?? createdAt 仍能调度)走不到「添加钟点」分支,语义不对。
                if RecurrenceAnchorPolicy.canAddClockTime(
                    dueDate: editedDueDate,
                    frequency: editedRecurrenceFrequency
                ) {
                    // "添加钟点":首次按下时把钟点设为当前时刻,避免显示 startOfDay 的 00:00。
                    // components(from: editedDueDate ?? now) 天然支持 dueDate == nil → 顺手把
                    // 今天写成锚点,无需额外改动。
                    Button {
                        let calendar = Calendar.current
                        let now = Date()
                        var components = calendar.dateComponents([.year, .month, .day], from: editedDueDate ?? now)
                        components.hour = calendar.component(.hour, from: now)
                        components.minute = calendar.component(.minute, from: now)
                        editedDueDate = calendar.date(from: components)
                        editedHasDueTime = true
                        checkForChanges()
                    } label: {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                            Text(String(localized: "detail.add_time"))
                                .font(WarmFont.body(15))
                        }
                        .foregroundColor(WarmTheme.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DetailAddTimeButton")
                }

                chipRow {
                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                        timeBucketButton(bucket)
                    }
                }
            }
        }
    }

    private func timeBucketButton(_ bucket: TimeBucket) -> some View {
        let selectedBucket = editedTimeBucket ?? .anytime
        let isSelected = selectedBucket == bucket
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedTimeBucket = bucket == .anytime ? nil : bucket
                checkForChanges()
            }
        } label: {
            // chip 按内容宽度:lineLimit(1) 防换行/断词,fixedSize 让 chip 宽度跟文字走
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

    // MARK: - Recurrence Editor

    private var recurrenceEditorCard: some View {
        detailCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "detail.section.recurrence"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)

                chipRow {
                    recurrenceModeButton(nil, title: String(localized: "recurrence.none"))
                    recurrenceModeButton(.daily, title: String(localized: "recurrence.daily"))
                    recurrenceModeButton(.weekly, interval: 1, title: String(localized: "recurrence.weekly_short"))
                    recurrenceModeButton(.weekly, interval: 2, title: String(localized: "recurrence.biweekly_short"))
                    recurrenceModeButton(.weekly, interval: 3, title: String(localized: "recurrence.triweekly_short"))
                    recurrenceModeButton(.monthly, title: String(localized: "recurrence.monthly_short"))
                }

                if editedRecurrenceFrequency == .weekly {
                    weekdayGrid
                }

                if editedRecurrenceFrequency == .monthly {
                    // wheel picker 高度由 .frame 强制 —— 不给 frame 会撑满父容器。
                    // 80×100:3 行可见,够 iOS HIG wheel 触摸目标,又不喧宾夺主。
                    // 文字「每月 / 号」放在 picker 同行,垂直居中视觉对齐。
                    HStack(spacing: WarmSpacing.sm) {
                        Text(String(localized: "recurrence.monthly_day_prefix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        Picker("", selection: $editedDayOfMonth) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80, height: 100)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "recurrence.monthly_day_placeholder"))
                        .onChange(of: editedDayOfMonth) { _, _ in checkForChanges() }
                        Text(String(localized: "recurrence.monthly_day_suffix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        Spacer()
                    }
                }

                if let recurrenceValidationMessage {
                    Text(recurrenceValidationMessage)
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.warning)
                } else if let recurrenceSummary {
                    // 重复生效后的完整语义摘要,把「起始锚点 / 周期 / 钟点」拼成一行,
                    // 让被隐藏的起始锚点(尤其 .startAnchor / .hidden 模式下)不再是黑盒。
                    // 例:「从 7月30日 起 · 双周 周一 · 10:10」或「每天 · 15:00」。
                    Text(recurrenceSummary)
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.textMuted)
                        .accessibilityIdentifier("DetailRecurrenceSummary")
                }
            }
        }
    }

    private func recurrenceModeButton(
        _ frequency: RecurrenceFrequency?,
        interval: Int = 1,
        title: String
    ) -> some View {
        // weekly 三档(每周/双周/三周)共用 frequency=.weekly,必须再比对 interval
        // 才能区分 —— 否则三档会被同时判定为选中。
        // non-weekly(daily/monthly/nil)忽略 interval。
        let isSelected: Bool = {
            guard editedRecurrenceFrequency == frequency else { return false }
            return frequency == .weekly ? editedInterval == interval : true
        }()
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedRecurrenceFrequency = frequency
                if frequency == .weekly {
                    editedInterval = interval
                    // interval==1(每周)强制默认周几,避免触发 weekly_required 校验;
                    // interval>1(双周/三周)保留已有 weekdays:用户可能从 AI 返回的
                    // "双周周一"进来,点 chip 确认时不应丢失周几锚定。displayText
                    // 会显示完整"双周 周一",chip 标签"双周"只表达周期,两者互补。
                    if interval == 1 && editedWeekdays.isEmpty {
                        editedWeekdays = [Calendar.current.component(.weekday, from: Date())]
                    }
                    // 双周/三周靠起始锚点决定「从哪一周开始」(occurs 的 weekDiff % interval);
                    // 无 dueDate 时补今天,既给 occurs() 确定基准,也让「起始日期」行有值可显示。
                    // 这跟 .startAnchor 形态强耦合:进 .startAnchor 必须有锚点,否则日期行空白。
                    if interval > 1 && editedDueDate == nil {
                        editedDueDate = DayClock.startOfUserDay(for: Date())
                    }
                } else if frequency == nil {
                    // 切回「无重复」时,若 editedDueDate 是切到 startAnchor 模式时被自动补的
                    // (基准:进入详情页时 todo.dueDate == nil,且用户没设过钟点),
                    // 把它清掉 —— 否则这个用户从未主动指定的日期会从「锚点」悄悄变成
                    // 「截止日」,语义错位。用户原本就有 dueDate 的场景不动。
                    if todo.dueDate == nil && !editedHasDueTime {
                        editedDueDate = nil
                    }
                }
                // monthly: editedDayOfMonth 是 Int,init 时已设默认值(当前日或 todo.dayOfMonth),
                // 切换时无需 fallback —— 用户切换走再切回应保留之前选择,不应被 reset。
                checkForChanges()
            }
        } label: {
            // 同 timeBucketButton:chip 按内容宽度,同一套修饰符保证视觉一致
            Text(title)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
        }
        .buttonStyle(.plain)
    }

    /// chip 容器:FlowLayout 自适应换行。默认档位 4 chip 一行;AX5 / 长词撑破
    /// 屏宽时自动换行到 2 行 / 3 行,所有 chip 完整可见不滚动、不缩字、不截断。
    /// chip 自身已用 fixedSize 暴露稳定 intrinsic 宽度,FlowLayout 按内容算行宽。
    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        FlowLayout(horizontalSpacing: WarmSpacing.xs, verticalSpacing: WarmSpacing.xs) {
            content()
        }
    }

    /// weekday 7 button 的容器:默认单行 7 等分;AX 档位(AX1+)切到 4+3 两行,
    /// 单格宽度从 ~44pt 涨到 ~89pt,容下 AX5 下撑大的 "Wed" / "周三"。
    /// 用 `dynamicTypeSize.isAccessibilitySize` 硬切,而非 ViewThatFits ——
    /// 后者对 `frame(maxWidth: .infinity)` 内容判断不可靠(button 永远"装得下")。
    /// 用户审美要求:两行布局按 4+3 而不是 3+4(7/2≈3.5,4+3 视觉更对称)。
    @ViewBuilder
    private var weekdayGrid: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: WarmSpacing.xs) {
                HStack(spacing: WarmSpacing.xs) {
                    ForEach(1...4, id: \.self) { weekday in weekdayButton(weekday) }
                }
                HStack(spacing: WarmSpacing.xs) {
                    ForEach(5...7, id: \.self) { weekday in weekdayButton(weekday) }
                }
            }
        } else {
            HStack(spacing: WarmSpacing.xs) {
                ForEach(1...7, id: \.self) { weekday in weekdayButton(weekday) }
            }
        }
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isSelected = editedWeekdays.contains(weekday)
        return Button {
            if isSelected { editedWeekdays.remove(weekday) } else { editedWeekdays.insert(weekday) }
            checkForChanges()
        } label: {
            Text(shortWeekdayName(weekday))
                // caption(11) 比 Repeat chip 的 caption(12) 小一档,视觉层级清晰:
                // Repeat 是主选择,weekday 是次级补选。两者同 textStyle(.caption2),
                // AX5 缩放系数一致,所以 11 vs 12 的相对差距在所有档位下都保留。
                .font(WarmFont.caption(11))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                // lineLimit(1) + minimumScaleFactor(0.7) 作为兜底:
                // 默认 7 等分模式下仍可能边缘截断(窄屏 + AX 边界档位),允许 Text 缩到 70%。
                // 两行模式(AX1+)下单格够宽,通常用不到缩放。
                // minHeight(非 height)让字号撑高时高度跟随,7 个 button 高度自动一致。
                // 符合 CLAUDE.md「文本布局规则」第 1 条 + feedback memory「文本截断零容忍」。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(minHeight: WarmSpacing.xxl)
                .background(RoundedRectangle(cornerRadius: WarmRadius.chip).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
        }
        .buttonStyle(.plain)
    }

    private func shortWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    /// 重复卡底部摘要文本。把引擎的 dueDate=锚点 语义显式化,让用户看见:
    /// - 周期(rule.displayTextWithEndDate):每天 / 双周 周一 / 三周 ...
    /// - 钟点或模糊时段(从 editedDueDate / timeBucket 派生)
    /// - 必要时拼「从 X 起」前缀(双周/三周锚点恒带,hidden 模式下锚点在未来才带)
    ///
    /// 复用 TodoTimeDisplayComposer 拼后半段 —— 它在有 rule 时会主动跳过 relativeDateText,
    /// 正好把「起始日」的表述让给这里的 detail.recurrence.starts_from 前缀,不会重复。
    /// 钟点串复用 WarmTodoCard 同款 "HH:mm" / en_US_POSIX formatter。
    private var recurrenceSummary: String? {
        guard let rule = editedRecurrenceRule else { return nil }
        let mode = RecurrenceAnchorPolicy.dateRowMode(
            frequency: editedRecurrenceFrequency,
            interval: editedInterval
        )

        let clockText: String? = {
            guard editedHasDueTime, let anchor = editedDueDate else { return nil }
            return detailRecurrenceSummaryTimeFormatter.string(from: anchor)
        }()
        let bucketText: String? = clockText == nil ? derivedTimeBucketTextForSummary : nil
        guard let tail = TodoTimeDisplayComposer.compose(
            recurrenceRule: rule,
            relativeDateText: nil,
            timeText: clockText,
            dueHint: nil,
            timeBucketText: bucketText
        ) else { return nil }

        let showsPrefix = RecurrenceAnchorPolicy.showsAnchorPrefix(
            mode: mode,
            anchor: editedDueDate,
            now: Date(),
            calendar: .current
        )
        guard showsPrefix, let anchor = editedDueDate else {
            return tail
        }
        let formatted = TodoRelativeDateFormatter.format(anchor)
        return String(format: String(localized: "recurrence.starts_from"), formatted) + " · " + tail
    }

    /// summary 专用:无钟点时取派生/手动 TimeBucket 的本地化文案。
    /// 跟 WarmTodoCard.timeBucketText 同语义,但不接受外部开关 —— 摘要恒走这条路径。
    private var derivedTimeBucketTextForSummary: String? {
        guard !editedHasDueTime else { return nil }
        let bucket = TimeBucketResolver.effective(
            explicitBucket: editedTimeBucket,
            dueDate: editedDueDate,
            hasDueTime: editedHasDueTime
        )
        return bucket == .anytime ? nil : bucket.localizedTitle
    }

    private var editedRecurrenceRule: RecurrenceRule? {
        switch editedRecurrenceFrequency {
        case .daily: return RecurrenceRule(frequency: .daily)
        case .weekly:
            // interval==1(每周)必须有 weekdays 才有效(否则 isValid 会判 false);
            // interval>1(双周/三周)允许空 weekdays —— 对齐 AI 返回的"每两周"语义。
            guard editedInterval > 1 || !editedWeekdays.isEmpty else { return nil }
            return RecurrenceRule(
                frequency: .weekly,
                interval: editedInterval,
                weekdays: Array(editedWeekdays)
            )
        case .monthly:
            // Picker 1...31 已限制范围,editedDayOfMonth 永远合法,直接构造。
            return RecurrenceRule(frequency: .monthly, dayOfMonth: editedDayOfMonth)
        case nil: return nil
        }
    }

    private var recurrenceValidationMessage: String? {
        switch editedRecurrenceFrequency {
        case .weekly:
            // 仅"每周"需要强制选周几;"双周/三周"允许空 weekdays。
            return (editedInterval == 1 && editedWeekdays.isEmpty)
                ? String(localized: "recurrence.validation.weekly_required")
                : nil
        // monthly:Picker 1...31 已限制,无需 validation。
        case .monthly, .daily, nil: return nil
        }
    }

    private var recurrenceStateChanged: Bool {
        if editedRecurrenceFrequency != todo.recurrenceRule?.frequency { return true }
        switch editedRecurrenceFrequency {
        case .weekly:
            // 同时比对 interval 和 weekdays:interval 变化(每周↔双周↔三周)也算结构变化。
            // 不比 interval 会导致 AI 返回 interval=2 的待办进详情页随便编辑一下就被静默重置为 1。
            let oldInterval = todo.recurrenceRule?.interval ?? 1
            let oldWeekdays = Set(todo.recurrenceRule?.weekdays ?? [])
            return editedInterval != oldInterval || editedWeekdays != oldWeekdays
        case .monthly:
            // todo 不是 monthly 时,frequency 已变化会先在第一行 return true,
            // 这里的 fallback 实际走不到 —— 用 1 仅作占位,任意值都不影响判定结果。
            // 不用 `Calendar.current.component(.day, ...)` 是为了避免 computed property
            // 每次访问重新取值,在跨午夜停留 Detail 页的极端场景产生漂移。
            return editedDayOfMonth != (todo.recurrenceRule?.dayOfMonth ?? 1)
        case .daily, nil: return false
        }
    }

    // MARK: - Actions

    /// 计算 `hasChanges` 并在检测到改动时触发防抖保存。
    ///
    /// 设计说明:把「检测变化」和「调度保存」放在一起是有意的取舍 ——
    /// 当前所有调用点(8 处 onChange / chip / button)都是「检测到变化就该保存」,
    /// 没有只检测不保存的用例。拆分会扩散到所有调用点(每处都加 scheduleAutosave),
    /// 反而降低可读性。如果未来出现「只检测不保存」场景,再拆分为纯查询 + 调用方显式调度。
    private func checkForChanges() {
        hasChanges = editedTitle != todo.title ||
                     editedDetail != (todo.detail ?? "") ||
                     editedCategory != todo.category ||
                     editedPriority != todo.priority ||
                     editedDueDate != todo.dueDate ||
                     editedHasDueTime != todo.hasDueTime ||
                     editedTimeBucket != todo.timeBucket ||
                     recurrenceStateChanged
        // 有改动就 schedule 防抖保存:用户停 800ms 不动 → 自动写库 + 显示 toast。
        // 防抖避免每次 keystroke 都触发 SwiftData 写入。
        if hasChanges {
            scheduleAutosave()
        }
    }

    /// 防抖保存:每次有改动就 cancel 旧 task,重启 800ms 倒计时。
    /// 用户连续改字段不会触发多次保存,只有真正停下才落盘。
    ///
    /// **时序边界**:Task 的 cancellation 是协作式的 —— `cancel()` 只设置 flag,无法中断
    /// 已越过 sleep 进入 persistChanges 同步段的代码。极端情况下用户快速 swipe back 然后立刻
    /// 重新进入同一 todo 详情,可能短暂存在两个 Task。`guard !Task.isCancelled` + `hasChanges`
    /// 守卫保证不会真正并发写库,但 toast 可能出现两次。可接受(用户感知极小)。
    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistChanges(feedback: .toast)
        }
    }

    /// 保存反馈模式。
    /// - `.toast`:debounce 自动保存走这条 —— 用户改完看到「已保存 ✓」反馈,确认改动落盘。
    /// - `.none`:onDisappear 兜底走这条 —— 页面已退出,toast 显示在父视图反而打扰用户。
    private enum SaveFeedback {
        case none
        case toast
    }

    /// 把当前 edited* 字段写入 store,并同步本地基准 `todo`。
    /// 同步基准是关键:不同步的话,保存后继续编辑会让 checkForChanges 用旧 todo 比对,
    /// 出现「用户改回原值却显示无变化」的 bug(因为 todo 还是初始值)。
    ///
    /// recurrence 验证失败时整体 abort(不降级保存):
    /// - validation 只在 recurrence 编辑过程中失败(.weekly 未选周几 / .monthly 日期非法),
    ///   这表示用户「正在设置 recurrence,还没完成」——属于未完成编辑,不应当作可保存状态。
    /// - 降级保存(保留旧 recurrence)会让 UI 显示 .weekly 但 store 仍是 nil,重新打开详情页
    ///   用户会看到 recurrence 没存住,数据 vs UI 不一致。
    /// - debounce 路径下 feedback == .toast 会显示 warning,提示用户完成编辑;用户不完成就不保存,
    ///   符合「in-progress 不持久化」的心智模型。
    /// - onDisappear 路径下 feedback == .none 不提示(页面已退出,toast 打扰用户),
    ///   用户重新进入时会看到 edited* 的中间态丢失、恢复到上次成功保存的基准 —— 这是
    ///   「未完成编辑 = 弃掉」的预期行为。
    ///
    /// **权衡代价**:整体 abort 意味着用户同时修改了其他字段(如改了标题、备注、分类),
    /// 这些改动也会一起被丢弃。这是优先「数据一致性」的取舍 —— 比部分保存后用户看到
    /// 「标题存了但 recurrence 没存」更可预测。如果未来要支持「部分保存」,需要给每个字段
    /// 独立做 valid 校验 + 独立 hasChanged 标记,改造较大。
    private func persistChanges(feedback: SaveFeedback) {
        guard hasChanges else { return }
        guard recurrenceValidationMessage == nil else {
            if feedback == .toast {
                coordinator.showToast(message: recurrenceValidationMessage ?? ErrorMessages.storageError, style: .warning)
            }
            return
        }
        let timeMetadataChanged = editedDueDate != todo.dueDate ||
                                  editedHasDueTime != todo.hasDueTime ||
                                  editedTimeBucket != todo.timeBucket ||
                                  recurrenceStateChanged
        do {
            try coordinator.updateTodoDetail(
                todo.id,
                update: TodoDetailUpdate(
                    title: editedTitle,
                    detail: editedDetail.isEmpty ? nil : editedDetail,
                    category: editedCategory != todo.category ? editedCategory : nil,
                    priority: editedPriority != todo.priority ? editedPriority : nil,
                    dueDate: editedDueDate,
                    hasDueTime: editedHasDueTime,
                    timeBucket: editedTimeBucket,
                    dueHint: timeMetadataChanged ? "" : nil,
                    recurrenceRule: editedRecurrenceRule
                )
            )
            // 同步基准:把 edited* 写回 todo,下次 checkForChanges 以新基准比对。
            // editedHasDueTime / editedTimeBucket 由 UI 层归一化(用户取消日期时 UI 自己清 hasDueTime),
            // 这里直接赋值即可,不再做二次归一化。
            todo.title = editedTitle
            todo.detail = editedDetail.isEmpty ? nil : editedDetail
            todo.category = editedCategory
            todo.priority = editedPriority
            todo.dueDate = editedDueDate
            todo.hasDueTime = editedHasDueTime
            todo.timeBucket = editedTimeBucket
            todo.recurrenceRule = editedRecurrenceRule
            if timeMetadataChanged {
                todo.dueHint = ""
            }
            hasChanges = false
            if feedback == .toast {
                coordinator.showToast(message: ErrorMessages.todoSaved, style: .success)
            }
        } catch {
            // 保存失败时保留 hasChanges = true —— 用户下次显式改动(checkForChanges 重算)
            // 会重新触发 scheduleAutosave 自动重试。debounce 机制天然限制重试频率:
            // 用户必须停下来 800ms 才会触发下一次保存,不会刷屏。
            // feedback == .none(onDisappear)时不 toast —— 页面已退出,toast 显示在父视图打扰用户。
            // 副作用:用户停止编辑后 hasChanges 保持 true,但无新 keystroke 就不会 scheduleAutosave,
            // 数据最终没保存。接受此权衡:静默失败比刷屏 toast 更可取,用户下次编辑会再触发。
            VoiceTodoLog.store.error("ui.detail.save_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            if feedback == .toast {
                coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
            }
        }
    }

    private func deleteTodo() {
        do {
            try coordinator.deleteTodo(todo.id)
            coordinator.showToast(message: ErrorMessages.todoDeleted, style: .info)
            dismiss()
        } catch {
            VoiceTodoLog.store.error("ui.detail.delete_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.todoDeleteFailed, style: .warning)
        }
    }
}
