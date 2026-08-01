import SwiftUI

/// ConfirmSheet 列表区:按 dueDate 分组成「今天 / 明天 / 周三 / 7月15日」,
/// 每组带细线分隔的 uppercase header,组内条目按 dueDate 升序排列。
/// 流式期间在末尾追加 StreamingFooter(三个点 blink + 「还在识别...」)。
///
/// 分组 key 与 title 都用 `TodoRelativeDateFormatter.format(_:)` 生成,
/// 保证与 HomeView 列表用的相对日期文案单一来源。无 dueDate 的条目归到
/// 「待定」组,排在最前(避免它们被日期排序推到末尾看不见)。
struct ConfirmGroupedList: View {
    @Binding var todos: [ExtractedTodo]
    @Binding var expandedTodoID: UUID?
    let isStreaming: Bool
    /// 流式期间卡片被点击时触发(透传到每行,由 ConfirmSheetView 显示底部 toast)。
    let onStreamingTap: () -> Void

    /// 展开态分组冻结:expandedTodoID != nil 时沿用上一帧的分组结果,
    /// 避免用户在面板改日期 → 卡片当场换组 → 展开的面板跳到别的 section。
    /// 收起时清空,回到实时分组。
    @State private var frozenSections: [GroupedSection]?

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            ForEach(Array(effectiveSections.enumerated()), id: \.element.key) { _, section in
                ConfirmGroupSection(section: section, todos: $todos, expandedTodoID: $expandedTodoID, isStreaming: isStreaming, onStreamingTap: onStreamingTap)
            }

            if isStreaming {
                StreamingFooter()
                    .padding(.top, WarmSpacing.xs)
            }
        }
        // 仅观察 count:ExtractedTodo 自定义 Codable 未合成 Equatable,
        // `.animation(value: todos)` 编译不过。count 变化是流式插入/删除的主要触发场景,
        // 内容编辑(标题/timeBucket)的反馈由具体 control 自己处理(Menu/TextField 已有动画)。
        .animation(WarmAnimation.springSlow, value: todos.count)
        .onChange(of: expandedTodoID) { _, newValue in
            if newValue != nil {
                // 进入展开态:冻结当前分组,面板改日期不会当场重排
                if frozenSections == nil {
                    frozenSections = groupedSections
                }
            } else {
                // 收起:解冻,回到实时分组(归位到新分组由上层 animation 播放)
                frozenSections = nil
            }
        }
        .onChange(of: todos.count) { _, _ in
            // 展开态下若有卡片被删除,frozenSections 会保留已删除 id 所属的空 section
            // (row 本身因 firstIndex 找不到会被跳过,但组 header 仍会渲染成空组)。
            // 这里在 count 变化时重建冻结快照——只同步删除,不重排日期
            // (改日期不改 count,不触发本回调,冻结初衷不破)。
            if expandedTodoID != nil {
                frozenSections = groupedSections.filter { section in
                    section.todoIDs.contains { id in todos.contains { $0.id == id } }
                }
            }
        }
        .accessibilityIdentifier("ExtractedTodoList")
    }

    // MARK: - Grouping

    fileprivate struct GroupedSection: Identifiable {
        let key: String
        let title: String
        /// 该组内条目的稳定身份(UUID),而非原数组下标。
        /// 原因:流式失败 / 用户删除导致 todos 缩短时,数组下标会失效,
        /// SwiftUI 在 row removal transition 期间仍可能持有陈旧 section 实例调用 body,
        /// 此刻 `$todos[staleIndex]` 会触发 Index out of range 致命错误。
        /// 用 UUID 做 ForEach 身份,row 渲染时 firstIndex(where:) 现查 index,
        /// 找不到 id 自动跳过(等价于"该 row 已不在数组里"),天然防御越界。
        let todoIDs: [UUID]
        /// 组内最小 dueDate,nil 表示「待定」组(排最前)。
        let minDueDate: Date?

        var id: String { key }
    }

    private var groupedSections: [GroupedSection] {
        let now = Date()
        let pendingKey = String(localized: "confirm.group.pending")

        // 按 title 分桶,用 Dictionary 避免 firstIndex(where:) 的 O(n^2) 查找。
        // 保留插入顺序用独立数组 titles 维护(展示顺序最后由 sorted 决定)。
        var bucketByTitle: [String: (minDate: Date?, ids: [UUID])] = [:]
        var titles: [String] = []
        for todo in todos {
            let title: String
            let date: Date?
            if let due = todo.dueDate {
                title = TodoRelativeDateFormatter.format(due, now: now)
                date = due
            } else {
                title = pendingKey
                date = nil
            }
            if var existing = bucketByTitle[title] {
                existing.ids.append(todo.id)
                if let d = date, let prevMin = existing.minDate {
                    existing.minDate = min(prevMin, d)
                } else if date != nil {
                    existing.minDate = date
                }
                bucketByTitle[title] = existing
            } else {
                titles.append(title)
                bucketByTitle[title] = (date, [todo.id])
            }
        }

        // 排序:无 dueDate 组(nil)放最前,其余按 minDueDate 升序
        return titles
            .compactMap { title -> GroupedSection? in
                guard let bucket = bucketByTitle[title] else { return nil }
                return GroupedSection(key: title, title: title, todoIDs: bucket.ids, minDueDate: bucket.minDate)
            }
            .sorted { lhs, rhs in
                switch (lhs.minDueDate, rhs.minDueDate) {
                case (nil, nil): return lhs.key < rhs.key
                case (nil, _):   return true
                case (_, nil):   return false
                case let (l?, r?): return l < r
                }
            }
    }

    /// 展开态用冻结分组,正常态用实时分组。
    private var effectiveSections: [GroupedSection] {
        if expandedTodoID != nil, let frozen = frozenSections {
            return frozen
        }
        return groupedSections
    }
}

// MARK: - Group Section

private struct ConfirmGroupSection: View {
    let section: ConfirmGroupedList.GroupedSection
    @Binding var todos: [ExtractedTodo]
    @Binding var expandedTodoID: UUID?
    let isStreaming: Bool
    let onStreamingTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            ConfirmGroupHeader(title: section.title)

            // ForEach 的 row 身份用 todo.id(UUID)。
            // 跨帧 id 稳定由 TodoExtractorService.reassignedIDs 保证(维护 stableIDs 数组,
            // 按 index 复用 UUID)——避免每个 partial 都触发整批 removal + insertion,
            // 也就是下面 .transition 定义下的"卡片向右闪出"现象。
            //
            // 越界防御:流式失败 / clearExtractionPresentation 把 todos 置空时,
            // SwiftUI 在 row removal transition 期间仍可能调用本 body;
            // 用 firstIndex 现查 index,找不到 id 自动跳过,不再 $todos[staleIndex]。
            ForEach(section.todoIDs, id: \.self) { id in
                if let index = todos.firstIndex(where: { $0.id == id }) {
                    TodoItemRowWithDelete(
                        index: index,
                        todo: $todos[index],
                        todos: $todos,
                        expandedTodoID: $expandedTodoID,
                        isStreaming: isStreaming,
                        onStreamingTap: onStreamingTap
                    )
                    .id(id)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Group Header

/// 「今天 / 明天 / 周三」+ 细线延伸,对齐 HTML .group。
struct ConfirmGroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: WarmSpacing.xs) {
            Text(title)
                .font(WarmFont.captionFixed(12))
                .tracking(0.6)
                .foregroundStyle(WarmTheme.textMuted)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(WarmTheme.divider)
                .frame(height: 1)
        }
        .accessibilityIdentifier("ConfirmGroupHeader_\(title)")
    }
}

// MARK: - Streaming Footer

/// 流式末尾的「● ● ● 还在识别...」指示器,对齐 HTML .streaming。
/// 三个圆点交替 blink,文字用 textMuted 让它不抢卡片焦点。
///
/// 用 TimelineView 驱动而非 @State + .onAppear + .repeatForever:
/// StreamingFooter 在 mainContent 的不同分支(todos 空 vs 非空)是独立实例,
/// 分支切换时 @State 重置会导致圆点闪烁。TimelineView 是无状态的,
/// 重建不会造成视觉跳变。
///
/// 用 `.periodic(from:by:0.05)` 而非 `.animation`:弹层内同时有 ScrollView +
/// 卡片动画,`.animation` 每帧重绘在低端设备掉帧。20fps 对三个圆点 blink 视觉足够。
struct StreamingFooter: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: WarmSpacing.xs) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = sin(t * 2.5 + Double(i) * 0.8)
                        Circle()
                            .fill(WarmTheme.primary)
                            .frame(width: 5, height: 5)
                            .scaleEffect(0.6 + 0.4 * (0.5 + 0.5 * phase))
                            .opacity(0.22 + 0.78 * (0.5 + 0.5 * phase))
                    }
                }
                Text(String(localized: "confirm.streaming_inline"))
                    .font(WarmFont.caption(13))
                    .foregroundStyle(WarmTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarmSpacing.xs)
        .accessibilityIdentifier("ConfirmStreamingFooter")
    }
}
