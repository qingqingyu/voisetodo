import SwiftUI

struct HomeSelectedDayListView: View {
    let state: HomeCalendarState
    let selectedBottomTab: BottomTab
    // 用于 daySectionHeader 副标题布局切换:Accessibility 档位下副标题横排会撑爆,
    // 回退到下方 VStack;普通档位下放右侧 HStack。读 dynamicTypeSize 是因为
    // `isAccessibilitySize` 是 SwiftUI 推荐的 a11y 阈值判定;`sizeCategory` 的枚举没有
    // 等价属性,且 `sizeCategory` 与 `dynamicTypeSize` 由 SwiftUI 自动同步,preview 里
    // 用 `.environment(\.sizeCategory, .accessibilityXXXL)` 仍能驱动本判断。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onToggleOccurrence: (TodoOccurrenceData) -> Void
    let onDeleteTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    /// 长按 context menu:卡片移到某 bucket。
    let onMoveToBucket: (UUID, TimeBucket) -> Void
    /// 长按 context menu:卡片移到明天。
    let onMoveToTomorrow: (UUID) -> Void
    /// 时间 chip 点击后的改时间入口。`Date` 由 `TimeEditPopover` 提交时填好,本回调负责写库。
    /// 改时间 popover 只用于「今日 Section」的 occurrence,待定日期组走自己的「选日期」按钮(Commit 6)。
    let onChangeTime: (UUID, Date) -> Void
    /// 「待定日期」分组「选日期」按钮提交后写库。参数是用户选定的 startOfDay,
    /// 调用方按 hasDueTime=false + 保留原 timeBucket 写入 —— 原本带时段 chip 的任务
    /// 落到 Today 对应时段 tier，原本只有 dueHint 的落到「整天」tier。
    let onPickDate: (UUID, Date) -> Void
    /// 「没能识别」分组「重新解析」按钮入口。把 rawTranscript 再喂一遍 extractor,
    /// 成功 → 替换原 todo 为 .parsed;失败 → 保留原 todo + toast。
    let onReextract: (UUID) -> Void
    /// 「稍后」section 拖拽排序回调。参数为用户拖完后该 section 的新顺序 todo id 数组,
    /// 调用方走 store.reorder 做局部重排(只动这组 sortOrder,不影响其他 section)。
    let onReorder: ([UUID]) -> Void
    /// 正在重新解析的 todo id 集合(来自 AppCoordinator.reextractingTodoIDs)。
    /// 用于驱动 UnparsedTodoCard 的按钮 disabled + ProgressView,防连点。
    var reextractingTodoIDs: Set<UUID> = []
    /// 待揭晓的新增条目 id(来自 AppCoordinator.pendingRevealTodoIDs)。
    /// 这些条目已写库但还没在 UI 上播过入场动画——`onAppear` 必须跳过自动 insert,
    /// 等 HomeView 在 ConfirmSheet `onDismiss` 后按 rank 依次放动画。否则动画会在
    /// sheet 背后播完,用户看到一堆静止的行。详见 docs/confirm-sheet-success-feedback-to-list-entrance.md。
    var pendingRevealIDs: Set<UUID> = []

    /// 选中日是否完全无 todo 数据(未完成 + 已完成 + 待处理 bucket 全空)。
    /// 用于决定 Today Section body 是否走 `emptySelectedDayRow` 空态分支。
    private var isSelectedDayCompletelyEmpty: Bool {
        state.selectedOccurrences.isEmpty
            && state.pendingDateTodos.isEmpty
            && state.unparsedTodos.isEmpty
            && state.unscheduledTodos.isEmpty
    }

    var body: some View {
        List {
            // Today Section 无 header —— 顶部 headerView 的大标题已经标明当前是「Today」tab,
            // list 里再挂 "Today · N" 会与顶部标题重复(用户 2026-07-25 真机反馈)。
            // 其他 section(稍后 / 待定日期 / 没能识别 / 已完成)保留 daySectionHeader,
            // 因为它们的标题信息(分组名 + 数量)无法从顶部推导。
            Section {
                if !state.hasTodos {
                    homeGlobalEmptyRow
                } else if isSelectedDayCompletelyEmpty {
                    emptySelectedDayRow
                } else {
                    todaySectionBody
                }
            }

            // 「稍后」分区(原「未定时间」):完全无时间信号的待排期货(原「未安排」,语义收紧后改名)。
            // 排在 Today 之后——用户主动暂存的待办(类 Inbox 性质),需要快速访问;
            // 与海外主流 todo app(Things 3 / TickTick 等)把 Inbox 提前的模式一致。
            // 本分区启用 `.onMove`:长按 row 进入拖拽模式,松手后回调 onReorder 走 store.reorder。
            // 对应 s17/s20 用户反馈(未设时任务想自由排序,不想为排序逐项设时间)。
            if !state.unscheduledTodos.isEmpty {
                Section {
                    // 不用 enumerated —— `.onMove` 要求 ForEach 直接对 Identifiable 集合迭代,
                    // 元组数组会破坏 List 内置 reorder 手势识别。
                    // index 改用 firstIndex 取(列表通常 < 20 项,O(n²) 可接受),
                    // 数值与原 enumerated 一致,WarmTodoCard staggered 动画不变。
                    ForEach(state.unscheduledTodos) { todo in
                        let idx = state.unscheduledTodos.firstIndex(where: { $0.id == todo.id }) ?? 0
                        todoRow(
                            todo,
                            index: state.selectedOccurrences.count + idx,
                            position: GroupedRowPosition(index: idx, count: state.unscheduledTodos.count)
                        )
                    }
                    .onMove { offsets, target in
                        var arr = state.unscheduledTodos
                        arr.move(fromOffsets: offsets, toOffset: target)
                        onReorder(arr.map(\.id))
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.undated.section"),
                        count: state.unscheduledTodos.count,
                        subtitle: String(localized: "home.undated.section.hint")
                    )
                }
            }

            // 「待定日期」分区:有时间信号(timeBucket 或 dueHint)但没具体日期。
            // 用 PendingDateTodoRow:橙描边「选日期」按钮 + .loose chip 显示时段 / dueHint。
            // 半完成态——用户已表达意向但需手动选日期,中段优先级。
            if !state.pendingDateTodos.isEmpty {
                Section {
                    ForEach(Array(state.pendingDateTodos.enumerated()), id: \.element.id) { idx, todo in
                        PendingDateTodoRow(
                            todo: todo,
                            index: state.unscheduledTodos.count + idx,
                            onToggle: { onToggleTodo(todo.id) },
                            onOpen: { onOpenTodo(todo) },
                            onDelete: { onDeleteTodo(todo.id) },
                            onPickDate: { date in onPickDate(todo.id, date) }
                        )
                        // 「待定日期」恒有第二行(时段/dueHint chip + 「选日期」按钮),固定走 76pt 档。
                        .groupedCardRow(
                            GroupedRowPosition(index: idx, count: state.pendingDateTodos.count),
                            height: .tall
                        )
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.pending_date.section"),
                        count: state.pendingDateTodos.count,
                        subtitle: String(localized: "home.pending_date.section.hint")
                    )
                }
            }

            // 「没能识别」分区:outcome != .parsed 的原文兜底条目。
            // 用 UnparsedTodoCard:斜纹背景 + dashed border + 「重新解析 / 删除」按钮。
            // 系统失败态——靠后,避免干扰主线;对应海外 app 隐藏/角落化失败条目的模式。
            if !state.unparsedTodos.isEmpty {
                Section {
                    ForEach(Array(state.unparsedTodos.enumerated()), id: \.element.id) { idx, todo in
                        UnparsedTodoCard(
                            todo: todo,
                            index: idx,
                            onReextract: { onReextract(todo.id) },
                            onDelete: { onDeleteTodo(todo.id) },
                            isReextracting: reextractingTodoIDs.contains(todo.id)
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDeleteTodo(todo.id)
                            } label: {
                                Label(String(localized: "home.delete"), systemImage: "trash")
                            }
                        }
                        // 「没能识别」刻意**不**走分组卡片:UnparsedTodoCard 自带斜纹底 +
                        // dashed 描边,本来就是一张独立的"失败态"卡。再套一层白卡会变成
                        // 卡中卡,而且失败态混进整齐的分组卡里反而弱化了"这条没解析成功"的提示。
                        // 它的 listRowInsets / listRowBackground 仍由组件自己管。
                    }
                } header: {
                    daySectionHeader(
                        title: String(localized: "home.unparsed.section"),
                        count: state.unparsedTodos.count
                    )
                }
            }

            // 「已完成」分区 = 当日 occurrence 的已完成 + 全局无安排任务的已完成。
            // 放最后:已完成是历史信息,优先级最低。
            if !state.completedOccurrences.isEmpty || !state.completedUnscheduledTodos.isEmpty {
                Section {
                    // 已完成分区由两段拼成(当日 occurrence + 全局无安排任务),但视觉上是**一张**卡,
                    // 所以圆角位置要按两段的总数算,不能各自从 0 数起。
                    let completedTotal = state.completedOccurrences.count + state.completedUnscheduledTodos.count

                    ForEach(Array(zip(state.completedOccurrences.indices, state.completedOccurrences)), id: \.1.id) { idx, occurrence in
                        occurrenceRow(
                            occurrence,
                            index: state.uncompletedOccurrences.count + idx,
                            position: GroupedRowPosition(index: idx, count: completedTotal)
                        )
                    }
                    ForEach(Array(state.completedUnscheduledTodos.enumerated()), id: \.element.id) { idx, todo in
                        // index 延续「已完成 occurrence」之后,跨过 today / unscheduled / pendingDate / unparsed
                        // 各 section 的行数(按当前 section 顺序),避免 a11y identifier 与前面 section 的行号撞号。
                        completedTodoRow(
                            todo,
                            index: state.selectedOccurrences.count
                                + state.unscheduledTodos.count
                                + state.pendingDateTodos.count
                                + state.unparsedTodos.count + idx,
                            // position 用「已完成 occurrence 段之后」的连续下标,与上一个 ForEach 接上。
                            position: GroupedRowPosition(
                                index: state.completedOccurrences.count + idx,
                                count: completedTotal
                            )
                        )
                    }
                } header: {
                    let totalCount = state.completedOccurrences.count + state.completedUnscheduledTodos.count
                    daySectionHeader(title: String(localized: "home.completed_section_title"), count: totalCount)
                }
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollContent)
        .contentMargins(.bottom, HomeLayoutMetrics.listBottomInset, for: .scrollIndicators)
        .accessibilityIdentifier("TodoList")
    }

    /// Today Section 拍平后的一行。tier 标签和 occurrence 混在同一个序列里,
    /// 是为了让「整个 Today 是一张卡」这件事成立 —— 圆角只能落在**拍平后**的
    /// 第一行和最后一行上,分开两层 ForEach 就算不出这个位置。
    private enum TodayRowEntry {
        /// 卡内 tier 小标题条(整天 / 上午 / 下午 / 晚上 / 按时间)。
        case subhead(tier: TodayTier, tierIndex: Int)
        /// 一条未完成 occurrence。`index` 是全局 running index,
        /// a11y identifier(`TodoCheckbox_\(index)` 等)依赖它稳定。
        case occurrence(TodoOccurrenceData, index: Int)

        var id: String {
            switch self {
            case .subhead(_, let tierIndex): return "tier-\(tierIndex)"
            // TodoOccurrenceData.id 已经是 "todoUUID-yyyy-MM-dd" 形式的 String,
            // 直接用它,和其它 ForEach 的 `id: \.element.id` 保持同一套身份。
            case .occurrence(let occurrence, _): return occurrence.id
            }
        }

        var isSubhead: Bool {
            if case .subhead = self { return true }
            return false
        }
    }

    /// 把 `tieredUncompletedOccurrences` 的两层结构拍平成一维行序列。
    /// occurrence 的 running index 在这里一次性算好 —— 原来靠 `occurrenceRunningCounter`
    /// 单独算一遍前缀和,拍平之后顺手累加即可,少一处会和渲染顺序失配的状态。
    private var todayRowEntries: [TodayRowEntry] {
        var entries: [TodayRowEntry] = []
        var occurrenceIndex = 0
        for (tierIndex, group) in state.tieredUncompletedOccurrences.enumerated() {
            entries.append(.subhead(tier: group.tier, tierIndex: tierIndex))
            for occurrence in group.items {
                entries.append(.occurrence(occurrence, index: occurrenceIndex))
                occurrenceIndex += 1
            }
        }
        return entries
    }

    /// 今天 Section 的内部 body:整个 Section 合成一张白卡,
    /// tier 标签是卡内的浅灰小标题条(设计稿 HTML 的 `.subhead`),条目之间画发丝线。
    ///
    /// 历史:tier 标签原来是卡片外的独立文字行,靠「上空白大 / 下空白小」的非对称留白分组
    /// (2026-07-25 的做法)。卡片合并之后那套留白会把一张卡切成几段,所以标签收进卡内。
    @ViewBuilder
    private var todaySectionBody: some View {
        let entries = todayRowEntries
        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
            let position = GroupedRowPosition(index: idx, count: entries.count)
            // 下一行是灰条时不画发丝线:灰条本身就是分隔带,再叠一条线显脏。
            let nextIsSubhead = idx + 1 < entries.count && entries[idx + 1].isSubhead

            switch entry {
            case .subhead(let tier, _):
                GroupedCardSubheadRow(text: tier.localizedLabel)
                    .groupedCardRow(
                        position,
                        height: .subhead,
                        fill: WarmTheme.subheadBackground,
                        showsHairline: false
                    )

            case .occurrence(let occurrence, let index):
                occurrenceRow(
                    occurrence,
                    index: index,
                    position: position,
                    showsHairline: !nextIsSubhead
                )
            }
        }
    }

    /// 这张卡会不会有第二行元数据 → 决定 56 / 76 两档行高里取哪一档。
    /// 判断委托给 `WarmTodoCard.hasMetadataLine`,与卡片内部实际渲不渲染第二行同源。
    private func rowHeight(
        for todo: TodoItemData,
        showsTimeBucketMetadata: Bool,
        showsInlineTimePrefix: Bool
    ) -> GroupedRowHeight {
        WarmTodoCard.hasMetadataLine(
            todo: todo,
            showsTimeBucketMetadata: showsTimeBucketMetadata,
            showsInlineTimePrefix: showsInlineTimePrefix
        ) ? .tall : .compact
    }

    private var homeGlobalEmptyRow: some View {
        // 空状态：去卡片容器，内容直接坐背景上；加向下箭头引导视线到 FAB；
        // top inset 加大让内容接近屏幕视觉中心（~40-45% 高度）。
        VStack(spacing: WarmSpacing.lg) {
            ProductEmptyStateView(
                icon: "sparkles",
                title: String(localized: "empty.home.title"),
                message: String(localized: "empty.home.message"),
                cardless: true
            )
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(WarmTheme.primary.opacity(0.35))
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: HomeLayoutMetrics.emptyStateTopInset, leading: WarmSpacing.lg, bottom: WarmSpacing.sm, trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    /// 选中日空状态:cardless + 大细线图标 + 引导文案 + 向下箭头。
    /// 对齐 `homeGlobalEmptyRow` 的视觉模式(用户反馈:原版白底卡片像内容、无引导、
    /// 浪费整屏空间)。两个 Text 都加 lineLimit + minimumScaleFactor,
    /// 遵守 CLAUDE.md「文本布局规则」——AX5 字号下允许缩到 0.7 倍避免换行溢出。
    private var emptySelectedDayRow: some View {
        VStack(spacing: WarmSpacing.lg) {
            VStack(spacing: WarmSpacing.xs) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(WarmTheme.primary.opacity(0.7))

                Text(String(localized: selectedBottomTab == .today
                             ? "empty.day.today" : "empty.day.title"))
                    .font(WarmFont.body(15))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)

                Text(String(localized: "empty.day.hint"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(WarmTheme.primary.opacity(0.35))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("EmptyState")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: HomeLayoutMetrics.emptyStateTopInset,
                                  leading: WarmSpacing.lg,
                                  bottom: WarmSpacing.sm,
                                  trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
    }

    /// section header。可选 `subtitle` 给副标题(如「稍后」「待定日期」分区的说明)。
    ///
    /// 布局:
    /// - 普通/Medium~ExtraExtraLarge 字号:副标题横放到标题/count 行的**右侧**,10pt + lineLimit(1),
    ///   用 `minimumScaleFactor(0.7)` 兜底英文长文本(如 "You mentioned a time, but not a day")。
    ///   副标题本就是辅助提示,设计稿把它放右侧与卡片内容做水平分隔,比压在标题下方更省垂直空间。
    /// - Accessibility 档位(AX1~AX5):caption 11pt 跟随 Dynamic Type 缩放到 ~30pt+,横排必然溢出,
    ///   回退到下方 VStack + 11pt + lineLimit(2)。a11y 用户优先要可读,不能靠 scaleFactor 硬挤。
    ///
    /// 其他分区(已完成 / 没能识别)不传 subtitle 即不渲染。
    private func daySectionHeader(title: String, count: Int, subtitle: String? = nil) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    titleCountHStack(title: title, count: count)
                    if let subtitle {
                        Text(subtitle)
                            .font(WarmFont.caption(11))
                            .foregroundColor(WarmTheme.textMuted)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    titleCountHStack(title: title, count: count)
                    Spacer(minLength: WarmSpacing.sm)
                    if let subtitle {
                        Text(subtitle)
                            // 10pt:比正文小一档,作为「次要提示」的视觉权重;minimumScaleFactor(0.7)
                            // 遵守 CLAUDE.md 文本布局规则(≥0.7),与全文件其他 Text 统一,
                            // 英文 36 字符在 SE 上可缩到 7pt 仍可读。
                            .font(WarmFont.caption(10))
                            .foregroundColor(WarmTheme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .foregroundColor(WarmTheme.textSecondary)
        .textCase(nil)
        // leading 与卡片左边缘对齐(都是 lg=20)。原来是 xl=24,卡片自带 lg 页边距时看不出来,
        // 现在分区合成整块白卡,4pt 的错位会在 header 和卡片左沿之间露出来。
        // top 从 sm(12) 提到 lg(20):行间距归零后,两张分区卡之间的呼吸感全靠 header 顶距撑。
        .listRowInsets(EdgeInsets(top: WarmSpacing.lg, leading: WarmSpacing.lg, bottom: WarmSpacing.xs, trailing: WarmSpacing.lg))
    }

    /// daySectionHeader 内部复用的「标题 + count」行。count=0 时不显示数字徽章——
    /// 空状态已有引导文案,"0"是冗余信息且看着像错误状态。橙色胶囊徽章改成朴素灰数字:
    /// 分区合并成整齐的白卡之后,每个 header 上再顶一个橙胶囊,颜色重量压过了卡片内容本身
    /// (对齐设计稿的「随时做 6」写法)。
    @ViewBuilder
    private func titleCountHStack(title: String, count: Int) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(title)
                .font(WarmFont.headline(15))
                // 标题给 layoutPriority(1):副标题用 minimumScaleFactor 缩放时,
                // SwiftUI 优先保标题完整,副标题承担压缩。
                .layoutPriority(1)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textMuted)
            }
        }
    }

    /// 未完成 unscheduled 行。Calendar tab 挂 `draggable`——长按拖到月历某天/时间线排程；
    /// Today tab 无月历可落点，不挂。
    /// 完成态样式（绿勾/删除线）由 WarmTodoCard 根据 `todo.isCompleted` 自行渲染。
    @ViewBuilder
    private func todoRow(_ todo: TodoItemData, index: Int, position: GroupedRowPosition) -> some View {
        let base = unscheduledTodoCardBase(
            todo: todo,
            index: index,
            position: position,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) },
            onDelete: { onDeleteTodo(todo.id) }
        )

        if selectedBottomTab == .calendar {
            base.draggable(todo.id.uuidString) {
                HStack(spacing: WarmSpacing.xxs) {
                    Text(todo.category.emoji)
                    Text(todo.title).lineLimit(1)
                }
                .font(WarmFont.caption(13))
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background(Capsule().fill(WarmTheme.secondaryBackground))
            }
        } else {
            base
        }
    }

    /// 已完成无安排任务的行。与 `todoRow` 的差别：
    /// - 不挂 `.draggable`（已完成的不该再拖月历）
    /// 完成态样式（绿勾/删除线）由 WarmTodoCard 根据 `todo.isCompleted` 自行渲染。
    /// 取消完成时 onToggle 会把 isCompleted 翻回 false → 下次重渲染时该行离开「已完成」、
    /// 回到「未安排」分区（unscheduledTodos 重新含它）。
    @ViewBuilder
    private func completedTodoRow(_ todo: TodoItemData, index: Int, position: GroupedRowPosition) -> some View {
        unscheduledTodoCardBase(
            todo: todo,
            index: index,
            position: position,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) },
            onDelete: { onDeleteTodo(todo.id) }
        )
    }

    /// Unscheduled 系卡片（todoRow / completedTodoRow）共用样式：
    /// WarmTodoCard + inset/背景/删除 swipe/入场动画/transition。
    /// 抽出来避免两处复制粘贴——后续改卡片样式只改一处。
    /// 不含 `draggable` 分支——draggable 由调用方按完成态与 tab 自行决定。
    ///
    /// Row tap 用 `Button(action: onTap).buttonStyle(.plain)` 包装而不是 WarmTodoCard 内的
    /// `.onTapGesture`：iOS 26 FB18199844 下顶层 onTapGesture 会吞掉 swipeActions delete 按钮
    /// 的 tap。Button 是显式控件，与 swipeActions 容器级手势天然共存（Apple Reminders 风格），
    /// 内嵌 checkbox Button 由 SwiftUI 分派给最内层 Button，点 checkbox 只触发 toggle。
    @ViewBuilder
    private func unscheduledTodoCardBase(
        todo: TodoItemData,
        index: Int,
        position: GroupedRowPosition,
        onToggle: @escaping () -> Void,
        onTap: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            WarmTodoCard(
                index: index,
                todo: todo,
                onToggle: onToggle,
                onMoveToBucket: { bucket in onMoveToBucket(todo.id, bucket) },
                onMoveToTomorrow: { onMoveToTomorrow(todo.id) },
                showsCardBackground: false
            )
        }
        .buttonStyle(.plain)
        .groupedCardRow(
            position,
            height: rowHeight(for: todo, showsTimeBucketMetadata: true, showsInlineTimePrefix: false)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        // 入场动画:仅淡入,不用 .offset。
        // .offset 会让 row frame 在动画期间持续偏移,List 内部 swipe 追踪与
        // 命中测试会跟着偏移过的 frame 走,出现「刚出现就滑不动 / 滑到一半跳」。
        // 纯 .opacity 不移动 frame,命中区恒定 → swipeActions 稳定。
        .opacity(cardAppeared.contains(todo.id) ? 1 : 0)
        .onAppear {
            // 待揭晓的新增条目交给 HomeView 在 sheet dismiss 后统一放动画,
            // 否则动画会在 ConfirmSheet 背后播完(见 plan「根因 3」)。
            guard !pendingRevealIDs.contains(todo.id) else { return }
            withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                _ = cardAppeared.insert(todo.id)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    private func occurrenceRow(
        _ occurrence: TodoOccurrenceData,
        index: Int,
        position: GroupedRowPosition,
        showsHairline: Bool = true
    ) -> some View {
        Button(action: { onOpenTodo(occurrence.todo) }) {
            WarmTodoCard(
                index: index,
                todo: occurrence.todo,
                onToggle: { onToggleOccurrence(occurrence) },
                onMoveToBucket: { bucket in onMoveToBucket(occurrence.todo.id, bucket) },
                onMoveToTomorrow: { onMoveToTomorrow(occurrence.todo.id) },
                onChangeTime: { date in
                    onChangeTime(occurrence.todo.id, date)
                },
                showsTimeBucketMetadata: false,
                dueStatusDisplayMode: .overdueOnly,
                showsInlineTimePrefix: true,
                showsCardBackground: false
            )
        }
        .buttonStyle(.plain)
        .groupedCardRow(
            position,
            height: rowHeight(
                for: occurrence.todo,
                showsTimeBucketMetadata: false,
                showsInlineTimePrefix: true
            ),
            showsHairline: showsHairline
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteTodo(occurrence.todo.id)
            } label: {
                Label(String(localized: "home.delete"), systemImage: "trash")
            }
        }
        .opacity(cardAppeared.contains(occurrence.todo.id) ? 1 : 0)
        .onAppear {
            // 待揭晓的新增条目交给 HomeView 在 sheet dismiss 后统一放动画,
            // 否则动画会在 ConfirmSheet 背后播完(见 plan「根因 3」)。
            guard !pendingRevealIDs.contains(occurrence.todo.id) else { return }
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

struct HomeCalendarLoadingView: View {
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

struct HomeCalendarErrorView: View {
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
