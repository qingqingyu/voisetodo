import SwiftUI
import WidgetKit

private func formattedDetailDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}

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
    @State private var editedDayOfMonth: String
    @State private var hasChanges = false
    @State private var showDeleteConfirmation = false
    /// 防抖保存 task。用户每次改字段都会 cancel + 重启;800ms 内无新改动才真正写库。
    /// onDisappear 时 cancel 并立即静默保存,保证用户离开时一定落盘。
    @State private var saveTask: Task<Void, Never>?

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
        _editedDayOfMonth = State(initialValue: todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
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
                    // minimum 64pt：emoji+文字改竖排后，每列只需容纳文字本身的宽度
                    // （不用再和 emoji 抢横向空间），64pt 足够放下 13pt 字体的 "Finance"/"Social"。
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

                            // 日期区:DatePicker 或「添加日期」按钮 + 清除
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

                            // 语音原文备注(保留但不编辑)
                            if let hint = todo.dueHint, !hint.isEmpty {
                                Text(String(format: String(localized: "detail.voice_hint_format"), hint))
                                    .font(WarmFont.caption(12))
                                    .foregroundColor(WarmTheme.textMuted)
                            }

                            // 时段区:三种状态。
                            // - 有 dueDate + 有钟点:钟点 picker(可编辑) + TimeBucket 只读派生 + 清除钟点按钮
                            // - 有 dueDate + 无钟点:"添加钟点"按钮 + TimeBucket 胶囊(可手动选)
                            // - 无 dueDate:保持原"设计妥协"——TimeBucket 胶囊仍显示,因为
                            //   TimeBucket 业务上可独立于 dueDate 存在(如"下午"不绑定具体日期)。
                            //
                            // 派生 TimeBucket 只用于显示,不写回 editedTimeBucket——避免污染
                            // 用户的手动选择。清钟点后 editedTimeBucket 保留,自然回到手动模式。
                            Divider()
                            if editedDueDate != nil {
                                timeRowWithDueDate
                            } else {
                                HStack(spacing: WarmSpacing.xs) {
                                    ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                                        timeBucketButton(bucket)
                                    }
                                }
                            }
                        }
                    }

                    recurrenceEditorCard

                    // 标记完成（issue 4：新增）
                    if !todo.isCompleted {
                        Button {
                            coordinator.toggleTodo(todo.id)
                            dismiss()
                        } label: {
                            HStack(spacing: WarmSpacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(String(localized: "detail.mark_done"))
                            }
                            .font(WarmFont.body(16))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarmSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: WarmRadius.section)
                                    .fill(WarmTheme.primary)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 删除:文字链接样式(无背景填充),与「标记完成」拉开距离降低误触。
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
                    .padding(.top, WarmSpacing.xxl)

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

    /// emoji 在上、文字在下的竖排布局（而非横排 HStack）：
    /// 横排时 emoji + 长分类名（"Finance"/"Social"）在窄格子里必须共享一行宽度，
    /// 文字没有 lineLimit 就会被迫折成两三行，而且 emoji 视觉居中、文字被挤右侧，
    /// 两者重心对不齐。竖排让每个元素独占整行宽度，天然垂直居中对齐，
    /// 配合 lineLimit(1) + minimumScaleFactor 兜底极端字体缩放场景。
    private func categoryChip(_ category: TodoCategory) -> some View {
        let isSelected = editedCategory == category
        return Button {
            withAnimation(WarmAnimation.springStandard) { editedCategory = category; checkForChanges() }
        } label: {
            VStack(spacing: WarmSpacing.xxs) {
                Text(category.emoji).font(.system(size: 18))
                Text(category.displayName)
                    .font(WarmFont.caption(12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, WarmSpacing.xs)
            .padding(.vertical, WarmSpacing.sm)
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
                Text(label).font(WarmFont.body(15))
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

    /// 有 dueDate 时的时段区:三种情况由 editedHasDueTime 决定。
    /// - hasDueTime=true: 钟点 DatePicker + 派生 TimeBucket 只读 + 清除钟点按钮
    /// - hasDueTime=false: "添加钟点"按钮 + TimeBucket 胶囊(手动选)
    @ViewBuilder
    private var timeRowWithDueDate: some View {
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
                // "添加钟点":首次按下时把钟点设为当前时刻,避免显示 startOfDay 的 00:00。
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

                HStack(spacing: WarmSpacing.xs) {
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
            Text(bucket.localizedTitle)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
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

                HStack(spacing: WarmSpacing.xs) {
                    recurrenceModeButton(nil, title: String(localized: "recurrence.none"))
                    recurrenceModeButton(.daily, title: String(localized: "recurrence.daily"))
                    recurrenceModeButton(.weekly, title: String(localized: "recurrence.weekly_short"))
                    recurrenceModeButton(.monthly, title: String(localized: "recurrence.monthly_short"))
                }

                if editedRecurrenceFrequency == .weekly {
                    HStack(spacing: WarmSpacing.xs) {
                        ForEach(1...7, id: \.self) { weekday in weekdayButton(weekday) }
                    }
                }

                if editedRecurrenceFrequency == .monthly {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(String(localized: "recurrence.monthly_day_prefix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        TextField(String(localized: "recurrence.monthly_day_placeholder"), text: $editedDayOfMonth)
                            .keyboardType(.numberPad)
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textPrimary)
                            .frame(width: 48)
                            .padding(.horizontal, WarmSpacing.xs)
                            .padding(.vertical, WarmSpacing.xs)
                            .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(WarmTheme.secondaryBackground))
                            .onChange(of: editedDayOfMonth) { _, _ in checkForChanges() }
                        Text(String(localized: "recurrence.monthly_day_suffix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                    }
                }

                if let recurrenceValidationMessage {
                    Text(recurrenceValidationMessage)
                        .font(WarmFont.caption(12))
                        .foregroundColor(WarmTheme.warning)
                }
            }
        }
    }

    private func recurrenceModeButton(_ frequency: RecurrenceFrequency?, title: String) -> some View {
        let isSelected = editedRecurrenceFrequency == frequency
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedRecurrenceFrequency = frequency
                if frequency == .weekly && editedWeekdays.isEmpty {
                    editedWeekdays = [Calendar.current.component(.weekday, from: Date())]
                }
                if frequency == .monthly && editedDayOfMonth.isEmpty {
                    editedDayOfMonth = String(Calendar.current.component(.day, from: Date()))
                }
                checkForChanges()
            }
        } label: {
            Text(title)
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, WarmSpacing.xs)
                .background(RoundedRectangle(cornerRadius: WarmRadius.card).fill(isSelected ? WarmTheme.primary : WarmTheme.secondaryBackground))
        }
        .buttonStyle(.plain)
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isSelected = editedWeekdays.contains(weekday)
        return Button {
            if isSelected { editedWeekdays.remove(weekday) } else { editedWeekdays.insert(weekday) }
            checkForChanges()
        } label: {
            Text(shortWeekdayName(weekday))
                .font(WarmFont.caption(12))
                .foregroundColor(isSelected ? .white : WarmTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: WarmSpacing.xxl)
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

    private var editedRecurrenceRule: RecurrenceRule? {
        switch editedRecurrenceFrequency {
        case .daily: return RecurrenceRule(frequency: .daily)
        case .weekly: return editedWeekdays.isEmpty ? nil : RecurrenceRule(frequency: .weekly, weekdays: Array(editedWeekdays))
        case .monthly:
            guard let day = Int(editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)), (1...31).contains(day) else { return nil }
            return RecurrenceRule(frequency: .monthly, dayOfMonth: day)
        case nil: return nil
        }
    }

    private var recurrenceValidationMessage: String? {
        switch editedRecurrenceFrequency {
        case .weekly: return editedWeekdays.isEmpty ? String(localized: "recurrence.validation.weekly_required") : nil
        case .monthly:
            let trimmed = editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let day = Int(trimmed), (1...31).contains(day) else { return String(localized: "recurrence.validation.monthly_day") }
            return nil
        case .daily, nil: return nil
        }
    }

    private var recurrenceStateChanged: Bool {
        if editedRecurrenceFrequency != todo.recurrenceRule?.frequency { return true }
        switch editedRecurrenceFrequency {
        case .weekly: return editedWeekdays != Set(todo.recurrenceRule?.weekdays ?? [])
        case .monthly: return editedDayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines) != (todo.recurrenceRule?.dayOfMonth.map(String.init) ?? "")
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
