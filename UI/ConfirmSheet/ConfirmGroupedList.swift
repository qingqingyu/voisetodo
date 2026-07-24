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
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            ForEach(Array(groupedSections.enumerated()), id: \.element.key) { _, section in
                ConfirmGroupSection(section: section, todos: $todos)
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
        .accessibilityIdentifier("ExtractedTodoList")
    }

    // MARK: - Grouping

    fileprivate struct GroupedSection: Identifiable {
        let key: String
        let title: String
        /// 该组内条目的原始 todos 数组下标。用下标而非拷贝 ExtractedTodo,
        /// 这样 TodoItemRow 的 @Binding 仍指向唯一真相源。
        let originalIndices: [Int]
        /// 组内最小 dueDate,nil 表示「待定」组(排最前)。
        let minDueDate: Date?

        var id: String { key }
    }

    private var groupedSections: [GroupedSection] {
        let now = Date()
        let pendingKey = String(localized: "confirm.group.pending")

        // 按 title 分桶,用 Dictionary 避免 firstIndex(where:) 的 O(n^2) 查找。
        // 保留插入顺序用独立数组 titles 维护(展示顺序最后由 sorted 决定)。
        var bucketByTitle: [String: (minDate: Date?, indices: [Int])] = [:]
        var titles: [String] = []
        for (index, todo) in todos.enumerated() {
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
                existing.indices.append(index)
                if let d = date, let prevMin = existing.minDate {
                    existing.minDate = min(prevMin, d)
                } else if date != nil {
                    existing.minDate = date
                }
                bucketByTitle[title] = existing
            } else {
                titles.append(title)
                bucketByTitle[title] = (date, [index])
            }
        }

        // 排序:无 dueDate 组(nil)放最前,其余按 minDueDate 升序
        return titles
            .compactMap { title -> GroupedSection? in
                guard let bucket = bucketByTitle[title] else { return nil }
                return GroupedSection(key: title, title: title, originalIndices: bucket.indices, minDueDate: bucket.minDate)
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
}

// MARK: - Group Section

private struct ConfirmGroupSection: View {
    let section: ConfirmGroupedList.GroupedSection
    @Binding var todos: [ExtractedTodo]

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
            ConfirmGroupHeader(title: section.title)

            // ForEach 的 row 身份用 todo.id(UUID):流式过程 .partial 整体替换 todos,
            // originalIndices 的 Int 不变但数组对应位置的 todo 已换人。
            // 外层 .id(todos[index].id) 覆盖 ForEach 的 `id: \.self` 身份,
            // 让 SwiftUI 按 UUID 判定 view 重建,触发 EmojiBumpModifier 重播,
            // 避免「row 内容突变但 view 没换」的身份漂移。
            ForEach(section.originalIndices, id: \.self) { index in
                TodoItemRowWithDelete(
                    index: index,
                    todo: $todos[index],
                    todos: $todos
                )
                .id(todos[index].id)
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
